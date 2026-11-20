#!/bin/bash
# watch-pane.sh <pane_id> [stall_minutes=10]
# Exits (so the orchestrator is notified) when the pane's agent stops working, waits for input,
# or its visible output hasn't changed for <stall_minutes> while "working".
p=$1; lim=${2:-10}; last=""; same=0; idle=0
while true; do
  st=$(herdr pane list 2>/dev/null | python3 -c "
import json,sys
for x in json.load(sys.stdin)['result'].get('panes',[]):
  if x.get('pane_id')=='$p': print(x.get('agent_status'))")
  out=$(herdr pane read $p --lines 40 2>/dev/null | grep -v -E "^\s*$|esc to cancel|Thought for|⣻|⣽|⣾|⣷|⣯|⣟|⡿|⢿" | md5)
  if [ -z "$st" ]; then echo "GONE $p $(date +%H:%M)"; exit 0; fi
  if [ "$st" != "working" ]; then idle=$((idle+1)); [ $idle -ge 2 ] && { echo "STOPPED $p status=$st $(date +%H:%M)"; exit 0; }; else idle=0; fi
  if [ "$out" = "$last" ]; then same=$((same+1)); else same=0; last=$out; fi
  [ $same -ge $lim ] && { echo "STALL $p no output change for ${lim} min $(date +%H:%M)"; exit 0; }
  herdr pane read $p --lines 8 2>/dev/null | grep -qE "\? .*\?$|Do you want|\[y/n\]|Yes, I trust|Allow|approve" && { echo "QUESTION $p $(date +%H:%M)"; exit 0; }
  sleep 60
done
