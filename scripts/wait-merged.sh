#!/bin/bash
# usage: wait-merged.sh <#PR-number|parent-branch> [<required-file>] -- <command...>
# Blocks until the PR (by number, preferred) or the branch's PR shows as MERGED on GitHub (and <required-file> is
# non-empty, if given), then runs the command. Never wait on "origin/<parent>" refs: GitHub deletes the branch on merge
# and a ref-based waiter loops forever (lesson). Prefer a PR number: branch names get reused, and a branch waiter then
# matches an OLD merged PR of the same name and fires at once (lesson). A branch waiter only counts PRs merged after
# it started. Run via run-pipe.sh or the harness's run_in_background.
. "$(dirname "$0")/orch-env.sh"
parent=$1; shift; req=
[ "${1:-}" != -- ] && { req=$1; shift; }
[ "${1:-}" = -- ] && shift
cd "$ORCH_REPO"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
merged() {
  case "$parent" in
    \#*|[0-9]*) [ "$(gh pr view "${parent#\#}" --json state -q .state 2>/dev/null)" = MERGED ] ;;
    *) [ -n "$(gh pr list --state merged --head "$parent" --json mergedAt -q ".[] | select(.mergedAt >= \"$since\") | .mergedAt" 2>/dev/null)" ] ;;
  esac
}
until merged && { [ -z "$req" ] || [ -s "$req" ]; }; do sleep 120; done
echo "$parent merged; running: $*"; exec "$@"
