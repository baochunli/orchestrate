#!/bin/bash
# usage: merge-seq.sh <wt>:<branch>:<stem> ...   (wt = worktree suffix: worktree is "$ORCH_WT_PREFIX<wt>")
# The merge train, batched. For each item (in turn): push the branch, create or update its PR from
# $ORCH_PR/<stem>.txt, join the batch queue and wait for the verdict (merge-batch.sh item). One runner at a time
# (merge-batch.sh runner, guarded by $ORCH_RUN/merge.lock; a dead owner's lock is reclaimed) merges queued branches:
# a lone branch takes the classic single train (merge main into the lane, gates, CI on the exact commit, merge);
# several are merged together into one candidate PR on current main, one CI run, then merged as one; a red batch is
# bisected down to the failing branch. $ORCH_RUN/merge-priority names one stem that goes first.
# Output lines a supervisor must act on: "<wt> TRAIN rc=3" + CONFLICT (resolve, push, requeue),
# "MERGE FAIL CI: ..." (fix, push, requeue), "MERGE FAIL STALE/DIRTY/PUSH" (requeue / clean worktree / inspect).
# Success: "merged" then the main commit line.
. "$(dirname "$0")/orch-env.sh"
for x in "$@"; do "$ORCH_SKILL_DIR/merge-batch.sh" item "$x"; done
