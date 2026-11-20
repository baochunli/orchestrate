#!/bin/bash
# watch-worktrees.sh <minutes> <wt>... — exits when any worktree shows no change (HEAD, status, file mtimes) for <minutes>.
lim=$1; shift; d=$(mktemp -d)
while true; do
  for w in "$@"; do
    k=$(echo "$w" | md5)
    sig=$( (git -C "$w" rev-parse HEAD; git -C "$w" status --porcelain; find "$w/content" -type f -newermt "-90 seconds" 2>/dev/null | head -50; git -C "$w" diff --stat 2>/dev/null | tail -1) | md5)
    if [ -f "$d/$k.sig" ] && [ "$(cat $d/$k.sig)" = "$sig" ]; then n=$(( $(cat $d/$k.n 2>/dev/null || echo 0) + 1 )); else n=0; echo "$sig" > $d/$k.sig; fi
    echo $n > $d/$k.n
    [ $n -ge $lim ] && { echo "STALL $w no change for $lim min $(date +%H:%M)"; exit 0; }
  done
  sleep 60
done
