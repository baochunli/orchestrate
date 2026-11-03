#!/bin/bash
# usage: run-pipe.sh <name> <script> [args...]
# Starts a pipeline script detached; output appends to $ORCH_STATE/pipe-<name>.out (what watch-all.sh and the
# 15-minute check read). Start every pipeline through this so no log falls outside the checks.
. "$(dirname "$0")/orch-env.sh"
n=$1; shift; cd "$ORCH_SKILL_DIR"
nohup "$@" >> "$ORCH_STATE/pipe-$n.out" 2>&1 < /dev/null & echo "started $n (pid $!)"
