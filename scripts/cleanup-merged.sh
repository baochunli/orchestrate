#!/bin/bash
# usage: cleanup-merged.sh <worktree-path> <stem> — after a merge: close idle herdr workspaces whose agents ran in the
# worktree (if herdr is installed), remove merged detached /tmp worktrees whose path contains the stem, prune worktrees.
. "$(dirname "$0")/orch-env.sh"
wt=$1; stem=$2
if command -v herdr >/dev/null; then
  herdr agent list 2>/dev/null | python3 -c '
import json,sys
wt=sys.argv[1]
for a in json.load(sys.stdin)["result"]["agents"]:
    if a.get("cwd")==wt and a["agent_status"]!="working": print(a["workspace_id"])' "$wt" | sort -u | \
    while read -r w; do herdr workspace close "$w" >/dev/null 2>&1; done
fi
cd "$ORCH_REPO" && git fetch -q "$ORCH_REMOTE" "$ORCH_MAIN"
git worktree list --porcelain | awk '/^worktree /{print $2}' | grep -E "^(/private)?/tmp/" | grep -F "$stem" | while read -r p; do
  git merge-base --is-ancestor "$(git -C "$p" rev-parse HEAD)" "$ORCH_REMOTE/$ORCH_MAIN" 2>/dev/null && git worktree remove --force "$p" 2>/dev/null
done
git worktree prune
