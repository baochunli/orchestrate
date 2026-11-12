#!/bin/bash
# usage: ci-wait-core.sh <PR-url> <commit-sha>   (one wait; ci-wait.sh wraps it with infra-outage reruns)
# Exit 4 + "HEAD MOVED: ..." when the PR head is no longer <commit-sha> (seen on two consecutive polls): a fix was
# pushed, so waiting on the superseded commit is pointless.
# Waits for every check on the EXACT commit (so an earlier head's green checks cannot pass the gate), then for the PR's
# checks. Prints "GitHub CI passed (N min)" and exits 0, or prints "MERGE FAIL CI: ..." and exits 1.
# With ORCH_CI_GATE=off it prints "CI gate off; merging without waiting" and exits 0.
# Timeouts: 15 min for checks to appear, 180 min pending. ORCH_CI_SLEEP (tests only) replaces every poll interval.
# ORCH_TURN_LABEL set (label-gated CI: the PR's full suite runs only while it carries that label; merge-pr.sh adds it
# at the turn): skipped checks never pass. It judges the workflow RUNS on the exact commit that are not listed in
# ORCH_CI_RUNS_BEFORE (run IDs that existed before the turn's push; merge-pr.sh sets it): once none is pending, any
# failed run fails the gate, and it passes only when a successful run's job named ORCH_REQUIRED_CHECK succeeded.
# Cheap runs (the required job skipped) and cancelled runs are ignored; 15 min with no pending or passing run fails.
# A run still "queued" with zero jobs ORCH_DEAD_RUN_MIN (default 20) minutes after it was created is dead (a GitHub
# Actions incident can leave such runs, which can be neither cancelled nor deleted); it is ignored, with one log line.
. "$(dirname "$0")/orch-env.sh"
URL=$1; HS=$2
seen_moved=
check_head() {
  local c; c=$(gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null || true)
  if [ -n "$c" ] && [ "$c" != "$HS" ]; then
    if [ "$seen_moved" = "$c" ]; then echo "HEAD MOVED: head moved from ${HS:0:9} to ${c:0:9}; requeue to test the new head"; exit 4; fi
    seen_moved=$c
  else seen_moved=; fi
}
nap() { check_head; sleep "${ORCH_CI_SLEEP:-$1}"; }
dead=
# dead_run <run-id> <created-at>: true when the run is older than ORCH_DEAD_RUN_MIN minutes and has no jobs at all.
dead_run() {
  local age n
  age=$(python3 -c 'import sys,datetime as d; t=d.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc); print(int((d.datetime.now(d.timezone.utc)-t).total_seconds()//60))' "$2" 2>/dev/null) || return 1
  [ "${age:-0}" -ge "${ORCH_DEAD_RUN_MIN:-20}" ] || return 1
  n=$(gh api "repos/$REPO/actions/runs/$1/jobs?per_page=1" --jq '.total_count' 2>/dev/null) || return 1
  [ "$n" = 0 ]
}
if [ "$ORCH_CI_GATE" != on ]; then echo "CI gate off; merging without waiting"; exit 0; fi
echo "waiting for GitHub CI on $URL"; t0=$(date +%s)
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
if [ -n "${ORCH_TURN_LABEL:-}" ]; then
  [ -n "${ORCH_REQUIRED_CHECK:-}" ] || { echo "MERGE FAIL CI: ORCH_TURN_LABEL is set but ORCH_REQUIRED_CHECK is not"; exit 1; }
  before=" ${ORCH_CI_RUNS_BEFORE:-} "; t1=$t0
  while :; do
    pending=0; passed=; failed=
    runs=$(gh api "repos/$REPO/actions/runs?head_sha=$HS&event=pull_request&per_page=100" --jq '.workflow_runs[] | "\(.id) \(.status) \(.conclusion) \(.created_at)"' 2>/dev/null) || pending=1
    while read -r id st co created; do
      [ -n "$id" ] || continue
      case "$before" in *" $id "*) continue ;; esac
      if [ "$st" != completed ]; then
        # A dead run: still "queued" with no jobs long after it was created (seen after a GitHub Actions incident;
        # such runs can be neither cancelled nor deleted). It will never finish, so it must not hold the gate.
        if [ "$st" = queued ] && dead_run "$id" "$created"; then
          case " $dead " in *" $id "*) ;; *) dead="$dead $id"; echo "ignoring dead CI run $id (queued with no jobs for over ${ORCH_DEAD_RUN_MIN:-20} min)" ;; esac
          continue
        fi
        pending=1; continue
      fi
      case "$co" in
        success) gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" --jq '.jobs[] | "\(.conclusion) \(.name)"' 2>/dev/null \
                   | grep -qxF "success $ORCH_REQUIRED_CHECK" && passed=$id ;;
        failure|timed_out|startup_failure|action_required) failed="$failed $id" ;;
      esac   # cancelled (superseded), skipped, neutral: ignored
    done <<<"$runs"
    if [ "$pending" = 0 ]; then
      if [ -n "$failed" ]; then
        bad=$(for id in $failed; do gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" \
          --jq '.jobs[] | select(.conclusion=="failure" or .conclusion=="timed_out") | .name' 2>/dev/null; done | sort -u | paste -sd, -)
        echo "MERGE FAIL CI: ${bad:-a workflow run} failed on $URL (PR left open)"; exit 1; fi
      [ -n "$passed" ] && { echo "GitHub CI passed ($(( ($(date +%s) - t0) / 60 )) min)"; exit 0; }
      [ $(( $(date +%s) - t1 )) -gt 900 ] && { echo "MERGE FAIL CI: no full CI run ($ORCH_REQUIRED_CHECK) on $HS within 15 min of the $ORCH_TURN_LABEL label"; exit 1; }
    else t1=$(date +%s); fi
    [ $(( $(date +%s) - t0 )) -gt 10800 ] && { echo "MERGE FAIL CI: $HS still pending after 180 min"; exit 1; }
    nap 60
  done
fi
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
