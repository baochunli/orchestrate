#!/bin/bash
# Retired batch train (2026-11-06): kept only so processes started under it keep working. Old waiting items call
# "merge-batch.sh runner" when the lock frees; the FIFO runner (merge-queue.sh) drains $ORCH_RUN/batch-queue first.
case "${1:-}" in
  item) exec "$(dirname "$0")/merge-queue.sh" item "$2" ;;
  runner) exec "$(dirname "$0")/merge-queue.sh" runner ;;
  *) echo "merge-batch.sh is retired; use merge-seq.sh" >&2; exit 2 ;;
esac
