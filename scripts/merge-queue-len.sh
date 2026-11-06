#!/bin/bash
# Prints the number of live merge-seq.sh processes (branches waiting for, or running, a merge); launch.sh compares it
# with ORCH_QUEUE_MAX. While $ORCH_RUN/build-pause exists it prints 99, holding every gated lane in launch.sh;
# --real prints the true count. --list prints the merge queue in order: "<position> <stem> <branch> attempt <n>".
. "$(dirname "$0")/orch-env.sh"
if [ "${1:-}" = --list ]; then
  Q=$ORCH_RUN/merge-queue; n=0
  for f in "$Q"/*; do [ -f "$f" ] && echo "$(sed -n 's/^seq=//p' "$f") ${f##*/} $(sed -n 's/^branch=//p' "$f") $(( $(sed -n 's/^fails=//p' "$f") + 1 ))"; done | sort -n |
    while read -r _ s b a; do n=$((n + 1)); echo "$n $s $b attempt $a"; done
  exit 0
fi
[ "${1:-}" != --real ] && [ -e "$ORCH_RUN/build-pause" ] && { echo 99; exit 0; }
ps -axo args= | awk '$1 ~ /bash$/ && $2 ~ /merge-seq\.sh$/' | wc -l | tr -d ' '
