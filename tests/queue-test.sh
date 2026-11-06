#!/bin/bash
# shellcheck disable=SC2015,SC2012  # ok/bad chains and ls counts are deliberate in this harness
# usage: queue-test.sh [scenario...]   (default: all) — local FIFO merge-train tests: a bare origin, a fake gh, no GitHub.
# Scenarios: fifo red flake twofail conflict legacy
set -u
HERE=$(cd "$(dirname "$0")" && pwd); S=${ORCH_TEST_SCRIPTS:-$(cd "$HERE/../scripts" && pwd)}
FAILS=0
ok() { echo "  ok: $*"; }
bad() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }
setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/mqtest.XXXXXX"); export T
  mkdir -p "$T/bin" "$T/gh"
  printf '#!/bin/sh\nexec python3 -I %s "$@"\n' "$HERE/fake-gh.py" > "$T/bin/gh"
  printf '#!/bin/sh\necho %s\n' "'{\"result\":{\"agents\":[]}}'" > "$T/bin/herdr"; chmod +x "$T/bin/gh" "$T/bin/herdr"
  export PATH="$T/bin:$PATH" FAKE_GH=$T/gh FAKE_BARE=$T/origin.git
  export ORCH_REPO=$T/app ORCH_STATE=$T/state ORCH_WT_PREFIX=$T/app- ORCH_POLL=1 ORCH_CI_SLEEP=1 ORCH_CI_GATE=on
  unset ORCH_LOCAL_GATES ORCH_POST_MERGE ORCH_RUN ORCH_PR ORCH_LOGS ORCH_PIPES ORCH_BRIEFS ORCH_REPORTS ORCH_REVIEWS ORCH_PLANS ORCH_ARTIFACTS ORCH_SKILL_DIR
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
  git init -q --bare -b main "$FAKE_BARE"; git clone -q "$FAKE_BARE" "$ORCH_REPO" 2>/dev/null
  printf 'one\ntwo\nthree\n' > "$ORCH_REPO/shared.txt"; git -C "$ORCH_REPO" add -A; git -C "$ORCH_REPO" commit -qm init
  git -C "$ORCH_REPO" push -q origin HEAD:main; git -C "$ORCH_REPO" branch -q -u origin/main
  mkdir -p "$ORCH_STATE/pr" "$ORCH_STATE/run"; PIDS=()
}
# lane <name> <file>...: worktree app-<name>, branch <name>-t1, one commit adding the files, PR text.
lane() {
  local n=$1 f w=$ORCH_WT_PREFIX$1; shift
  git -C "$ORCH_REPO" fetch -q origin; git -C "$ORCH_REPO" worktree add -q -b "$n-t1" "$w" origin/main 2>/dev/null
  for f in "$@"; do case "$f" in shared=*) printf 'one\n%s\nthree\n' "${f#shared=}" > "$w/shared.txt" ;; *) echo "$n" > "$w/$f" ;; esac; done
  git -C "$w" add -A; git -C "$w" commit -qm "Added $n."
  printf 'Added %s\n\nBody for %s.\n\nGates: [GATES]\n' "$n" "$n" > "$ORCH_STATE/pr/$n.txt"
}
main_commit() { local f; for f in "$@"; do case "$f" in shared=*) printf 'one\n%s\nthree\n' "${f#shared=}" > "$ORCH_REPO/shared.txt" ;; *) echo main > "$ORCH_REPO/$f" ;; esac; done
  git -C "$ORCH_REPO" add -A; git -C "$ORCH_REPO" commit -qm "Main change."; git -C "$ORCH_REPO" push -q origin HEAD:main; }
hold() { mkdir "$ORCH_STATE/run/merge.lock"; sleep 900 & HOLD=$!; echo $HOLD > "$ORCH_STATE/run/merge.lock/pid"; }
release() { kill "$HOLD"; wait "$HOLD" 2>/dev/null; }
# queue <name>...: one merge-seq each, started in order (each waits until the previous one is queued).
queue() { local n _; for n in "$@"; do "$S/merge-seq.sh" "$n:$n-t1:$n" >> "$T/out-$n" 2>&1 & PIDS+=($!)
  for _ in $(seq 60); do grep -q "queued at position\|already queued\|TRAIN rc=\|MERGE FAIL" "$T/out-$n" 2>/dev/null && break; sleep 0.2; done; done; }
finish_all() { local p _; for p in "${PIDS[@]}"; do wait "$p"; done
  for _ in $(seq 60); do [ -d "$ORCH_STATE/run/merge.lock" ] || break; sleep 1; done; }
