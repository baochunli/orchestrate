#!/bin/bash
# usage: lane-busy.sh <lane> — exit 0 while an external herdr lane is really working.
# herdr can report a lane "done" mid-turn during a long tool call, so also treat it as busy while its screen shows
# the "esc to interrupt" working indicator.
herdr agent get "$1" 2>/dev/null | grep -qE '"agent_status":"(working|unknown|blocked)"' && exit 0
herdr agent read "$1" 2>/dev/null | tail -20 | grep -q "esc to interrupt"
