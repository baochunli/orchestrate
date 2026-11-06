#!/bin/bash
# usage: ci-wait.sh <PR-url> <commit-sha>
# Waits for every check on the EXACT commit (so an earlier head's green checks cannot pass the gate), then for the PR's
# checks. Prints "GitHub CI passed (N min)" and exits 0, or prints "MERGE FAIL CI: ..." and exits 1.
# With ORCH_CI_GATE=off it prints "CI gate off; merging without waiting" and exits 0.
# Timeouts: 15 min for checks to appear, 180 min pending. ORCH_CI_SLEEP (tests only) replaces every poll interval.
. "$(dirname "$0")/orch-env.sh"
URL=$1; HS=$2
nap() { sleep "${ORCH_CI_SLEEP:-$1}"; }
if [ "$ORCH_CI_GATE" != on ]; then echo "CI gate off; merging without waiting"; exit 0; fi
echo "waiting for GitHub CI on $URL"; t0=$(date +%s)
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
until [ "$(gh api "repos/$REPO/commits/$HS/check-runs" --jq '.total_count' 2>/dev/null || echo 0)" -gt 0 ]; do
  nap 20; [ $(( $(date +%s) - t0 )) -gt 900 ] && { echo "MERGE FAIL CI: no checks for $HS after 15 min"; exit 1; }; done
until [ "$(gh api "repos/$REPO/commits/$HS/check-runs" --jq '[.check_runs[]|select(.status!="completed")]|length' 2>/dev/null || echo 1)" = 0 ]; do
  nap 60; [ $(( $(date +%s) - t0 )) -gt 10800 ] && { echo "MERGE FAIL CI: $HS still pending after 180 min"; exit 1; }; done
until [ -n "$(gh pr checks "$URL" --json name -q '.[].name' 2>/dev/null)" ]; do
  nap 30; [ $(( $(date +%s) - t0 )) -gt 900 ] && { echo "MERGE FAIL CI: no checks registered on $URL after 15 min"; exit 1; }; done
while [ -n "$(gh pr checks "$URL" --json bucket -q '.[] | select(.bucket=="pending") | .bucket' 2>/dev/null)" ]; do
  nap 60; [ $(( $(date +%s) - t0 )) -gt 10800 ] && { echo "MERGE FAIL CI: still pending after 180 min on $URL"; exit 1; }; done
bad=$(gh pr checks "$URL" --json name,bucket -q '.[] | select(.bucket=="fail" or .bucket=="cancel") | .name' | paste -sd, -)
[ -z "$bad" ] || { echo "MERGE FAIL CI: $bad failed on $URL (PR left open)"; exit 1; }
echo "GitHub CI passed ($(( ($(date +%s) - t0) / 60 )) min)"
