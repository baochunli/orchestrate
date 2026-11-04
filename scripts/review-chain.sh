#!/bin/bash
# usage: [CHAIN_NO_MERGE=1] review-chain.sh <stem> <branch> [full|quick]
# Fresh review lane -> (PASS) PR-text lane -> merge-seq. Stops on FAIL and prints "CHAIN FAIL <stem>: <verdict head>".
# Worktree is "$ORCH_WT_PREFIX<stem>". Reads brief-<branch>.md and <branch>-report.md from $ORCH_STATE.
# Prompts come from templates/review-prompt.md and templates/pr-text-prompt.md (override: REVIEW_PROMPT_FILE,
# PRTEXT_PROMPT_FILE, e.g. project copies with the <...> blanks filled) with these tokens substituted:
#   {{STEM}} {{BRANCH}} {{SHA}} {{WORKTREE}} {{REPO}} {{BRIEF}} {{REPORT}} {{VERDICT}} {{VERDICTS}} {{PRFILE}}
# Optional text appended to the prompts: REVIEW_EXTRA, PRTEXT_EXTRA (e.g. project rules, PR content notes).
# Models (launch.sh applies model-overrides.txt on top): REVIEW_MODEL/REVIEW_EFFORT, PRTEXT_MODEL/PRTEXT_EFFORT,
# each falling back to ORCH_MODEL/ORCH_EFFORT (set in the environment or $ORCH_STATE/env.sh). KIND picks the CLI.
# $ORCH_RUN/extra-review-<stem> (any content) adds a second independent review (REVIEW2_MODEL, default
# REVIEW_MODEL); merging then needs both PASS.
# CHAIN_NO_MERGE=1 stops after the PR text ("READY"), for batch merges.
# ROUND=<n> (n >= 2) re-reviews after a fix round: lanes "<prefix>-<stem>-r<n>-rev" and "<prefix>-pr-<stem>-r<n>",
# verdict reviews/<stem>-review<n>.md; set REVIEW_PROMPT_FILE to a filled delta-review prompt for a delta review.
set -u
. "$(dirname "$0")/orch-env.sh"
stem=$1; br=$2; mode=${3:-quick}; wt=$ORCH_WT_PREFIX$stem; S=$ORCH_STATE; LP=${ORCH_LANE_PREFIX:-orch}
RM=${REVIEW_MODEL:-${ORCH_MODEL:-}}; RE=${REVIEW_EFFORT:-${ORCH_EFFORT:-high}}
PM=${PRTEXT_MODEL:-${ORCH_MODEL:-}}; PE=${PRTEXT_EFFORT:-${ORCH_EFFORT:-high}}
[ -n "$RM" ] && [ -n "$PM" ] || { echo "CHAIN FAIL $stem: set REVIEW_MODEL and PRTEXT_MODEL (or ORCH_MODEL)"; exit 1; }
[ -d "$wt" ] || { echo "CHAIN FAIL $stem: worktree $wt missing"; exit 1; }
R=${ROUND:-1}; T=; [ "$R" -gt 1 ] && T=-r$R
brief=$ORCH_BRIEFS/$br.md; report=$ORCH_REPORTS/$br.md; v1=$ORCH_REVIEWS/$stem-review$R.md; v2=$ORCH_REVIEWS/$stem-review$R-b.md; prf=$ORCH_PR/$stem.txt
sha=$(git -C "$wt" rev-parse --short HEAD)
ts=$(date +%s); for f in "$v1" "$v2" "$prf"; do [ -e "$f" ] && mv "$f" "$f.stale-$ts"; done
lane() { herdr agent get "$1" 2>/dev/null | grep -q agent_status; }
busy() { herdr agent get "$1" 2>/dev/null | grep -qE '"agent_status":"(working|unknown)"'; }
lane "$LP-$stem$T-rev" && { echo "CHAIN FAIL $stem: lane $LP-$stem$T-rev already exists; use a new stem"; exit 1; }
# subst <template> <verdict> <verdicts>: fill the {{TOKENS}}; fail if any remain.
subst() {
  local t; t=$(sed -e "s#{{STEM}}#$stem#g" -e "s#{{BRANCH}}#$br#g" -e "s#{{SHA}}#$sha#g" -e "s#{{WORKTREE}}#$wt#g" \
    -e "s#{{REPO}}#$ORCH_REPO#g" -e "s#{{BRIEF}}#$brief#g" -e "s#{{REPORT}}#$report#g" -e "s#{{VERDICT}}#$2#g" \
    -e "s#{{VERDICTS}}#$3#g" -e "s#{{PRFILE}}#$prf#g" "$1")
  case "$t" in *"{{"*) echo "CHAIN FAIL $stem: unresolved {{token}} in $1"; exit 1 ;; esac
  printf '%s\n' "$t"
}
RT=${REVIEW_PROMPT_FILE:-$ORCH_SKILL_DIR/../templates/review-prompt.md}
PT=${PRTEXT_PROMPT_FILE:-$ORCH_SKILL_DIR/../templates/pr-text-prompt.md}
RP="$(subst "$RT" "$v1" "$v1") ${REVIEW_EXTRA:-}"
MODEL=$RM "$ORCH_SKILL_DIR/launch.sh" "$LP-$stem$T-rev" "$wt" "$RE" "$RP" >/dev/null
sleep 30; lane "$LP-$stem$T-rev" || { echo "CHAIN FAIL $stem: review lane not registered"; exit 1; }
second=0
if [ -f "$ORCH_RUN/extra-review-$stem" ]; then second=1
  RP2="$(subst "$RT" "$v2" "$v2") ${REVIEW_EXTRA:-} Work independently of any other reviewer."
  MODEL=${REVIEW2_MODEL:-$RM} "$ORCH_SKILL_DIR/launch.sh" "$LP-$stem$T-rev2" "$wt" "$RE" "$RP2" >/dev/null
