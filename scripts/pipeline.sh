#!/bin/bash
# usage: [CHAIN_NO_MERGE=1] pipeline.sh <branch> [<#PR|dep-branch>|...|-] [full|quick]
# Chains the whole lane: wait for dependency PRs to merge -> create worktree -> build lane -> wait -> require report
# -> review-chain.sh (review -> PR text -> merge-seq). launch.sh alone starts ONE lane and stops; this chains them.
# Stem = branch with "-" removed; worktree "$ORCH_WT_PREFIX<stem>"; brief $ORCH_BRIEFS/<branch>.md;
# required report $ORCH_REPORTS/<branch>.md. Start it with run-pipe.sh so the log is checked.
# Models: BUILD_MODEL/BUILD_EFFORT (fall back to ORCH_MODEL/ORCH_EFFORT from env or $ORCH_STATE/env.sh), plus
# REVIEW_*/PRTEXT_* for review-chain.sh. BUILD_EXTRA = project rules appended to the build prompt (budget, gates, copy).
# Failures print "CHAIN FAIL <stem>: <reason>". Dependencies are waited on by PR merged state, never by refs.
set -u
. "$(dirname "$0")/orch-env.sh"
br=$1; deps=${2:--}; mode=${3:-quick}; stem=${br//-/}; wt=$ORCH_WT_PREFIX$stem; S=$ORCH_STATE; LP=${ORCH_LANE_PREFIX:-orch}
BM=${BUILD_MODEL:-${ORCH_MODEL:-}}; BE=${BUILD_EFFORT:-${ORCH_EFFORT:-high}}
[ -n "$BM" ] || { echo "CHAIN FAIL $stem: set BUILD_MODEL (or ORCH_MODEL)"; exit 1; }
[ -s "$ORCH_BRIEFS/$br.md" ] || { echo "CHAIN FAIL $stem: brief $ORCH_BRIEFS/$br.md missing"; exit 1; }
cd "$ORCH_REPO" || exit 1
# Dependencies: "#123" waits for that PR; a branch name waits for a PR from it merged after this pipeline started
# (branch names get reused, and an old merged PR of the same name must not count).
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for d in $(echo "$deps" | tr '|' ' '); do [ "$d" = - ] && continue
  case "$d" in
    \#*) until [ "$(gh pr view "${d#\#}" --json state -q .state 2>/dev/null)" = MERGED ]; do sleep 300; done ;;
    *) until [ -n "$(gh pr list --state merged --head "$d" --json mergedAt -q ".[] | select(.mergedAt >= \"$since\") | .mergedAt" 2>/dev/null)" ]; do sleep 300; done ;;
  esac; done
git fetch -q "$ORCH_REMOTE"
# Parallel pipelines can race on git's worktree lock: retry, and reuse a branch created by a lost race.
for i in 1 2 3 4 5 6; do [ -d "$wt" ] && break
  git worktree add -q -b "$br" "$wt" "$ORCH_REMOTE/$ORCH_MAIN" 2>/dev/null || git worktree add -q "$wt" "$br" 2>/dev/null
  [ -d "$wt" ] || sleep $((RANDOM % 15 + 5)); done
[ -d "$wt" ] || { echo "CHAIN FAIL $stem: could not create worktree $wt"; exit 1; }
[ -e "$ORCH_REPORTS/$br.md" ] && mv "$ORCH_REPORTS/$br.md" "$ORCH_REPORTS/$br.md.stale-$(date +%s)"
lane="$LP-$stem-build"
MODEL=$BM "$ORCH_SKILL_DIR/launch.sh" "$lane" "$wt" "$BE" "Read $ORCH_BRIEFS/$br.md and follow it exactly. Write your report to $ORCH_REPORTS/$br.md. ${BUILD_EXTRA:-}" >/dev/null
sleep 30; herdr agent get "$lane" 2>/dev/null | grep -q agent_status || { echo "CHAIN FAIL $stem: build lane not registered"; exit 1; }
until ! herdr agent get "$lane" 2>/dev/null | grep -qE '"agent_status":"(working|unknown)"'; do "$ORCH_SKILL_DIR/wait-lanes.sh" "$lane" >/dev/null; done
[ -s "$ORCH_REPORTS/$br.md" ] || { echo "CHAIN FAIL $stem: no report ($(herdr agent get "$lane" | grep -o '"agent_status":"[a-z]*"'))"; exit 1; }
exec "$ORCH_SKILL_DIR/review-chain.sh" "$stem" "$br" "$mode"
