#!/bin/bash
# usage: merge-pr.sh <stem> <branch> <prfile-stem> "<gates text>"
# Pushes the lane, creates or updates its PR from $ORCH_STATE/pr/<prfile-stem>.txt (line 1 = title, line 3+ = body,
# "[GATES]" replaced by the gates text), waits for every check on the EXACT pushed commit (ORCH_CI_GATE=on), merges
# with --match-head-commit, then removes the worktree and branch. Prints "MERGE FAIL ..." and leaves the PR open on failure.
set -euo pipefail
. "$(dirname "$0")/orch-env.sh"
wt=$ORCH_WT_PREFIX$1; br=$2; pf=$ORCH_STATE/pr/$3.txt; gates=$4
[ -s "$pf" ] || { echo "MERGE FAIL: no PR text at $pf"; exit 1; }
cd "$wt"; git fetch -q "$ORCH_REMOTE"
git merge-base --is-ancestor "$ORCH_REMOTE/$ORCH_MAIN" HEAD || { echo "MERGE FAIL STALE: $ORCH_MAIN moved"; exit 1; }
[ -z "$(git status --short)" ] || { echo "MERGE FAIL DIRTY"; exit 1; }
python3 - "$pf" "$gates" <<'PY'
import sys; p,g=sys.argv[1],sys.argv[2]; s=open(p).read()
if "[GATES]" in s: s=s.replace("[GATES]", g)
open(p,"w").write(s)
PY
git push -q -u "$ORCH_REMOTE" "$br"
T=$(head -1 "$pf"); tail -n +3 "$pf" > "$pf.body"
# A CI failure leaves the PR open; a later run reuses it (the push already updated its head).
URL=$(gh pr list --head "$br" --state open --json url -q '.[0].url' 2>/dev/null || true)
if [ -n "$URL" ]; then gh pr edit "$URL" --title "$T" --body-file "$pf.body" >/dev/null
else URL=$(gh pr create --base "$ORCH_MAIN" --head "$br" --title "$T" --body-file "$pf.body"); fi
echo "$URL"; sleep 10
if [ "$ORCH_CI_GATE" = on ]; then
  echo "waiting for GitHub CI on $URL"; t0=$(date +%s)
  # Wait for check runs on the exact pushed commit, so an earlier head's green checks cannot pass the gate.
  HS=$(git rev-parse HEAD); REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  until [ "$(gh api "repos/$REPO/commits/$HS/check-runs" --jq '.total_count' 2>/dev/null || echo 0)" -gt 0 ]; do
    sleep 20; [ $(( $(date +%s) - t0 )) -gt 900 ] && { echo "MERGE FAIL CI: no checks for $HS after 15 min"; exit 1; }; done
  until [ "$(gh api "repos/$REPO/commits/$HS/check-runs" --jq '[.check_runs[]|select(.status!="completed")]|length' 2>/dev/null || echo 1)" = 0 ]; do
    sleep 60; [ $(( $(date +%s) - t0 )) -gt 10800 ] && { echo "MERGE FAIL CI: $HS still pending after 180 min"; exit 1; }; done
  until [ -n "$(gh pr checks "$URL" --json name -q '.[].name' 2>/dev/null)" ]; do
    sleep 30; [ $(( $(date +%s) - t0 )) -gt 900 ] && { echo "MERGE FAIL CI: no checks registered on $URL after 15 min"; exit 1; }; done
  while [ -n "$(gh pr checks "$URL" --json bucket -q '.[] | select(.bucket=="pending") | .bucket' 2>/dev/null)" ]; do
    sleep 60; [ $(( $(date +%s) - t0 )) -gt 10800 ] && { echo "MERGE FAIL CI: still pending after 180 min on $URL"; exit 1; }; done
  bad=$(gh pr checks "$URL" --json name,bucket -q '.[] | select(.bucket=="fail" or .bucket=="cancel") | .name' | paste -sd, -)
  [ -z "$bad" ] || { echo "MERGE FAIL CI: $bad failed on $URL (PR left open)"; exit 1; }
  echo "GitHub CI passed ($(( ($(date +%s) - t0) / 60 )) min)"
else echo "CI gate off; merging without waiting"; fi
H=$(git rev-parse HEAD); gh pr merge "$URL" --merge --match-head-commit "$H" || true
for i in 1 2 3 4 5 6; do [ "$(gh pr view "$URL" --json state -q .state)" = MERGED ] && break; sleep 10; done
[ "$(gh pr view "$URL" --json state -q .state)" = MERGED ] || { echo "MERGE FAIL: $URL not merged"; exit 1; }; echo merged
[ -n "${ORCH_POST_MERGE:-}" ] && (nohup bash -c "$ORCH_POST_MERGE" _ "$wt" "$br" "$3" >/dev/null 2>&1 &)
cd "$ORCH_REPO"; git fetch -q "$ORCH_REMOTE" "$ORCH_MAIN" && git merge -q --ff-only "$ORCH_REMOTE/$ORCH_MAIN" || echo "note: main checkout not fast-forwarded"
(nohup "$ORCH_SKILL_DIR/cleanup-merged.sh" "$wt" "$3" >/dev/null 2>&1 &)
git worktree remove --force "$wt"; git branch -D "$br" >/dev/null; git push -q "$ORCH_REMOTE" --delete "$br" 2>/dev/null || true
git log --oneline -1 | cat
