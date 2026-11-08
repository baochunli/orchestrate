#!/bin/bash
# usage: ci-wait.sh <PR-url> <commit-sha>
# Waits for every check on the EXACT commit (ci-wait-core.sh holds the polling logic and the gate rules; see its header
# for ORCH_CI_GATE, ORCH_TURN_LABEL / ORCH_REQUIRED_CHECK / ORCH_CI_RUNS_BEFORE and the timeouts).
# Prints "GitHub CI passed (N min)" and exits 0, or prints "MERGE FAIL CI: ..." and exits 1. Two extra outcomes:
#  - exit 4 + "HEAD MOVED: head moved from X to Y; requeue to test the new head": the PR head changed while waiting
#    (a fix was pushed). Not a CI failure; merge-queue.sh requeues at the same position without using an attempt.
#  - infra-outage tolerance: when every failed run's failed-step log shows an infrastructure error (HTTP 5xx, download
#    failures; patterns in ci-infra.sh) and no real test failure, the failed jobs are rerun (`gh run rerun --failed`)
#    after a backoff and the wait resumes; no "MERGE FAIL CI" line is printed for those. ORCH_INFRA_RERUNS (default 6,
#    0 = off) caps the reruns; ORCH_INFRA_BACKOFF (default 300 s) is the first wait, growing by that much per rerun up
#    to 600 s. Exhausted: "MERGE FAIL CI: ... (infra outage persisted after N reruns)". ORCH_CI_SLEEP replaces sleeps.
. "$(dirname "$0")/orch-env.sh"
. "$(dirname "$0")/ci-infra.sh"
URL=$1; HS=$2
max=${ORCH_INFRA_RERUNS:-6}; base=${ORCH_INFRA_BACKOFF:-300}; n=0
TAG="CI FAIL (checking for infra outage): "
core="$(dirname "$0")/ci-wait-core.sh"
while :; do
  tmp=$(mktemp "${TMPDIR:-/tmp}/ci-wait.XXXXXX")
  "$core" "$URL" "$HS" 2>&1 | sed -u "s/^MERGE FAIL CI: /$TAG/" | tee "$tmp"; rc=${PIPESTATUS[0]}
  fail=$(sed -n "s/^$TAG/MERGE FAIL CI: /p" "$tmp" | tail -1); rm -f "$tmp"
  if [ "$rc" != 1 ] || [ -z "$fail" ]; then exit "$rc"; fi
  cur=$(gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null || true)
  if [ -n "$cur" ] && [ "$cur" != "$HS" ]; then
    echo "HEAD MOVED: head moved from ${HS:0:9} to ${cur:0:9}; requeue to test the new head"; exit 4; fi
  infra=0; ids=
  if [ "$max" -gt 0 ]; then
    before=" ${ORCH_CI_RUNS_BEFORE:-} "
    for id in $(gh run list --commit "$HS" --json databaseId,conclusion -q '.[] | select(.conclusion=="failure" or .conclusion=="timed_out") | .databaseId' 2>/dev/null); do
      case "$before" in *" $id "*) continue ;; esac; ids="$ids $id"; done
    if [ -n "$ids" ]; then
      infra=1; lg=$(mktemp "${TMPDIR:-/tmp}/ci-log.XXXXXX")
      for id in $ids; do gh run view "$id" --log-failed > "$lg" 2>/dev/null || true; infra_only "$lg" || infra=0; done
      rm -f "$lg"
    fi
  fi
  if [ "$infra" = 0 ]; then echo "$fail"; exit 1; fi
  if [ "$n" -ge "$max" ]; then echo "$fail (infra outage persisted after $n reruns)"; exit 1; fi
  n=$((n + 1)); d=$((base * n)); cap=$((base > 600 ? base : 600)); [ "$d" -gt "$cap" ] && d=$cap
  echo "infra outage in the failed CI log (not a code failure, no merge attempt used): rerunning the failed jobs ($n/$max) after ${d}s"
  sleep "${ORCH_CI_SLEEP:-$d}"
  for id in $ids; do gh run rerun "$id" --failed >/dev/null 2>&1 || true; done
  t0=$(date +%s)   # wait until the rerun is visible as not completed, so the next wait cannot read the old verdict
  while [ -z "$(gh run list --commit "$HS" --json status -q '.[] | select(.status!="completed") | .status' 2>/dev/null)" ]; do
    [ $(( $(date +%s) - t0 )) -gt 300 ] && break; sleep "${ORCH_CI_SLEEP:-10}"; done
done