wait_line() { local _; for _ in $(seq 240); do grep -qF -- "$2" "$T/out-$1" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
has() { grep -qF -- "$2" "$T/out-$1"; }
pr_state() { gh pr list --state all --head "$1-t1" --json state -q '.[0].state'; }
pr_num() { gh pr list --state all --head "$1-t1" --json number -q '.[0].number'; }
triggers() { grep -c " $1-t1 " "$FAKE_GH/triggers.log" 2>/dev/null || echo 0; }
merged_order() { sed 's/^#[0-9]* //; s/-t1$//' "$FAKE_GH/merges.log" 2>/dev/null | paste -sd' ' -; }
show() { local n; for n in "$@"; do echo "  --- out-$n"; sed 's/^/    /' "$T/out-$n"; done
  echo "  --- runner log"; sed 's/^/    /' "$ORCH_STATE/pipes/merge-queue.out" 2>/dev/null; }

t_fifo() {
  echo "== fifo: four branches merge one by one in enqueue order; no CI before each one's turn"; setup
  lane d fd; lane b fb; lane c fc; lane a fa
  hold; queue d b c a
  has d "queued at position 1" && has b "queued at position 2" && has c "queued at position 3" && has a "queued at position 4" && ok "positions 1-4 in enqueue order" || bad "positions wrong"
  [ ! -s "$FAKE_GH/triggers.log" ] && ! grep -q "^pr create" "$FAKE_GH/calls.log" 2>/dev/null && ok "no PR opened and no CI started while queued" || bad "CI/PR before the turn"
  [ "$("$S/merge-queue-len.sh" --list | awk '{print $2}' | paste -sd' ' -)" = "d b c a" ] && ok "merge-queue-len.sh --list shows d b c a" || bad "list: $("$S/merge-queue-len.sh" --list)"
  release; finish_all; show d b c a
  [ "$(merged_order)" = "d b c a" ] && ok "merged in FIFO order: d b c a" || bad "merge order: $(merged_order)"
  for n in d b c a; do has $n "merged" && [ "$(triggers $n)" = 1 ] && ok "$n merged after exactly one CI run" || bad "$n: triggers $(triggers $n)"; done
  for l in "d gates: full suite in PR CI" "waiting for GitHub CI on" "GitHub CI passed" "merged"; do has d "$l" && ok "classic line: $l" || bad "missing: $l"; done
  tail -1 "$T/out-a" | grep -q "Merge pull request #$(pr_num a) from a-t1" && ok "last line is the main commit" || bad "last line: $(tail -1 "$T/out-a")"
  git -C "$FAKE_BARE" log --format=%s main | grep -q "Merged current main into the a-t1 branch." && ok "main merged into each lane before its CI" || bad "no merge commit"
}
t_red() {
  echo "== red: a red branch moves to the end, the next merges; a pushed fix runs normally at its next turn"; setup
  lane r early-red; lane b fb; lane c fc
  hold; queue r b c; release
  wait_line r "moved to the end of the merge queue" && ok "r moved to the end" || bad "r not moved"
  has r "MERGE FAIL CI: unit failed on" && ok "r printed MERGE FAIL CI" || bad "no MERGE FAIL CI"
  git -C "${ORCH_WT_PREFIX}r" rm -q early-red; git -C "${ORCH_WT_PREFIX}r" commit -qm "Fixed r."
  queue r   # supervisor requeue: keeps the position
  wait_line r "already queued: keeping position" && ok "requeue keeps the position" || bad "requeue lost position"
  finish_all; show r b c
  [ "$(merged_order)" = "b c r" ] && ok "merged b c, then the fixed r" || bad "merge order: $(merged_order)"
  [ "$(triggers r)" = 2 ] && ok "r: two CI runs (red, then the fix)" || bad "r triggers $(triggers r)"
  has r "a newer merge-seq" && ok "the first r waiter handed over" || bad "no handover line"
}
t_flake() {
  echo "== flake: an unchanged red branch gets one rerun on the identical commit and merges"; setup
  lane f flaky
  queue f; finish_all; show f
  has f "moved to the end of the merge queue" && has f "rerunning the failed CI" && has f "merged" && ok "f red, moved, reran on the same commit, merged" || bad "f not rerun/merged"
  [ "$(triggers f)" = 1 ] && grep -q "^rerun " "$FAKE_GH/triggers.log" && ok "f: one push + one rerun, no new commit" || bad "f triggers $(triggers f)"
}
t_twofail() {
  echo "== twofail: a branch red twice with no new commits is removed"; setup
  lane r early-red; lane b fb
  hold; queue r b; release; finish_all; show r b
  has r "(removed after 2 attempts; requeue after fixing)" && ok "r removed after 2 attempts" || bad "no removal line"
  [ ! -e "$ORCH_STATE/run/merge-queue/r" ] && [ "$(pr_state r)" = OPEN ] && ok "r out of the queue, PR left open" || bad "r still queued"
  has b "merged" && ok "b merged" || bad "b not merged"
}
t_conflict() {
  echo "== conflict: a branch that conflicts with main gets rc=3 at its turn and leaves the queue"; setup
  lane d shared=dee; lane b fb; main_commit shared=main
  hold; queue d b; release; finish_all; show d b
  has d "d TRAIN rc=3" && has d "CONFLICT" && has d "UU shared.txt" && ok "d: rc=3 + CONFLICT + UU shared.txt" || bad "d lines missing"
  [ ! -e "$ORCH_STATE/run/merge-queue/d" ] && [ -z "$(pr_state d)" ] && ok "d removed, no PR, no CI" || bad "d still queued or PR opened"
  has b "merged" && ok "b merged" || bad "b not merged"
}
t_legacy() {
  echo "== legacy: an item left in the retired batch queue is drained with a classic train"; setup
  lane l fl; git -C "${ORCH_WT_PREFIX}l" push -q -u origin l-t1
  sleep 900 & OWN=$!; mkdir -p "$ORCH_STATE/run/batch-queue" "$ORCH_STATE/pipes"
  printf 'wt=l\nbranch=l-t1\nstem=l\npr=\nurl=\nhead=x\nowner=%s\nt=1\n' "$OWN" > "$ORCH_STATE/run/batch-queue/l"
  "$S/merge-batch.sh" runner >> "$ORCH_STATE/pipes/merge-queue.out" 2>&1
  kill "$OWN"; wait "$OWN" 2>/dev/null
  head -1 "$ORCH_STATE/run/batch-result/l" | grep -qx "done" && grep -qx merged "$ORCH_STATE/run/batch-result/l" && ok "batch-result/l: done + merged" || bad "legacy result: $(cat "$ORCH_STATE/run/batch-result/l" 2>/dev/null)"
}
[ $# -gt 0 ] || set -- fifo red flake twofail conflict legacy
for t in "$@"; do "t_$t"; [ -n "${KEEP:-}" ] || rm -rf "$T"; done
echo "== $FAILS failure(s)"; [ "$FAILS" = 0 ]
