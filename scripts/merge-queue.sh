#!/bin/bash
# usage: merge-queue.sh item <wt>:<branch>:<stem>   (called by merge-seq.sh, once per item)
#        merge-queue.sh runner                      (started by a waiting item when no runner holds merge.lock)
#
# The FIFO merge train: one branch at a time, one CI run per attempt.
# item:   checks the worktree, pushes the branch only if it has no open PR (a push to an open PR would start CI), and
#         appends it to $ORCH_RUN/merge-queue/<stem> with the next sequence number; prints "<wt> queued at position N".
#         Re-running merge-seq for a queued stem keeps its position (the newest merge-seq takes over the waiting).
#         It never opens or updates the PR. It prints the runner's lines for this item and exits on the final one.
# runner: holds $ORCH_RUN/merge.lock (pid file; a dead owner's lock is reclaimed) and works the FRONT item only:
#         merge current main into the lane (train.sh: conflict -> "<wt> TRAIN rc=3" + CONFLICT + files, removed),
#         gates, then merge-pr.sh: push, create/update the PR (the single CI run), wait for CI on the exact commit,
#         merge with --match-head-commit, clean up. CI red -> "MERGE FAIL CI: ..." and the item moves to the END.
#         At its next turn: head changed (a fix was pushed or committed) -> a fresh attempt; unchanged -> one rerun
#         (merge main again; same commit -> `gh run rerun --failed`), and a second failure removes it:
#         "MERGE FAIL CI: ... (removed after 2 attempts; requeue after fixing)". Runner log: $ORCH_PIPES/merge-queue.out.
#         The PR head moving during the CI wait (a fix pushed) is not a failure: ci-wait.sh exits 4 ("HEAD MOVED: ..."),
#         the item keeps its position and attempt count and its next turn tests the new head. A CI failure whose log shows
#         only an infrastructure error (HTTP 5xx, download failure) is rerun inside ci-wait.sh and never counts as an attempt.
#         ORCH_TURN_LABEL set (label-gated CI): merge-pr.sh adds the label at the turn (that starts the one full run)
#         and removes it when the turn ends; an identical-commit second attempt gets a fresh full run instead of a rerun.
# Legacy: items left in $ORCH_RUN/batch-queue/ by the retired batch train are drained first, one classic train each.
. "$(dirname "$0")/orch-env.sh"
D=$ORCH_RUN; L=$D/merge.lock; Q=$D/merge-queue; R=$D/merge-result; BIN=$ORCH_SKILL_DIR
mkdir -p "$Q" "$R"
nap() { sleep "${ORCH_CI_SLEEP:-$1}"; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
lock_pid() { cat "$L/pid" 2>/dev/null; }
reclaim() { local o; o=$(lock_pid); [ -n "$o" ] && ! alive "$o" && rm -rf "$L"; }
qget() { sed -n "s/^$2=//p" "$Q/$1" 2>/dev/null | head -1; }
log() { echo "$(date '+%F %T') $*"; }
# qput <stem> <wt> <branch> <seq> <owner> <fails> <failhead>: atomic rewrite of a queue entry.
qput() {
  local t=$Q/.$1.$$
  printf 'stem=%s\nwt=%s\nbranch=%s\nseq=%s\nowner=%s\nfails=%s\nfailhead=%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" > "$t" && mv "$t" "$Q/$1"
}
# nextseq: monotonically increasing enqueue number ($Q/.seq, guarded by a mkdir lock).
nextseq() {
  local n; until mkdir "$Q/.seq.lock" 2>/dev/null; do sleep 1; done
  n=$(( $(cat "$Q/.seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$Q/.seq"; rmdir "$Q/.seq.lock"; echo "$n"
}
order() { local f; for f in "$Q"/*; do [ -f "$f" ] && echo "$(qget "${f##*/}" seq) ${f##*/}"; done | sort -n | awk '{print $2}'; }
position() { order | grep -nx -- "$1" | cut -d: -f1; }

# urgent <stem>: move a queued stem to the front of the waiting items (a turn already running finishes first).
urgent() {
  local s=$1 min
  [ -f "$Q/$s" ] || { echo "$s is not queued" >&2; return 1; }
  min=$(order | head -1); min=$(qget "$min" seq)
  qput "$s" "$(qget "$s" wt)" "$(qget "$s" branch)" "$((min - 1))" "$(qget "$s" owner)" "$(qget "$s" fails)" "$(qget "$s" failhead)"
  log "$s: marked urgent; next in the merge queue (position $(position "$s"))" >> "$ORCH_PIPES/merge-queue.out"
  echo "$s is next in the merge queue (position $(position "$s"))"
}

# ---------------------------------------------------------------- item
spawn_runner() {
  local lp; lp=$(lock_pid)
  if [ ! -d "$L" ] || { [ -n "$lp" ] && ! alive "$lp"; }; then
    (nohup "$BIN/merge-queue.sh" runner >> "$ORCH_PIPES/merge-queue.out" 2>&1 < /dev/null &)
  fi
}
item() {
  local wt br stem w pf out f
  IFS=: read -r wt br stem _ <<<"$1"
  w=$ORCH_WT_PREFIX$wt; pf=$ORCH_PR/$stem.txt
  [ -d "$w" ] || { echo "$wt TRAIN rc=2"; echo "no worktree at $w"; return; }
  [ -s "$pf" ] || { echo "MERGE FAIL: no PR text at $pf"; return; }
  [ -z "$(git -C "$w" status --short)" ] || { echo "MERGE FAIL DIRTY"; return; }
  if [ -z "$(cd "$w" && gh pr list --head "$br" --state open --json url -q '.[0].url' 2>/dev/null)" ]; then
    if ! out=$(git -C "$w" push -q -u "$ORCH_REMOTE" "$br" 2>&1); then
      echo "MERGE FAIL PUSH: git push of $br rejected"; echo "$out" | grep -vE "^remote:" | tail -5; return; fi
  fi
  cd "$ORCH_REPO" || return   # the runner removes the worktree after the merge; never wait inside it
  if [ -f "$Q/$stem" ]; then   # already queued: keep the position, take over the waiting
    qput "$stem" "$wt" "$br" "$(qget "$stem" seq)" "$PPID" "$(qget "$stem" fails)" "$(qget "$stem" failhead)"
    echo "$wt already queued: keeping position $(position "$stem")"
  else
    rm -f "$R/$stem".*; qput "$stem" "$wt" "$br" "$(nextseq)" "$PPID" 0 ""
    echo "$wt queued at position $(position "$stem")"
  fi
  while :; do
    for f in "$R/$stem".*; do
      [ -f "$f" ] || continue
      tail -n +2 "$f"; [ "$(head -1 "$f")" = final ] && { rm -f "$f"; return; }; rm -f "$f"
    done
    alive "$PPID" || { [ "$(qget "$stem" owner)" = "$PPID" ] && rm -f "$Q/$stem"; return; }   # merge-seq stopped
    if [ ! -f "$Q/$stem" ]; then ls "$R/$stem".* >/dev/null 2>&1 || { echo "$wt left the merge queue"; return; }
    elif [ "$(qget "$stem" owner)" != "$PPID" ]; then echo "$wt: a newer merge-seq (pid $(qget "$stem" owner)) took over"; return; fi
    spawn_runner; nap "$ORCH_POLL"
  done
}

# ---------------------------------------------------------------- runner
# emit <stem> <final|note> <line>...: lines for the waiting item (files sorted by name = by time).
EMIT_N=0
emit() {
  local s=$1 k=$2 t f; shift 2; EMIT_N=$((EMIT_N + 1))
  f=$R/$s.$(printf '%010d%04d' "$(date +%s)" "$EMIT_N"); t=$R/.$s.$$
  { echo "$k"; printf '%s\n' "$@"; } > "$t" && mv "$t" "$f"; log "$s: $*"
}
final() { local s=$1; shift; emit "$s" final "$@"; rm -f "$Q/$s"; }
# rerun_failed <sha>: rerun the failed workflow runs of an identical commit and wait until a check is running again.
rerun_failed() {
  local id n=0 t0
  for id in $(gh run list --commit "$1" --json databaseId,conclusion -q '.[] | select(.conclusion=="failure" or .conclusion=="cancelled" or .conclusion=="timed_out") | .databaseId' 2>/dev/null); do
    gh run rerun "$id" --failed >/dev/null 2>&1 && n=$((n + 1)); done
  [ "$n" -gt 0 ] || return 1
  t0=$(date +%s); local repo; repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  until [ "$(gh api "repos/$repo/commits/$1/check-runs" --jq '[.check_runs[]|select(.status!="completed")]|length' 2>/dev/null || echo 0)" -gt 0 ]; do
    nap 10; [ $(( $(date +%s) - t0 )) -gt 300 ] && return 0; done
}
# turn <stem>: one attempt for the front item.
turn() {
  local s=$1 wt br w seq fails failhead pre post out rc G res rr=
  wt=$(qget "$s" wt); br=$(qget "$s" branch); seq=$(qget "$s" seq); fails=$(qget "$s" fails); failhead=$(qget "$s" failhead)
  w=$ORCH_WT_PREFIX$wt; out=$ORCH_LOGS/train-$wt.out; res=$ORCH_LOGS/merge-queue-$wt.out
  [ -d "$w" ] || { final "$s" "$wt TRAIN rc=2" "no worktree at $w"; return; }
  [ -z "$(git -C "$w" status --short)" ] || { final "$s" "MERGE FAIL DIRTY"; return; }
  git -C "$w" fetch -q "$ORCH_REMOTE"
  # A fix pushed from elsewhere: fast-forward the worktree to it.
  if git -C "$w" rev-parse -q --verify "$ORCH_REMOTE/$br" >/dev/null && ! git -C "$w" merge-base --is-ancestor "$ORCH_REMOTE/$br" HEAD; then
    git -C "$w" merge -q --ff-only "$ORCH_REMOTE/$br" 2>/dev/null || { final "$s" "MERGE FAIL PUSH: $ORCH_REMOTE/$br has commits the worktree lacks (not a fast-forward)"; return; }
  fi
  pre=$(git -C "$w" rev-parse HEAD)
  [ "$fails" -gt 0 ] && [ "$pre" != "$failhead" ] && fails=0   # new commits since the failure: a fresh attempt
  log "$s: turn (seq $seq, attempt $((fails + 1)))"
  "$BIN/train.sh" "$wt" "train$wt" > "$out" 2>&1; rc=$?
  if [ $rc -ne 0 ]; then final "$s" "$wt TRAIN rc=$rc" "$(tail -4 "$out")"; return; fi
  if grep -q "^tests: delegated to PR CI" "$out"; then G=$ORCH_GATES_TEXT
  elif grep -q "^gates: local ok" "$out"; then G="local gates passed (${ORCH_LOCAL_GATES}); $ORCH_GATES_TEXT"
  else final "$s" "$wt GATES FAIL" "$(tail -20 "$out")"; return; fi
  post=$(git -C "$w" rev-parse HEAD)
  if [ "$fails" -gt 0 ] && [ "$post" = "$failhead" ]; then   # identical commit: rerun its failed runs
    if [ -n "${ORCH_TURN_LABEL:-}" ]; then rr=label   # re-adding the label starts a fresh full run
    elif (cd "$w" && rerun_failed "$post"); then rr=1; else log "$s: no failed run to rerun on ${post:0:9}"; fi
  fi
  [ "$rr" = 1 ] && emit "$s" note "$wt rerunning the failed CI on ${post:0:9} (attempt 2)"
  [ "$rr" = label ] && emit "$s" note "$wt rerunning the full CI on ${post:0:9} via the $ORCH_TURN_LABEL label (attempt 2)"
  "$BIN/merge-pr.sh" "$wt" "$br" "$s" "$G" 2>&1 | grep -vE "^remote:" > "$res"
  if grep -qx "merged" "$res"; then final "$s" "$wt gates: $G" "$(cat "$res")"; return; fi
  if grep -q "^HEAD MOVED: " "$res"; then   # a fix was pushed while CI ran: not a failure; same position, same attempt count
    emit "$s" note "$wt $(grep -m1 '^HEAD MOVED: ' "$res" | cut -c13-)" "$wt stays at position $(position "$s") (not a CI failure; no attempt used)"
    return
  fi
  if grep -q "^MERGE FAIL CI: " "$res"; then
    if [ "$fails" -ge 1 ]; then
      sed -e 's/^\(MERGE FAIL CI: .*\)$/\1 (removed after 2 attempts; requeue after fixing)/' "$res" > "$res.t" && mv "$res.t" "$res"
      final "$s" "$wt gates: $G" "$(cat "$res")"; return; fi
    qput "$s" "$wt" "$br" "$(nextseq)" "$(qget "$s" owner)" 1 "$post"
    emit "$s" note "$wt gates: $G" "$(cat "$res")" "$wt moved to the end of the merge queue (position $(position "$s"))"
    return
  fi
  final "$s" "$wt gates: $G" "$(cat "$res")"
}
# Retired batch train: drain $ORCH_RUN/batch-queue with classic trains; results in its old format.
legacy() {
  local f s wt br out G res B=$D/batch-queue BR=$D/batch-result t rc
  mkdir -p "$BR"
  for f in $(for g in "$B"/*; do [ -f "$g" ] && echo "$(sed -n 's/^t=//p' "$g") $g"; done | sort -n | awk '{print $2}'); do
    s=${f##*/}; wt=$(sed -n 's/^wt=//p' "$f"); br=$(sed -n 's/^branch=//p' "$f")
    alive "$(sed -n 's/^owner=//p' "$f")" || { rm -f "$f"; continue; }
    log "$s: legacy batch-queue item, classic train"; out=$ORCH_LOGS/train-$wt.out; res=$ORCH_LOGS/merge-queue-$wt.out
    "$BIN/train.sh" "$wt" "train$wt" > "$out" 2>&1; rc=$?
    if [ $rc -ne 0 ]; then printf 'done\n%s TRAIN rc=%s\n%s\n' "$wt" "$rc" "$(tail -4 "$out")" > "$res"
    else G=$ORCH_GATES_TEXT; grep -q "^gates: local ok" "$out" && G="local gates passed (${ORCH_LOCAL_GATES}); $ORCH_GATES_TEXT"
      { echo "done"; echo "$wt gates: $G"; "$BIN/merge-pr.sh" "$wt" "$br" "$s" "$G" 2>&1 | grep -vE "^remote:"; } > "$res"; fi
    t=$BR/.$s.$$; cp "$res" "$t" && mv "$t" "$BR/$s"; rm -f "$f"
  done
}
runner() {
  local s
  reclaim "$L"; mkdir "$L" 2>/dev/null || exit 0
  echo $$ > "$L/pid"; trap '[ "$(lock_pid)" = "$$" ] && rm -rf "$L"' EXIT
  log "runner $$ started"
  while :; do
    [ -d "$D/batch-queue" ] && legacy
    s=$(order | head -1)
    [ -n "$s" ] || { log "runner $$: queue empty, exiting"; exit 0; }
    alive "$(qget "$s" owner)" || { rm -f "$Q/$s"; log "$s: merge-seq gone; dropped"; continue; }
    turn "$s"
  done
}

case "${1:-}" in
  item) item "$2" ;;
  runner) runner ;;
  urgent) urgent "${2:?usage: merge-queue.sh urgent <stem>}" ;;
  *) echo "usage: merge-queue.sh item <wt>:<branch>:<stem> | runner | urgent <stem>" >&2; exit 2 ;;
esac