fi
# await <lane> <file>: until the file exists or the lane stops working.
await() { until [ -s "$2" ] || ! busy "$1"; do "$ORCH_SKILL_DIR/wait-lanes.sh" "$1" >/dev/null; done; }
head_of() { head -3 "$1" 2>/dev/null | tr '\n' ' ' | cut -c1-200; }
passed() { [ "$(head -1 "$1" 2>/dev/null | tr -d '[:space:]')" = PASS ]; }
await "$LP-$stem$T-rev" "$v1"
if [ ! -s "$v1" ] && herdr agent get "$LP-$stem$T-rev" 2>/dev/null | grep -q '"agent_status":"blocked"'; then
  echo "CHAIN FAIL $stem: review lane blocked on an interactive prompt"; exit 1; fi
passed "$v1" || { echo "CHAIN FAIL $stem: ${v1##*/} $(head_of "$v1")"; exit 1; }
echo "$stem review 1: PASS"
if [ $second = 1 ]; then
  await "$LP-$stem$T-rev2" "$v2"
  passed "$v2" || { echo "CHAIN FAIL $stem: ${v2##*/} $(head_of "$v2")"; exit 1; }
  echo "$stem review 2: PASS"
fi
verdicts=$v1; [ $second = 1 ] && verdicts="$v1 and $v2"
PP="$(subst "$PT" "$v1" "$verdicts") ${PRTEXT_EXTRA:-}"
MODEL=$PM "$ORCH_SKILL_DIR/launch.sh" "$LP-pr-$stem$T" "$wt" "$PE" "$PP" >/dev/null
sleep 30; lane "$LP-pr-$stem$T" || { echo "CHAIN FAIL $stem: PR-text lane not registered"; exit 1; }
await "$LP-pr-$stem$T" "$prf"
[ -s "$prf" ] || { echo "CHAIN FAIL $stem: PR-text lane stopped without writing ${prf##*/}"; exit 1; }
[ "${CHAIN_NO_MERGE:-}" = 1 ] && { echo "$stem READY (review PASS, PR text written; merge pending)"; exit 0; }
# merge-seq.sh serializes on its own lock; no extra waiting here (a pgrep wait could deadlock behind a priority holder).
git -C "$wt" fetch -q "$ORCH_REMOTE" "$br" 2>/dev/null && git -C "$wt" merge -q --no-edit "$ORCH_REMOTE/$br" 2>/dev/null || true
if [ "$mode" = full ]; then exec "$ORCH_SKILL_DIR/merge-seq.sh" "$stem:$br:$stem:full"; else exec "$ORCH_SKILL_DIR/merge-seq.sh" "$stem:$br:$stem"; fi
