#!/bin/bash
# shellcheck disable=SC2015,SC2012  # ok/bad chains and ls counts are deliberate in this harness
# usage: queue-test.sh [scenario...]   (default: all) — local FIFO merge-train tests: a bare origin, a fake gh, no GitHub.
# Scenarios: fifo red flake twofail conflict legacy infra infraexhausted realfail headmoved urgent (ORCH_TURN_LABEL unset), label race leftover noop (label-gated CI), prelabel (setting on, workflow not yet gated)
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
  unset FAKE_TURN_LABEL FAKE_LABEL_DELAY FAKE_UNGATED ORCH_TURN_LABEL ORCH_REQUIRED_CHECK ORCH_INFRA_RERUNS ORCH_INFRA_BACKOFF ORCH_CI_RUNS_BEFORE ORCH_LOCAL_GATES ORCH_POST_MERGE ORCH_RUN ORCH_PR ORCH_LOGS ORCH_PIPES ORCH_BRIEFS ORCH_REPORTS ORCH_REVIEWS ORCH_PLANS ORCH_ARTIFACTS ORCH_SKILL_DIR
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
t_infra() {
  echo "== infra: a failure whose log shows only an HTTP 503 is rerun inside ci-wait, never counted as an attempt"; setup
  lane i infra-flake; printf '2\n' > "${ORCH_WT_PREFIX}i/infra-flake"; git -C "${ORCH_WT_PREFIX}i" commit -qam "Two infra failures."
  queue i; finish_all; show i
  has i "merged" && ok "i merged" || bad "i not merged"
  ! has i "MERGE FAIL CI" && ! has i "moved to the end" && ok "no CI failure reported, not moved to the end" || bad "infra failure was counted"
  [ "$(grep -c '^rerun ' "$FAKE_GH/triggers.log")" = 2 ] && ok "two reruns of the failed run" || bad "reruns: $(grep -c '^rerun ' "$FAKE_GH/triggers.log")"
  grep -q "infra outage in the failed CI log" "$ORCH_STATE/pipes/merge-queue.out" "$ORCH_STATE/logs/merge-queue-i.out" 2>/dev/null && ok "infra rerun logged" || bad "no infra rerun line"
}
t_infraexhausted() {
  echo "== infraexhausted: an outage that outlasts ORCH_INFRA_RERUNS counts as a failure ('infra outage persisted')"; setup
  export ORCH_INFRA_RERUNS=2
  lane i infra-always
  queue i; finish_all; show i
  has i "infra outage persisted after 2 reruns" && ok "MERGE FAIL CI says the outage persisted" || bad "no persisted line"
  has i "moved to the end of the merge queue" && has i "removed after 2 attempts" && ok "counted as 2 attempts, then removed" || bad "attempt accounting wrong"
}
t_realfail() {
  echo "== realfail: a real test failure in the log is never treated as an outage (no rerun inside ci-wait)"; setup
  lane r early-red
  queue r; finish_all
  has r "moved to the end of the merge queue" && ok "r counted as a failure" || bad "r not moved"
  ! grep -q "infra outage in the failed CI log" "$ORCH_STATE/pipes/merge-queue.out" && ok "no infra rerun" || bad "treated a real failure as an outage"
}
t_headmoved() {
  echo "== headmoved: a fix pushed while CI runs stops the wait; same position, no attempt used, new head tested"; setup
  lane h slow; lane b fb
  hold; queue h b; release
  for _ in $(seq 120); do [ "$(triggers h)" -ge 1 ] && break; sleep 0.25; done
  echo fixed > "${ORCH_WT_PREFIX}h/fix"; git -C "${ORCH_WT_PREFIX}h" add -A; git -C "${ORCH_WT_PREFIX}h" commit -qm "Fixed h."; git -C "${ORCH_WT_PREFIX}h" push -q origin h-t1
  finish_all; show h b
  has h "head moved from" && has h "requeue to test the new head" && ok "head-moved reported" || bad "no head-moved line"
  has h "stays at position 1" && ok "kept position 1" || bad "position line missing"
  ! has h "MERGE FAIL CI" && ! has h "attempt 2" && ok "no failure, no attempt used" || bad "counted as a failure"
  [ "$(merged_order)" = "h b" ] && [ "$(triggers h)" = 2 ] && ok "h merged first on the new head (2 heads), then b" || bad "order $(merged_order) triggers $(triggers h)"
}
# ---- label-gated CI (the workflow runs its full suite on a PR only while it carries the merge-turn label)
gated() { export FAKE_TURN_LABEL=merge-turn ORCH_TURN_LABEL=merge-turn ORCH_REQUIRED_CHECK=publish; }
full_runs() { local h; for h in $(heads "$1"); do grep -c "^$h $2" "$FAKE_GH/full-runs.log" 2>/dev/null; done | awk '{s+=$1} END {print s+0}'; }
cheap_runs() { local h; for h in $(heads "$1"); do grep -c "^$h .* cheap$" "$FAKE_GH/runs.log" 2>/dev/null; done | awk '{s+=$1} END {print s+0}'; }
heads() { python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("heads", [])))' "$FAKE_GH/prs/$(pr_num "$1").json"; }
labels() { gh pr view "$(pr_num "$1")" --json labels -q '.labels[].name' | paste -sd, -; }
# open_pr <name> [label]: push the lane and open its PR outside the train (a crashed or interrupted earlier turn).
open_pr() { git -C "${ORCH_WT_PREFIX}$1" push -q -u origin "$1-t1"
  gh pr create --base main --head "$1-t1" --title "Added $1" --body-file "$ORCH_STATE/pr/$1.txt" >/dev/null
  [ -z "${2:-}" ] || gh pr edit "$(pr_num "$1")" --add-label "$2"; }
