#!/bin/bash
# usage: wait-lanes.sh <lane> [<lane>...]
# Returns when any lane finishes for real (done/idle/blocked, after a settle) or after ORCH_WAIT_MAX seconds
# (default 1760). Prints "first: <lane> (<status>)" or "timeout", then every lane's status. Needs the herdr CLI.
# Lanes that stopped on a model-capacity error (screen matches $ORCH_CAPACITY_RE) are re-prompted to continue.
# herdr can report a lane done mid-turn, so a lane whose screen still shows "esc to interrupt" counts as working.
. "$(dirname "$0")/orch-env.sh"
RE=${ORCH_CAPACITY_RE:-"at capacity|stream disconnected|overloaded|rate limit"}
MAX=${ORCH_WAIT_MAX:-1760}
status() { herdr agent get "$1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["agent"]["agent_status"])' 2>/dev/null; }
working() { herdr agent read "$1" 2>/dev/null | tail -20 | grep -q "esc to interrupt"; }
report() { for m in "$@"; do echo "$m $(status "$m")"; done; }
[ $# -gt 0 ] || { echo "usage: wait-lanes.sh <lane>..." >&2; exit 2; }
sleep "${ORCH_SETTLE:-20}"
start=$SECONDS
while [ $((SECONDS-start)) -lt "$MAX" ]; do
  for n in "$@"; do
    st=$(status "$n")
    case "$st" in done|idle|blocked) ;; *) continue ;; esac
    [ "$st" != blocked ] && working "$n" && continue
    if [ "$st" != blocked ] && herdr agent read "$n" 2>/dev/null | tail -25 | grep -qE "$RE"; then
      herdr agent prompt "$n" "Continue where you left off (the previous turn was interrupted by a model-capacity error) and finish your task." >/dev/null 2>&1
      echo "auto-resumed $n at $(date +%H:%M)"; sleep 30; continue
    fi
    echo "first: $n ($st)"; report "$@"; exit 0
  done
  sleep 20
done
for n in "$@"; do  # a lane herdr calls finished but whose screen still shows work: keep waiting
  case "$(status "$n")" in done|idle) working "$n" && exec "$0" "$@" ;; esac
done
echo timeout; report "$@"
