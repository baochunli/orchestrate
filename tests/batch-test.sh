#!/bin/bash
# shellcheck disable=SC2015,SC2012  # ok/bad chains and ls counts are deliberate in this harness
# usage: batch-test.sh [scenario...]   (default: all)  — local merge-train tests: a bare origin, a fake gh, no GitHub.
# Scenarios: green conflict conflictpr refresh mates bisect pair gherr early single
set -u
HERE=$(cd "$(dirname "$0")" && pwd); S=${ORCH_TEST_SCRIPTS:-$(cd "$HERE/../scripts" && pwd)}
FAILS=0
ok() { echo "  ok: $*"; }
bad() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }
setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/mbtest.XXXXXX"); export T
  mkdir -p "$T/bin" "$T/gh"
  printf '#!/bin/sh\nexec python3 -I %s "$@"\n' "$HERE/fake-gh.py" > "$T/bin/gh"
  printf '#!/bin/sh\necho %s\n' "'{\"result\":{\"agents\":[]}}'" > "$T/bin/herdr"; chmod +x "$T/bin/gh" "$T/bin/herdr"
  export PATH="$T/bin:$PATH" FAKE_GH=$T/gh FAKE_BARE=$T/origin.git
  export ORCH_REPO=$T/app ORCH_STATE=$T/state ORCH_WT_PREFIX=$T/app- ORCH_POLL=1 ORCH_CI_SLEEP=1 ORCH_BATCH_EARLY_MAX=40 ORCH_CI_GATE=on
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
queue() { local n; for n in "$@"; do "$S/merge-seq.sh" "$n:$n-t1:$n" > "$T/out-$n" 2>&1 & PIDS+=($!); done; }
release_when_queued() { # release the held lock once all <n> items sit in the batch queue (so they batch together)
  local _; for _ in $(seq 120); do [ "$(ls "$ORCH_STATE/run/batch-queue" 2>/dev/null | wc -l | tr -d ' ')" -ge "$1" ] && break; sleep 1; done
  [ "${2:-1}" = 0 ] || { kill "$HOLD"; wait "$HOLD" 2>/dev/null; }; }
finish_all() { local p; for p in "${PIDS[@]}"; do wait "$p"; done
  for _ in $(seq 60); do [ -d "$ORCH_STATE/run/merge.lock" ] || break; sleep 1; done; }
has() { grep -qF -- "$2" "$T/out-$1"; }
batch_prs() { gh pr list --state all --json title,state -q '.[] | select(.title|startswith("Merge train batch")) | .state + " " + .title'; }
pr_num() { gh pr list --state all --head "$1-t1" --json number -q '.[0].number'; }
pr_state() { gh pr list --state all --head "$1-t1" --json state -q '.[0].state'; }
show() { local n; for n in "$@"; do echo "  --- out-$n"; sed 's/^/    /' "$T/out-$n"; done; echo "  --- batch PRs"; batch_prs | sed 's/^/    /'
  echo "  --- runner log"; sed 's/^/    /' "$ORCH_STATE/pipes/merge-batch.out" 2>/dev/null; }

