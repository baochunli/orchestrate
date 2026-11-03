#!/bin/bash
# usage: [MODEL=<model>] [KIND=muse|codex] launch.sh <lane-name> <dir> <effort> <prompt>
# Starts an EXTERNAL long-running agent lane in a herdr workspace (requires the herdr CLI) and verifies it really
# started on the prompt (not left queued); retries twice. KIND picks the CLI (default from $ORCH_EXTERNAL_KIND, else muse).
#
# WARNING (lesson): external lanes do NOT notify the supervisor when they finish. The supervisor must scan
# $ORCH_STATE/*-report.md on every check, and must verify the lane actually started (worktree activity) at the next check.
#
# Queue gate: lanes whose prompt starts with "Read <brief>" wait while the merge queue has >= ORCH_QUEUE_MAX branches
# (default 99 = effectively off). The wait prints a visible WAITING line every 5 min, so a held lane is never silent.
# Pause: "$ORCH_STATE/pause-<kind>-until" holding an epoch time refuses launches of that kind until then (exit 3).
# Overrides: "$ORCH_STATE/model-overrides.txt" lines "<lane-name> <model> [effort]" win over MODEL/effort.
. "$(dirname "$0")/orch-env.sh"
name=$1; dir=$2; effort=$3; msg=$4
KIND=${KIND:-${ORCH_EXTERNAL_KIND:-muse}}
ov=$(awk -v n="$name" '$1==n {print $2}' "$ORCH_STATE/model-overrides.txt" 2>/dev/null | tail -1); [ -n "$ov" ] && MODEL=$ov
oe=$(awk -v n="$name" '$1==n {print $3}' "$ORCH_STATE/model-overrides.txt" 2>/dev/null | tail -1); [ -n "$oe" ] && effort=$oe
[ -n "${MODEL:-}" ] || { echo "launch.sh: set MODEL" >&2; exit 2; }
command -v herdr >/dev/null || { echo "launch.sh: herdr CLI not found; start the external lane by hand" >&2; exit 2; }
pu=$(cat "$ORCH_STATE/pause-$KIND-until" 2>/dev/null || echo 0)
if [ "$(date +%s)" -lt "$pu" ]; then echo "$KIND LANES PAUSED until $(date -r "$pu" '+%Y-%m-%d %H:%M'); not launching $name" >&2; exit 3; fi
if echo "$msg" | grep -q "^Read .*brief" && [ "$ORCH_QUEUE_MAX" -lt 99 ]; then
  while [ "$("$ORCH_SKILL_DIR/merge-queue-len.sh")" -ge "$ORCH_QUEUE_MAX" ]; do
    echo "WAITING (queue gate): $name held, merge queue >= $ORCH_QUEUE_MAX at $(date +%H:%M)" | tee -a "$ORCH_STATE/pipe-launch-waits.out"
    sleep 300
  done
fi
for attempt in 1 2 3; do
  ws=$(herdr workspace create --cwd "$dir" --label "$name" --no-focus)
  pane=$(echo "$ws" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])'); sleep 2
  case "$KIND" in
    muse) herdr agent start "$name" --kind muse --pane "$pane" --timeout 90000 -- --model "$MODEL" --reasoning-effort "$effort" --yolo 2>&1 | head -c 25; echo ;;
    codex) herdr agent start "$name" --kind codex --pane "$pane" --timeout 90000 -- --model "$MODEL" -c "model_reasoning_effort=\"$effort\"" \
             -c features.multi_agent=false -c check_for_update_on_startup=false --no-daemon --cd "$dir" 2>&1 | head -c 25; echo ;;
    *) echo "launch.sh: unknown KIND $KIND" >&2; exit 2 ;;
  esac
  sleep 5
  herdr agent prompt "$name" "$msg" 2>&1 | head -c 25; echo
  sleep 25
  if herdr agent get "$name" 2>/dev/null | grep -q agent_status && ! herdr agent read "$name" 2>/dev/null | grep -q "Queued follow-up"; then
    echo "STARTED $name ($KIND $MODEL $effort)"; exit 0; fi
  echo "launch $name attempt $attempt did not start; retrying" >&2
  pid=${pane%%:*}; herdr workspace close "$pid" >/dev/null 2>&1; sleep 5
done
echo "LAUNCH FAIL $name" >&2; echo "LAUNCH FAIL $name" >> "$ORCH_STATE/pipe-launch-failures.out"; exit 1