t_label() {
  echo "== label: the full CI runs once per turn via the label; a fix pushed off-turn runs only the cheap jobs"; setup; gated
  lane r early-red; lane b fb
  hold; queue r b; release
  wait_line r "moved to the end of the merge queue" && ok "red r moved to the end" || bad "r not moved"
  has r "MERGE FAIL CI: unit failed on" && ok "r: MERGE FAIL CI names the failed job" || bad "no MERGE FAIL CI line"
  [ -z "$(labels r)" ] && ok "label removed when r's turn ended red" || bad "r still labeled: $(labels r)"
  git -C "${ORCH_WT_PREFIX}r" rm -q early-red; git -C "${ORCH_WT_PREFIX}r" commit -qm "Fixed r."
  git -C "${ORCH_WT_PREFIX}r" push -q origin r-t1   # the off-turn fix push
  finish_all; show r b
  [ "$(merged_order)" = "b r" ] && ok "merged b, then the fixed r" || bad "merge order: $(merged_order)"
  [ "$(full_runs b labeled)" = 1 ] && [ "$(full_runs b sync)" = 0 ] && ok "b: exactly one full run, started by the label" || bad "b full runs: labeled $(full_runs b labeled) sync $(full_runs b sync)"
  [ "$(full_runs r labeled)" = 2 ] && [ "$(full_runs r sync)" = 0 ] && ok "r: two full runs (red turn, fix turn), none from the off-turn push" || bad "r full runs: labeled $(full_runs r labeled) sync $(full_runs r sync)"
  [ "$(cheap_runs r)" = 2 ] && ok "r: the opening and the off-turn push ran only cheap jobs" || bad "r cheap runs $(cheap_runs r)"
  [ -z "$(labels b)" ] && [ -z "$(labels r)" ] && ok "no label left on merged PRs" || bad "labels left: b=$(labels b) r=$(labels r)"
  has b "added the merge-turn label" && ok "turn line: added the merge-turn label" || bad "no label line"
}
t_race() {
  echo "== race: the cheap run's skipped checks complete first; ci-wait waits for the late labeled run"; setup; gated
  export FAKE_LABEL_DELAY=4
  lane r early-red; lane g fg
  hold; queue r g; release; finish_all; show r g
  ! has r "GitHub CI passed" && has r "MERGE FAIL CI: unit failed on" && ok "red r not passed on skipped checks; failed on the full run" || bad "r passed on skipped checks"
  [ "$(merged_order)" = "g" ] && ok "only g merged" || bad "merge order: $(merged_order)"
  has g "GitHub CI passed" && [ "$(full_runs g labeled)" = 1 ] && ok "g passed on its one full run" || bad "g: full runs $(full_runs g labeled)"
}
t_leftover() {
  echo "== leftover: a label left by a crashed turn is removed and re-added, so labeled fires again"; setup; gated
  lane l fl; open_pr l merge-turn
  [ "$(full_runs l labeled)" = 1 ] && ok "the crashed turn's labeled run exists" || bad "setup: full runs $(full_runs l labeled)"
  queue l; finish_all; show l
  has l "removed a leftover merge-turn label" && has l "merged" && ok "leftover removed, re-added, merged" || bad "l not merged after leftover"
  [ "$(full_runs l labeled)" = 2 ] && ok "l: a fresh full run at its turn (the old one is not counted)" || bad "l full runs $(full_runs l labeled)"
  grep -c " unlabeled merge-turn" "$FAKE_GH/labels.log" | grep -qx 2 && ok "label removed before re-adding and after the merge" || bad "unlabel count: $(grep -c unlabeled "$FAKE_GH/labels.log")"
}
t_noop() {
  echo "== noop: an open PR whose head is already pushed (no-op push) still gets its one full run from the label"; setup; gated
  lane n fn; open_pr n
  queue n; finish_all; show n
  has n "merged" && ok "n merged" || bad "n not merged"
  [ "$(full_runs n labeled)" = 1 ] && [ "$(cheap_runs n)" = 1 ] && [ "$(heads n | wc -w | tr -d ' ')" = 1 ] && ok "n: no new head, one cheap run from opening, one full run from the label" || bad "n: full $(full_runs n labeled) cheap $(cheap_runs n) heads $(heads n)"
}
t_urgent() {
  echo "== urgent: an urgent stem queued last jumps ahead of the waiting items; the others keep their order"; setup
  lane d fd; lane b fb; lane u fu
  hold; queue d b u
  out=$("$S/merge-queue.sh" urgent u)
  echo "$out" | grep -q "u is next in the merge queue (position 1)" && ok "urgent reports position 1" || bad "urgent said: $out"
  [ "$("$S/merge-queue-len.sh" --list | awk '{print $2}' | paste -sd' ' -)" = "u d b" ] && ok "list is u d b" || bad "list: $("$S/merge-queue-len.sh" --list)"
  "$S/merge-queue.sh" urgent nosuch >/dev/null 2>&1 && bad "unknown stem accepted" || ok "unknown stem refused"
  release; finish_all; show d b u
  [ "$(merged_order)" = "u d b" ] && ok "merged u d b" || bad "merge order: $(merged_order)"
}
t_prelabel() {
  echo "== prelabel: ORCH_TURN_LABEL on while the workflow is not gated yet: the push's full run counts"; setup; gated
  export FAKE_UNGATED=1
  # (A red branch's identical-commit second attempt would get no new run here and fail after 15 min: not tested.)
  lane p fp
  queue p; finish_all; show p
  has p "GitHub CI passed" && has p "merged" && [ "$(full_runs p sync)" = 1 ] && ok "p merged on the push's full run" || bad "p: full sync runs $(full_runs p sync)"
}
[ $# -gt 0 ] || set -- fifo red flake twofail conflict legacy infra infraexhausted realfail headmoved urgent label race leftover noop prelabel
for t in "$@"; do "t_$t"; [ -n "${KEEP:-}" ] || rm -rf "$T"; done
echo "== $FAILS failure(s)"; [ "$FAILS" = 0 ]
