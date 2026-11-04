#!/bin/bash
# Prints the number of live merge-seq.sh processes (branches waiting for, or running, a merge).
# While $ORCH_RUN/build-pause exists it prints 99, holding every gated lane in launch.sh; --real prints the true count.
. "$(dirname "$0")/orch-env.sh"
[ "${1:-}" != --real ] && [ -e "$ORCH_RUN/build-pause" ] && { echo 99; exit 0; }
ps -axo args= | awk '$1 ~ /bash$/ && $2 ~ /merge-seq\.sh$/' | wc -l | tr -d ' '
