#!/bin/bash
# usage: merge-seq.sh <wt>:<branch>:<stem> ...   (wt = worktree suffix: worktree is "$ORCH_WT_PREFIX<wt>")
# The merge train. For each item: take the merge lock, merge the default branch into the lane (train.sh), run local
# gates if configured, then push, open/update the PR and merge it only after CI passes on the exact commit (merge-pr.sh).
# Output lines a supervisor must act on: "<wt> TRAIN rc=3" + CONFLICT (resolve, push, requeue),
# "MERGE FAIL CI: ..." (fix, push, requeue), "MERGE FAIL STALE/DIRTY" (requeue / clean worktree).
#
# Locking: merges are serialized by $ORCH_STATE/merge.lock, so main cannot move during a train. A lock whose owner
# PID is gone is reclaimed. $ORCH_STATE/merge-priority, if present, names one stem that must take the lock first.
# Two-deep speculation (off unless $ORCH_STATE/merge-spec contains "on"; checked on every poll): while branch A holds
# merge.lock, one waiting branch B may take spec.lock and run its gates on A's candidate head (main + A). Once A is
# done, B merges on those gates only if main is exactly A's merge and merging main into B leaves B's tree unchanged;
# otherwise B's speculative merge is undone and B runs a normal train. Only the spec.lock holder (or the priority
# stem) may take merge.lock. Speculation only pays off when local gates are slow; with CI-only gates leave it off.
. "$(dirname "$0")/orch-env.sh"
D=$ORCH_STATE; L=$D/merge.lock; S=$D/spec.lock; P=$D/merge-priority; BIN=$ORCH_SKILL_DIR
mine() { [ "$(cat "$1/pid" 2>/dev/null)" = "$$" ]; }
reclaim() { local o; o=$(cat "$1/pid" 2>/dev/null); [ -n "$o" ] && ! kill -0 "$o" 2>/dev/null && rm -rf "$1"; }
prio_ok() { [ ! -s "$P" ] || [ "$(cat "$P")" = "$1" ]; }
spec_ok() { [ ! -d "$S" ] || mine "$S" || { [ -s "$P" ] && [ "$(cat "$P")" = "$1" ]; }; }
unlock() { mine "$L" && rm -rf "$L"; }
unspec() { mine "$S" && rm -rf "$S"; }
trap 'unlock; unspec' EXIT
clearprio() { [ -s "$P" ] && [ "$(cat "$P")" = "$1" ] && rm -f "$P"; }
# gates <train-output>: sets G (the text that replaces [GATES]), or prints the failure and returns 1.
gates() {
  local out=$1
  if grep -q "^tests: delegated to PR CI" "$out"; then G=$ORCH_GATES_TEXT; return 0; fi
  if grep -q "^gates: local ok" "$out"; then G="local gates passed (${ORCH_LOCAL_GATES}); $ORCH_GATES_TEXT"; return 0; fi
  echo "$wt GATES FAIL"; tail -20 "$out"; return 1
}
# Speculate once per item: the holder has published "candidate-head branch main" in merge.lock/head.
maybe_spec() {
  local w=$ORCH_WT_PREFIX$wt ah ab am
  [ "$(cat "$D/merge-spec" 2>/dev/null)" = on ] && [ -z "$SH" ] && [ -s "$L/head" ] && prio_ok "$stem" || return
  read ah ab am < "$L/head" 2>/dev/null; [ -n "$am" ] || return
  [ -z "$(git -C "$w" status --short 2>/dev/null)" ] || return
  mkdir "$S" 2>/dev/null || return; echo $$ > "$S/pid"
  SH=$ah; SM=$am; SPRE=$(git -C "$w" rev-parse HEAD)
  echo "$wt speculative gates on $ORCH_MAIN + $ab"
  SPEC_BASE=$ah SPEC_FROM=$ab "$BIN/train.sh" "$wt" "spec$wt" > "$D/spec-$wt.out" 2>&1; SRC=$?
}
lock() {
  until prio_ok "$1" && spec_ok "$1" && mkdir "$L" 2>/dev/null; do reclaim "$L"; reclaim "$S"; maybe_spec; sleep "$ORCH_POLL"; done
  echo $$ > "$L/pid"
}
# After A: is the speculative run exactly what main + B now is?
spec_valid() {
  local w=$ORCH_WT_PREFIX$wt t
  git -C "$w" fetch -q "$ORCH_REMOTE"
  [ "$(git -C "$w" rev-parse "$ORCH_REMOTE/$ORCH_MAIN^1" 2>/dev/null)" = "$SM" ] && \
    [ "$(git -C "$w" rev-parse "$ORCH_REMOTE/$ORCH_MAIN^2" 2>/dev/null)" = "$SH" ] || return 1
  [ "$SRC" = 0 ] || return 1
  t=$(git -C "$w" rev-parse 'HEAD^{tree}')
  git -C "$w" merge -q --no-edit "$ORCH_REMOTE/$ORCH_MAIN" -m "Merged current $ORCH_MAIN into the $br branch." >/dev/null 2>&1 || \
    { git -C "$w" merge --abort 2>/dev/null; return 1; }
  [ "$(git -C "$w" rev-parse 'HEAD^{tree}')" = "$t" ]
}
spec_undo() { local w=$ORCH_WT_PREFIX$wt; git -C "$w" merge --abort 2>/dev/null; git -C "$w" reset -q --hard "$SPRE"; echo "$wt speculation discarded: running a normal train"; }
for x in "$@"; do
  IFS=: read wt br stem _ <<<"$x"
  SH=; SM=; SPRE=; SRC=
  unlock; lock "$stem"; unspec
  if [ -n "$SH" ]; then
    if spec_valid; then
      clearprio "$stem"; echo "$wt speculation valid: using the speculative gates"
      gates "$D/spec-$wt.out" || continue
      echo "$wt gates: $G"; "$BIN/merge-pr.sh" "$wt" "$br" "$stem" "$G" 2>&1 | grep -vE "^remote:"
      continue
    fi
    spec_undo
  fi
  out=$D/train-$wt.out
  HEAD_FILE=$L/head "$BIN/train.sh" "$wt" "train$wt" > "$out" 2>&1; rc=$?
  clearprio "$stem"
  if [ $rc -ne 0 ]; then echo "$wt TRAIN rc=$rc"; tail -4 "$out"; continue; fi
  gates "$out" || continue
  echo "$wt gates: $G"
  "$BIN/merge-pr.sh" "$wt" "$br" "$stem" "$G" 2>&1 | grep -vE "^remote:"
done
