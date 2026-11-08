#!/bin/bash
# usage: merge-pr.sh <stem> <branch> <prfile-stem> "<gates text>"
# Pushes the lane, creates or updates its PR from $ORCH_PR/<prfile-stem>.txt (line 1 = title, line 3+ = body,
# "[GATES]" replaced by the gates text), waits for every check on the EXACT pushed commit (ORCH_CI_GATE=on), merges
# with --match-head-commit (CI wait: ci-wait.sh), then removes the worktree and branch. Prints "MERGE FAIL ..." and leaves the PR open on failure.
# Exit 4 + "HEAD MOVED: ..." (from ci-wait.sh): the PR head changed while waiting; not a CI failure, the PR stays open.
# ORCH_TURN_LABEL set (label-gated CI): records the commit's existing workflow runs before the push, then removes the
# label if a crashed turn left it and adds it, so the "labeled" event starts the one full run even when the push was a
# no-op; ci-wait.sh judges only runs started after that point. The label is removed whenever this script exits.
set -euo pipefail
. "$(dirname "$0")/orch-env.sh"
wt=$ORCH_WT_PREFIX$1; br=$2; pf=$ORCH_PR/$3.txt; gates=$4
[ -s "$pf" ] || { echo "MERGE FAIL: no PR text at $pf"; exit 1; }
cd "$wt"; git fetch -q "$ORCH_REMOTE"
git merge-base --is-ancestor "$ORCH_REMOTE/$ORCH_MAIN" HEAD || { echo "MERGE FAIL STALE: $ORCH_MAIN moved"; exit 1; }
[ -z "$(git status --short)" ] || { echo "MERGE FAIL DIRTY"; exit 1; }
python3 - "$pf" "$gates" <<'PY'
import sys; p,g=sys.argv[1],sys.argv[2]; s=open(p).read()
if "[GATES]" in s: s=s.replace("[GATES]", g)
open(p,"w").write(s)
PY
H=$(git rev-parse HEAD)
if [ -n "${ORCH_TURN_LABEL:-}" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  ORCH_CI_RUNS_BEFORE=$(gh api "repos/$REPO/actions/runs?head_sha=$H&event=pull_request&per_page=100" --jq '.workflow_runs[].id' 2>/dev/null | paste -sd' ' - || true)
  export ORCH_CI_RUNS_BEFORE
fi
git push -q -u "$ORCH_REMOTE" "$br"
T=$(head -1 "$pf"); tail -n +3 "$pf" > "$pf.body"
# A CI failure leaves the PR open; a later run reuses it (the push already updated its head).
URL=$(gh pr list --head "$br" --state open --json url -q '.[0].url' 2>/dev/null || true)
if [ -n "$URL" ]; then gh pr edit "$URL" --title "$T" --body-file "$pf.body" >/dev/null
else URL=$(gh pr create --base "$ORCH_MAIN" --head "$br" --title "$T" --body-file "$pf.body"); fi
echo "$URL"
if [ -n "${ORCH_TURN_LABEL:-}" ]; then
  trap 'gh pr edit "$URL" --remove-label "$ORCH_TURN_LABEL" >/dev/null 2>&1 || true' EXIT
  labels=$(gh pr view "$URL" --json labels -q '.labels[].name' 2>/dev/null || true)
  if grep -qxF "$ORCH_TURN_LABEL" <<<"$labels"; then
    gh pr edit "$URL" --remove-label "$ORCH_TURN_LABEL" >/dev/null; echo "removed a leftover $ORCH_TURN_LABEL label"; fi
  gh pr edit "$URL" --add-label "$ORCH_TURN_LABEL" >/dev/null 2>&1 ||
    { gh label create "$ORCH_TURN_LABEL" --description "Merge-queue turn: run the full CI" >/dev/null 2>&1; gh pr edit "$URL" --add-label "$ORCH_TURN_LABEL" >/dev/null; } ||
    { echo "MERGE FAIL CI: could not add the $ORCH_TURN_LABEL label to $URL"; exit 1; }
  echo "added the $ORCH_TURN_LABEL label (the full CI run for this turn)"
fi
sleep "${ORCH_CI_SLEEP:-10}"
"$ORCH_SKILL_DIR/ci-wait.sh" "$URL" "$H" || exit $?   # rc 4 = "HEAD MOVED" (not a CI failure)
gh pr merge "$URL" --merge --match-head-commit "$H" || true
for _ in 1 2 3 4 5 6; do [ "$(gh pr view "$URL" --json state -q .state)" = MERGED ] && break; sleep "${ORCH_CI_SLEEP:-10}"; done
[ "$(gh pr view "$URL" --json state -q .state)" = MERGED ] || { echo "MERGE FAIL: $URL not merged"; exit 1; }; echo merged
[ -n "${ORCH_POST_MERGE:-}" ] && (nohup bash -c "$ORCH_POST_MERGE" _ "$wt" "$br" "$3" >/dev/null 2>&1 &)
cd "$ORCH_REPO"; git fetch -q "$ORCH_REMOTE" "$ORCH_MAIN" && git merge -q --ff-only "$ORCH_REMOTE/$ORCH_MAIN" || echo "note: main checkout not fast-forwarded"
(nohup "$ORCH_SKILL_DIR/cleanup-merged.sh" "$wt" "$3" >/dev/null 2>&1 &)
git worktree remove --force "$wt"; git branch -D "$br" >/dev/null; git push -q "$ORCH_REMOTE" --delete "$br" 2>/dev/null || true
git log --oneline -1 | cat
