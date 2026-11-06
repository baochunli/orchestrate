#!/bin/bash
# usage: merge-seq.sh <wt>:<branch>:<stem> ...   (wt = worktree suffix: worktree is "$ORCH_WT_PREFIX<wt>")
# The FIFO merge train (merge-queue.sh). For each item in turn: push the branch (only if it has no open PR), append it
# to $ORCH_RUN/merge-queue/ ("<wt> queued at position N"; an already queued stem keeps its position) and wait.
# One runner at a time (merge.lock) takes the front item: merge current main into the lane, push, create/update the
# PR (the single CI run), wait for CI on the exact commit, merge. CI red: "MERGE FAIL CI: ..." and the item moves to
# the end; at its next turn a changed head runs normally, an unchanged one gets one rerun, then it is removed.
# Output lines a supervisor must act on: "<wt> TRAIN rc=3" + CONFLICT (resolve, push, requeue),
# "MERGE FAIL CI: ..." (fix and push: the queued item picks the fix up at its turn; after "removed after 2 attempts",
# requeue), "MERGE FAIL STALE/DIRTY/PUSH" (requeue / clean worktree / inspect). Success: "merged" + the main commit line.
. "$(dirname "$0")/orch-env.sh"
for x in "$@"; do "$ORCH_SKILL_DIR/merge-queue.sh" item "$x"; done
