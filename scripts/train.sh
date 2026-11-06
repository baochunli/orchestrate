#!/bin/bash
# usage: train.sh <stem> <tag> — merge the default branch into the lane worktree, then run local gates
# if ORCH_LOCAL_GATES is set; otherwise report "tests: delegated to PR CI".
# Exit codes: 2 no worktree, 3 merge conflict (conflicted files printed), 5 local gates failed.
set -u
. "$(dirname "$0")/orch-env.sh"
wt=$ORCH_WT_PREFIX$1; tag=$2; cd "$wt" || exit 2
git fetch -q "$ORCH_REMOTE"
br=$(git branch --show-current)
M=$ORCH_REMOTE/$ORCH_MAIN; MSG="Merged current $ORCH_MAIN into the $br branch."
if ! git merge --no-edit "$M" -m "$MSG" > "$ORCH_LOGS/train-$tag-merge.log" 2>&1; then
  echo "CONFLICT"; git status --short | grep -E '^(UU|AA|DU|UD)'; exit 3
fi
if [ -z "${ORCH_LOCAL_GATES:-}" ]; then echo "tests: delegated to PR CI"; echo "HEAD $(git rev-parse HEAD)"; exit 0; fi
if bash -c "$ORCH_LOCAL_GATES" > "$ORCH_LOGS/train-$tag-gates.log" 2>&1; then echo "gates: local ok"
else echo "GATES-FAIL (see $ORCH_LOGS/train-$tag-gates.log)"; tail -20 "$ORCH_LOGS/train-$tag-gates.log"; exit 5; fi
echo "HEAD $(git rev-parse HEAD)"
