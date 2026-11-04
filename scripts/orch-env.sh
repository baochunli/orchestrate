#!/bin/bash
# Sourced by every orchestrate script. Override any value in the environment or in $ORCH_STATE/env.sh.
#   ORCH_REPO       main checkout of the repo (default: git toplevel of the current directory)
#   ORCH_STATE      state dir (default: ~/.local/share/orchestrate/<repo-name>); typed subfolders below (ORCH_BRIEFS ...)
#   ORCH_WT_PREFIX  worktree path prefix; a lane's worktree is "$ORCH_WT_PREFIX<stem>" (default: "$ORCH_REPO-")
#   ORCH_REMOTE     git remote (default: origin);  ORCH_MAIN  default branch (default: main)
#   ORCH_LOCAL_GATES  optional shell command run in the worktree after merging main (empty = gates delegated to PR CI)
#   ORCH_CI_GATE    "on" (default) = wait for every check on the exact pushed commit before merging; "off" = merge without waiting
#   ORCH_GATES_TEXT text substituted for [GATES] in PR bodies when gates are delegated to PR CI
#   ORCH_POLL       lock poll interval in seconds (default 30)
#   ORCH_QUEUE_MAX  launch.sh holds build lanes while the merge queue has >= this many branches (default 99 = off)
#   ORCH_MODEL / ORCH_EFFORT  default model and effort for pipeline.sh / review-chain.sh when BUILD_*, REVIEW_*, PRTEXT_* are unset
#   ORCH_LANE_PREFIX  prefix of external lane names (default "orch"): <prefix>-<stem>-build, -rev, -rev2, <prefix>-pr-<stem>
#   ORCH_KIND_MAP   space-separated <model-glob>=<kind> pairs choosing launch.sh's CLI, e.g. "muse-*=muse gpt-*=codex"
#   ORCH_POST_MERGE optional command run after each merge with args: <worktree> <branch> <stem>
ORCH_REPO=${ORCH_REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}
[ -n "$ORCH_REPO" ] || { echo "orchestrate: set ORCH_REPO (no git repo here)" >&2; exit 2; }
ORCH_STATE=${ORCH_STATE:-$HOME/.local/share/orchestrate/$(basename "$ORCH_REPO")}
[ -f "$ORCH_STATE/env.sh" ] && . "$ORCH_STATE/env.sh"
# Typed subfolders of the state dir (never /tmp: a reboot wipes it). Tracked in the state repo unless noted.
ORCH_BRIEFS=${ORCH_BRIEFS:-$ORCH_STATE/briefs}      # <branch>.md, common.md
ORCH_REPORTS=${ORCH_REPORTS:-$ORCH_STATE/reports}   # <branch>.md (builder reports)
ORCH_REVIEWS=${ORCH_REVIEWS:-$ORCH_STATE/reviews}   # <stem>-review<N>.md (first line PASS or FAIL)
ORCH_PR=${ORCH_PR:-$ORCH_STATE/pr}                  # <stem>.txt (line 1 title)
ORCH_PIPES=${ORCH_PIPES:-$ORCH_STATE/pipes}         # <name>.out (pipeline and merge-train output)
ORCH_LOGS=${ORCH_LOGS:-$ORCH_STATE/logs}            # decisions-<date>.md; train/gate logs (untracked)
ORCH_PLANS=${ORCH_PLANS:-$ORCH_STATE/plans}         # plans, batches, mockups
ORCH_RUN=${ORCH_RUN:-$ORCH_STATE/run}               # locks, merge-priority, pause files, model-overrides.txt
ORCH_ARTIFACTS=${ORCH_ARTIFACTS:-$ORCH_STATE/artifacts}  # screenshots, scratch databases, large logs (untracked)
mkdir -p "$ORCH_BRIEFS" "$ORCH_REPORTS" "$ORCH_REVIEWS" "$ORCH_PR" "$ORCH_PIPES" "$ORCH_LOGS" "$ORCH_PLANS" "$ORCH_RUN" "$ORCH_ARTIFACTS"
ORCH_WT_PREFIX=${ORCH_WT_PREFIX:-$ORCH_REPO-}
ORCH_REMOTE=${ORCH_REMOTE:-origin}
ORCH_MAIN=${ORCH_MAIN:-main}
ORCH_CI_GATE=${ORCH_CI_GATE:-on}
ORCH_GATES_TEXT=${ORCH_GATES_TEXT:-"full suite in PR CI"}
ORCH_POLL=${ORCH_POLL:-30}
ORCH_QUEUE_MAX=${ORCH_QUEUE_MAX:-99}
ORCH_SKILL_DIR=${ORCH_SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
export ORCH_REPO ORCH_STATE ORCH_BRIEFS ORCH_REPORTS ORCH_REVIEWS ORCH_PR ORCH_PIPES ORCH_LOGS ORCH_PLANS ORCH_RUN ORCH_ARTIFACTS ORCH_WT_PREFIX ORCH_REMOTE ORCH_MAIN ORCH_CI_GATE ORCH_GATES_TEXT ORCH_POLL ORCH_QUEUE_MAX ORCH_SKILL_DIR