t_green() {
  echo "== green: three branches merge in one batch, one CI run"; setup; lane a fa; lane b fb; lane c fc
  hold; queue a b c; release_when_queued 3; finish_all; show a b c
  for n in a b c; do has $n "merged" && [ "$(pr_state $n)" = MERGED ] && ok "$n merged" || bad "$n not merged"; done
  [ "$(batch_prs | grep -c '^MERGED')" = 1 ] && [ "$(batch_prs | wc -l | tr -d ' ')" = 1 ] && ok "one batch PR, merged" || bad "batch PRs: $(batch_prs)"
  [ "$(wc -l < "$FAKE_GH/merges.log" | tr -d ' ')" = 1 ] && ok "one merge into main" || bad "merges: $(cat "$FAKE_GH/merges.log")"
  n=$(git -C "$FAKE_BARE" rev-parse main^2); grep -q "^$n " "$FAKE_GH/ci-runs.log" && [ "$(grep -c "" "$FAKE_GH/ci-runs.log")" = 4 ] && ok "CI: 3 early runs + 1 batch run" || bad "ci runs: $(cat "$FAKE_GH/ci-runs.log")"
  [ -z "$(ls "$ORCH_STATE/run/batch-queue")" ] && [ ! -d "$ORCH_STATE/run/merge.lock" ] && ok "queue empty, lock released" || bad "leftover queue/lock"
  [ ! -d "${ORCH_WT_PREFIX}a" ] && ! git -C "$FAKE_BARE" rev-parse -q --verify refs/heads/a-t1 >/dev/null && ok "lane worktree and branch removed" || bad "lane a not cleaned"
}
t_conflict() {
  echo "== conflict: a branch that conflicts with main at enqueue gets rc=3 and is not queued; the rest merge"; setup
  lane a fa; lane b fb; lane d shared=dee; main_commit shared=main
  hold; queue a b d; release_when_queued 2; finish_all; show a b d
  has d "d TRAIN rc=3" && has d "CONFLICT" && has d "UU shared.txt" && ok "d: rc=3 + CONFLICT + UU shared.txt" || bad "d conflict lines missing"
  ! has d "queued for the merge batch" && [ -z "$(pr_state d)" ] && ok "d not queued, no PR opened" || bad "d was queued"
  git -C "${ORCH_WT_PREFIX}d" status --short | grep -q "^UU shared.txt" && ok "d's merge left for the resolver" || bad "d worktree not mid-merge"
  for n in a b; do has $n "merged" && ok "$n merged" || bad "$n not merged"; done
  [ "$(batch_prs | grep -c '^MERGED')" = 1 ] && ok "a+b in one batch" || bad "batch PRs: $(batch_prs)"
}
t_conflictpr() {
  echo "== conflictpr: main conflicts with a queued PR (GitHub gives it no CI): evicted with rc=3, no waiting"; setup
  lane x shared=ex; lane y fy
  hold; queue x y; release_when_queued 2 0; main_commit shared=main; kill "$HOLD"; wait "$HOLD" 2>/dev/null
  finish_all; show x y
  has x "x TRAIN rc=3" && has x "CONFLICT" && has x "UU shared.txt" && ok "x: rc=3 + CONFLICT + UU shared.txt" || bad "x conflict lines missing"
  [ ! -e "$FAKE_GH/ci/$(git -C "${ORCH_WT_PREFIX}x" rev-parse HEAD)" ] && ok "x's conflicting head never got checks" || bad "x got checks"
  has y "merged" && ok "y merged" || bad "y not merged"
}
t_refresh() {
  echo "== refresh: main moves while items wait: they merge main, early CI reruns; one now fails early"; setup
  lane a fa; lane e needs-old-api
  hold; queue a e; release_when_queued 2 0; main_commit new-api; kill "$HOLD"; wait "$HOLD" 2>/dev/null
  finish_all; show a e
  grep -q "a: merged current main into the branch (early CI restarts)" "$ORCH_STATE/pipes/merge-batch.out" && ok "a refreshed by the runner" || bad "no refresh logged"
  has a "PR head moved: requeued at" && has a "merged" && ok "a requeued at its new head and merged" || bad "a lines missing"
  has e "MERGE FAIL CI: unit failed on" && has e "early PR CI" && ok "e (breaks on the new main) evicted on early CI" || bad "e lines missing"
  git -C "$FAKE_BARE" ls-tree -r --name-only main | grep -q needs-old-api && bad "e reached main" || ok "e not in main"
}
t_bisect() {
  echo "== bisect: red batch [a b c e] (c+e red together) isolates e; a b c merge"; setup
  lane a fa; lane b fb; lane c pair-a; lane e pair-b
  hold; queue a b c e; release_when_queued 4; finish_all; show a b c e
  has e "MERGE FAIL CI: unit failed on" && has e "(isolated in batch)" && ok "e: MERGE FAIL CI ... (isolated in batch)" || bad "e isolation line missing"
  [ "$(pr_state e)" = OPEN ] && ok "e PR left open" || bad "e PR $(pr_state e)"
  for n in a b c; do has $n "merged" && [ "$(pr_state $n)" = MERGED ] && ok "$n merged" || bad "$n not merged"; done
  git -C "$FAKE_BARE" ls-tree -r --name-only main | grep -q pair-b && bad "e reached main" || ok "e not in main"
}
t_mates() {
  echo "== mates: two branches that conflict only with each other: the first merges, the second gets rc=3 next round"; setup
  lane a fa; lane m1 shared=mone; lane m2 shared=mtwo
  hold; queue a m1 m2; release_when_queued 3; finish_all; show a m1 m2
  for n in a m1; do has $n "merged" && ok "$n merged" || bad "$n not merged"; done
  has m2 "m2 TRAIN rc=3" && has m2 "shared.txt" && ok "m2 evicted with rc=3 after m1 merged" || bad "m2 lines missing"
  grep -q "m2: conflicts only with batch-mates; next round" "$ORCH_STATE/pipes/merge-batch.out" && ok "m2 deferred once" || bad "no deferral logged"
  [ "$(grep -c "conflicts only with batch-mates" "$ORCH_STATE/pipes/merge-batch.out")" = 1 ] && ok "no repeated rounds" || bad "deferral repeated"
}
t_pair() {
  echo "== pair: a1 and b1 are green alone but red together, in different halves: a1 merges, b1 is isolated"; setup
  lane a1 pair-a; lane a2 fa2; lane b1 pair-b; lane b2 fb2
  hold; queue a1 a2 b1 b2; release_when_queued 4; finish_all; show a1 a2 b1 b2
  for n in a1 a2 b2; do has $n "merged" && [ "$(pr_state $n)" = MERGED ] && ok "$n merged" || bad "$n not merged"; done
  has b1 "MERGE FAIL CI: unit failed on" && has b1 "(isolated in batch)" && ok "b1: MERGE FAIL CI ... (isolated in batch)" || bad "b1 isolation line missing"
  local c red=0; for c in $(git -C "$FAKE_BARE" rev-list main); do
    git -C "$FAKE_BARE" ls-tree -r --name-only "$c" | grep -qx pair-a && git -C "$FAKE_BARE" ls-tree -r --name-only "$c" | grep -qx pair-b && red=1; done
  [ "$red" = 0 ] && ok "main never held the red combination" || bad "main went red"
}
t_gherr() {
  echo "== gherr: while gh fails the runner frees merge.lock and backs off; the item merges once gh recovers"; setup
  export ORCH_BATCH_BACKOFF=3; lane a fa
  hold; queue a; release_when_queued 1 0; touch "$FAKE_GH/fail-view"; kill "$HOLD"; wait "$HOLD" 2>/dev/null
  local _; for _ in $(seq 60); do grep -q "releasing merge.lock" "$ORCH_STATE/pipes/merge-batch.out" 2>/dev/null && break; sleep 1; done
  [ ! -d "$ORCH_STATE/run/merge.lock" ] && ok "merge.lock free during the backoff" || bad "lock still held"
  sleep 2; grep -q "gh errors (1): releasing merge.lock" "$ORCH_STATE/pipes/merge-batch.out" && ok "runner released the lock on gh errors" || bad "no release logged"
  [ -s "$ORCH_STATE/run/batch-backoff" ] && ok "backoff recorded" || bad "no backoff file"
  rm -f "$FAKE_GH/fail-view"; finish_all; show a
  has a "merged" && ok "a merged after gh recovered" || bad "a not merged"
  [ "$(grep -c "runner .* started" "$ORCH_STATE/pipes/merge-batch.out")" -ge 2 ] && ok "a new runner took over" || bad "no second runner"
  unset ORCH_BATCH_BACKOFF
}
t_early() {
  echo "== early CI: an early-red branch is evicted before batching; a slow (pending) branch is waited for"; setup
  lane a fa; lane f early-red; lane g slow
  hold; queue a f g; release_when_queued 3; finish_all; show a f g
  has f "MERGE FAIL CI: unit failed on" && has f "early PR CI" && ok "f evicted on early CI" || bad "f early eviction missing"
  for n in a g; do has $n "merged" && ok "$n merged" || bad "$n not merged"; done
  [ "$(batch_prs)" = "MERGED Merge train batch: #$(pr_num a), #$(pr_num g)" ] && grep -q "candidate .*: a g$" "$ORCH_STATE/pipes/merge-batch.out" \
    && ok "a and g (pending, then green) merged as one batch" || bad "batch PRs: $(batch_prs)"
}
t_single() {
  echo "== single: a lone branch takes the classic train (merge main into the lane, CI on its own PR, merge)"; setup
  lane a fa; main_commit fm
  queue a; finish_all; show a
  for l in "https://github.com/o/r/pull/1" "a gates: full suite in PR CI" "waiting for GitHub CI on https://github.com/o/r/pull/1" "GitHub CI passed" "merged"; do
    has a "$l" && ok "line: $l" || bad "missing line: $l"; done
  [ -z "$(batch_prs)" ] && ok "no batch PR" || bad "batch PR opened for a single item"
  git -C "$FAKE_BARE" log --format=%s main | grep -q "Merged current main into the a-t1 branch." && ok "main was merged into the lane (classic train)" || bad "no classic merge commit"
  tail -1 "$T/out-a" | grep -q "Merge pull request #1 from a-t1" && ok "last line is the main commit" || bad "last line: $(tail -1 "$T/out-a")"
  grep -q "Gates: full suite in PR CI" "$ORCH_STATE/pr/a.txt" && ok "[GATES] replaced" || bad "[GATES] not replaced"
}
[ $# -gt 0 ] || set -- green conflict conflictpr refresh mates bisect pair gherr early single
for t in "$@"; do "t_$t"; done
echo "== $FAILS failure(s)"; [ "$FAILS" = 0 ]
