#!/bin/bash
# usage: wait-merged.sh <parent-branch> [<required-file>] -- <command...>
# Blocks until <parent-branch>'s PR shows as MERGED on GitHub (and <required-file> is non-empty, if given), then runs
# the command. Use for stacked branches: never wait on "origin/<parent>" refs, because GitHub deletes the branch on merge
# and a ref-based waiter loops forever (lesson). Run via run-pipe.sh or the harness's run_in_background.
. "$(dirname "$0")/orch-env.sh"
parent=$1; shift; req=
[ "${1:-}" != -- ] && { req=$1; shift; }
[ "${1:-}" = -- ] && shift
cd "$ORCH_REPO"
until [ "$(gh pr list --state merged --head "$parent" --json number --jq length 2>/dev/null)" = 1 ] && { [ -z "$req" ] || [ -s "$req" ]; }; do
  sleep 120
done
echo "$parent merged; running: $*"; exec "$@"
