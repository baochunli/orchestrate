#!/bin/bash
# usage: merge-batch.sh item <wt>:<branch>:<stem>    (called by merge-seq.sh, once per item)
#        merge-batch.sh runner                       (started by a waiting item when no runner holds merge.lock)
#
# The batched merge train.
# item:   check the worktree, push the branch, create or update its PR from $ORCH_PR/<stem>.txt (so early PR CI
#         starts), enqueue "$ORCH_RUN/batch-queue/<stem>", then wait for the runner's verdict in
#         "$ORCH_RUN/batch-result/<stem>" and print it. Starts a runner if none is alive.
# runner: holds $ORCH_RUN/merge.lock (pid file; a dead owner's lock is reclaimed). Each round it collects queued
#         items ($ORCH_RUN/merge-priority first), drops items whose PR head moved (they requeue themselves), evicts
#         items whose early PR CI failed, waits (bounded by ORCH_BATCH_EARLY_MAX, default 1200 s) while early CI is
#         pending, and caps the batch at $ORCH_RUN/merge-batch-max (default 8).
#         One item: today's single train (train.sh merges main into the lane, gates, merge-pr.sh).
#         Several: a candidate in ${ORCH_WT_PREFIX}batch = current main + each branch (merge commits, queue order),
#         pushed as batch/<yyyymmdd-hhmm> with PR "Merge train batch: #a, #b, ..."; CI on the exact candidate commit
#         (ci-wait.sh). Green: merge it (merge commit), every item PR becomes MERGED. Red: split in halves, each half a
#         fresh candidate from main, down to single trains; the failing item gets "MERGE FAIL CI: ... (isolated in batch)".
#         A branch that conflicts with main is evicted (rc=3 + CONFLICT + files); one that only conflicts with a
#         batch-mate waits for the next round.
# Supervisor lines per item are unchanged: "merged" + the main commit line, "MERGE FAIL CI: ...", "<wt> TRAIN rc=3"
# + CONFLICT + files, "MERGE FAIL STALE/DIRTY/PUSH". Runner log: $ORCH_PIPES/merge-batch.out.
. "$(dirname "$0")/orch-env.sh"
D=$ORCH_RUN; L=$D/merge.lock; P=$D/merge-priority; Q=$D/batch-queue; R=$D/batch-result; BIN=$ORCH_SKILL_DIR
EARLY_MAX=${ORCH_BATCH_EARLY_MAX:-1200}
mkdir -p "$Q" "$R"
nap() { sleep "${ORCH_CI_SLEEP:-$1}"; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
lock_pid() { cat "$L/pid" 2>/dev/null; }
reclaim() { local o; o=$(lock_pid); [ -n "$o" ] && ! alive "$o" && rm -rf "$L"; }
qget() { sed -n "s/^$2=//p" "$Q/$1" 2>/dev/null | head -1; }
prio() { cat "$P" 2>/dev/null; }
clearprio() { [ -s "$P" ] && [ "$(cat "$P")" = "$1" ] && rm -f "$P"; }
log() { echo "$(date '+%F %T') $*"; }

# ---------------------------------------------------------------- item
enqueue() {
  local t=$Q/.$stem.$$
  printf 'wt=%s\nbranch=%s\nstem=%s\npr=%s\nurl=%s\nhead=%s\nowner=%s\nt=%s\n' \
    "$wt" "$br" "$stem" "$pr" "$URL" "$head" "$PPID" "$(date +%s)" > "$t" && mv "$t" "$Q/$stem"
}
spawn_runner() {
  local lp p; lp=$(lock_pid)
  if [ ! -d "$L" ] || { [ -n "$lp" ] && ! alive "$lp"; }; then
    p=$(prio); { [ -z "$p" ] || [ -f "$Q/$p" ]; } || return 0
    (nohup "$BIN/merge-batch.sh" runner >> "$ORCH_PIPES/merge-batch.out" 2>&1 < /dev/null &)
  fi
}
item() {
  IFS=: read -r wt br stem _ <<<"$1"
  local w=$ORCH_WT_PREFIX$wt pf=$ORCH_PR/$stem.txt out G T kind
  rm -f "$R/$stem"
  cd "$w" 2>/dev/null || { echo "$wt TRAIN rc=2"; echo "no worktree at $w"; return; }
  [ -s "$pf" ] || { echo "MERGE FAIL: no PR text at $pf"; return; }
  [ -z "$(git status --short)" ] || { echo "MERGE FAIL DIRTY"; return; }
  if [ -n "${ORCH_LOCAL_GATES:-}" ]; then G="local gates (${ORCH_LOCAL_GATES}) on the lane or the batch candidate; $ORCH_GATES_TEXT"; else G=$ORCH_GATES_TEXT; fi
  python3 - "$pf" "$G" <<'PY'
import sys; p,g=sys.argv[1],sys.argv[2]; s=open(p).read()
if "[GATES]" in s: open(p,"w").write(s.replace("[GATES]", g))
PY
  if ! out=$(git push -q -u "$ORCH_REMOTE" "$br" 2>&1); then
    echo "MERGE FAIL PUSH: git push of $br rejected"; echo "$out" | grep -vE "^remote:" | tail -5; return; fi
  T=$(head -1 "$pf"); tail -n +3 "$pf" > "$pf.body"
  URL=$(gh pr list --head "$br" --state open --json url -q '.[0].url' 2>/dev/null || true)
  if [ -n "$URL" ]; then gh pr edit "$URL" --title "$T" --body-file "$pf.body" >/dev/null
  else URL=$(gh pr create --base "$ORCH_MAIN" --head "$br" --title "$T" --body-file "$pf.body") || { echo "MERGE FAIL: gh pr create failed for $br"; return; }; fi
  echo "$URL"
  head=$(git rev-parse HEAD); pr=${URL##*/}
  cd "$ORCH_REPO" || return   # the runner may remove the worktree; never wait inside it
  enqueue; echo "$wt queued for the merge batch (head ${head:0:9})"
  while :; do
    if [ -f "$R/$stem" ]; then
      kind=$(head -1 "$R/$stem")
      if [ "$kind" = moved ]; then
        rm -f "$R/$stem"; head=$(gh pr view "$URL" --json headRefOid -q .headRefOid)
        echo "$wt PR head moved: requeued at ${head:0:9}"; enqueue
      else tail -n +2 "$R/$stem"; rm -f "$R/$stem"; return; fi
    fi
    alive "$PPID" || { rm -f "$Q/$stem"; return; }   # merge-seq was stopped: leave the queue
    [ -f "$Q/$stem" ] || [ -f "$R/$stem" ] || enqueue  # the runner writes the result before removing the queue file
    spawn_runner; nap "$ORCH_POLL"
  done
}

# ---------------------------------------------------------------- runner
# finish <stem> <line>...: the item prints the lines; its queue file goes away.
finish() {
  local s=$1 t; shift; t=$R/.$s.$$
  { echo "done"; printf '%s\n' "$@"; } > "$t" && mv "$t" "$R/$s"; rm -f "$Q/$s"; clearprio "$s"; log "$s: $*"
}
moved() { local t=$R/.$1.$$; echo moved > "$t" && mv "$t" "$R/$1"; rm -f "$Q/$1"; log "$1: PR head moved; item requeues"; }
order() {
  local p f; p=$(prio); [ -n "$p" ] && [ -f "$Q/$p" ] && echo "$p"
  for f in "$Q"/*; do [ -f "$f" ] || continue; [ "${f##*/}" = "$p" ] && continue; echo "$(qget "${f##*/}" t) ${f##*/}"; done | sort -n -k1,1 -k2,2 | awk '{print $2}'
}
# early <url>: pass | pending | fail <names>  (the PR head was already checked to be the enqueued head)
early() {
  local bad
  [ "$ORCH_CI_GATE" = on ] || { echo pass; return; }
  [ -n "$(gh pr checks "$1" --json name -q '.[].name' 2>/dev/null)" ] || { echo pending; return; }
  [ -z "$(gh pr checks "$1" --json bucket -q '.[] | select(.bucket=="pending") | .bucket' 2>/dev/null)" ] || { echo pending; return; }
  bad=$(gh pr checks "$1" --json name,bucket -q '.[] | select(.bucket=="fail" or .bucket=="cancel") | .name' 2>/dev/null | paste -sd, -)
  if [ -n "$bad" ]; then echo "fail $bad"; else echo pass; fi
}
close_stale_batches() {
  local u
  for u in $(cd "$ORCH_REPO" && gh pr list --state open --json url,headRefName,title \
      -q '.[] | select((.headRefName|startswith("batch/")) and (.title|startswith("Merge train batch:"))) | .url' 2>/dev/null); do
    log "closing stale batch PR $u (left by a dead runner)"; (cd "$ORCH_REPO" && gh pr close "$u" --delete-branch >/dev/null 2>&1)
  done
}
# single <isolated 0|1> <stem>: exactly the classic train for one item.
single() {
  local iso=$1 s=$2 wt br out rc G res
  wt=$(qget "$s" wt); br=$(qget "$s" branch); out=$ORCH_LOGS/train-$wt.out; res=$ORCH_LOGS/batch-single-$wt.out
  if [ "$iso" = 1 ]; then log "$s: single train (isolating)"; else log "$s: single train"; fi
  "$BIN/train.sh" "$wt" "train$wt" > "$out" 2>&1; rc=$?
  if [ $rc -ne 0 ]; then
    finish "$s" "$wt TRAIN rc=$rc" "$(tail -4 "$out")"; return; fi
  if grep -q "^tests: delegated to PR CI" "$out"; then G=$ORCH_GATES_TEXT
  elif grep -q "^gates: local ok" "$out"; then G="local gates passed (${ORCH_LOCAL_GATES}); $ORCH_GATES_TEXT"
  else finish "$s" "$wt GATES FAIL" "$(tail -20 "$out")"; return; fi
  "$BIN/merge-pr.sh" "$wt" "$br" "$s" "$G" 2>&1 | grep -vE "^remote:" > "$res"
  [ "$iso" = 1 ] && sed -e 's/^\(MERGE FAIL CI: .*\)$/\1 (isolated in batch)/' "$res" > "$res.t" && mv "$res.t" "$res"
  finish "$s" "$wt gates: $G" "$(cat "$res")"
}
# candidate <stem>...: sets CAND_IN (merged-in stems), CAND_URL, CAND_NAME, CAND_FAIL, CAND_CI (CI timeout). Returns 0 green+merged,
# 1 red (CAND_FAIL = failing checks), 2 infra failure, 3 fewer than two items merged in (no PR), 4 main moved.
candidate() {
  local s head br pr files base sha out body t rc i=1
  CAND_IN=(); CAND_URL=; CAND_FAIL=; CAND_CI=
  git -C "$ORCH_REPO" fetch -q "$ORCH_REMOTE"
  if [ ! -d "$RW" ]; then git -C "$ORCH_REPO" worktree add -q --detach "$RW" "$ORCH_REMOTE/$ORCH_MAIN" || { CAND_FAIL="cannot create $RW"; return 2; }; fi
  cd "$RW" || { CAND_FAIL="cannot enter $RW"; return 2; }
  git merge --abort 2>/dev/null; git reset -q --hard; git clean -fdq
  git fetch -q "$ORCH_REMOTE"; base=$(git rev-parse "$ORCH_REMOTE/$ORCH_MAIN")
  CAND_NAME=batch/$(date +%Y%m%d-%H%M)
  while git show-ref --verify -q "refs/heads/$CAND_NAME" || git ls-remote --exit-code -q "$ORCH_REMOTE" "refs/heads/$CAND_NAME" >/dev/null 2>&1; do
    i=$((i + 1)); CAND_NAME=batch/$(date +%Y%m%d-%H%M)-$i; done
  git checkout -q -B "$CAND_NAME" "$base" || { CAND_FAIL="cannot create $CAND_NAME"; return 2; }
  for s in "$@"; do
    head=$(qget "$s" head); br=$(qget "$s" branch); pr=$(qget "$s" pr)
    git cat-file -e "$head^{commit}" 2>/dev/null || git fetch -q "$ORCH_REMOTE" "$br"
    if git merge -q --no-ff --no-edit -m "Merged $br (#$pr) into the batch." "$head" > "$ORCH_LOGS/batch-merge-$s.log" 2>&1; then
      CAND_IN+=("$s"); continue; fi
    files=$(git status --short | grep -E '^(UU|AA|DU|UD|AU|UA|DD)'); git merge --abort 2>/dev/null; git reset -q --hard
    if [ -z "$files" ]; then   # failed without conflict markers (hook, missing commit): never defer, or the runner spins
      finish "$s" "MERGE FAIL: batch merge of $br failed" "$(tail -5 "$ORCH_LOGS/batch-merge-$s.log")"; continue; fi
    if git merge-tree --write-tree "$base" "$head" >/dev/null 2>&1; then log "$s: conflicts only with batch-mates; next round"
    else finish "$s" "$(qget "$s" wt) TRAIN rc=3" "CONFLICT" "$files"; fi
  done
  if [ ${#CAND_IN[@]} -lt 2 ]; then git checkout -q --detach; git branch -q -D "$CAND_NAME"; return 3; fi
  if [ -n "${ORCH_LOCAL_GATES:-}" ] && ! bash -c "$ORCH_LOCAL_GATES" > "$ORCH_LOGS/batch-gates.log" 2>&1; then
    CAND_FAIL="local gates (see $ORCH_LOGS/batch-gates.log)"; return 1; fi
  git push -q -u "$ORCH_REMOTE" "$CAND_NAME" 2>&1 | grep -vE "^remote:" || true
  [ "$(git ls-remote "$ORCH_REMOTE" "refs/heads/$CAND_NAME" | cut -f1)" = "$(git rev-parse HEAD)" ] || { CAND_FAIL="push of $CAND_NAME failed"; return 2; }
  t="Merge train batch:"; body=$ORCH_LOGS/batch-body.md; : > "$body"
  for s in "${CAND_IN[@]}"; do
    pr=$(qget "$s" pr); t="$t #$pr,"
    echo "- #$pr $(gh pr view "$(qget "$s" url)" --json title -q .title 2>/dev/null)" >> "$body"; done
  printf '\nEach PR above merges with this batch (one CI run on the combined commit).\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' >> "$body"
  CAND_URL=$(gh pr create --base "$ORCH_MAIN" --head "$CAND_NAME" --title "${t%,}" --body-file "$body") || { CAND_FAIL="gh pr create failed for $CAND_NAME"; return 2; }
  log "candidate $CAND_URL ($CAND_NAME): ${CAND_IN[*]}"
  sha=$(git rev-parse HEAD); nap 10
  out=$("$BIN/ci-wait.sh" "$CAND_URL" "$sha" 2>&1); rc=$?; log "$(echo "$out" | tail -1)"
  if [ $rc -ne 0 ]; then
    CAND_FAIL=$(echo "$out" | grep '^MERGE FAIL CI: ' | tail -1); CAND_FAIL=${CAND_FAIL#MERGE FAIL CI: }
    case "$CAND_FAIL" in *" failed on "*) CAND_FAIL=${CAND_FAIL%% failed on *}; return 1 ;; esac
    CAND_FAIL=${CAND_FAIL:-$out}; CAND_CI=1; return 2
  fi
  git fetch -q "$ORCH_REMOTE"
  [ "$(git rev-parse "$ORCH_REMOTE/$ORCH_MAIN")" = "$base" ] || { CAND_FAIL="$ORCH_MAIN moved during the batch"; return 4; }
  gh pr merge "$CAND_URL" --merge --match-head-commit "$sha" > /dev/null 2>&1 || true
  for i in 1 2 3 4 5 6; do [ "$(gh pr view "$CAND_URL" --json state -q .state 2>/dev/null)" = MERGED ] && return 0; nap 10; done
  CAND_FAIL="$CAND_URL not merged"; return 2
}
drop_candidate() {
  [ -n "$CAND_URL" ] && (cd "$ORCH_REPO" && gh pr close "$CAND_URL" --delete-branch >/dev/null 2>&1)
  git -C "$RW" checkout -q --detach 2>/dev/null; git -C "$RW" branch -q -D "$CAND_NAME" 2>/dev/null
  git -C "$RW" push -q "$ORCH_REMOTE" --delete "$CAND_NAME" 2>/dev/null || true
}
green() {
  local s url wt br main note i
  cd "$ORCH_REPO" || return
  { git fetch -q "$ORCH_REMOTE" "$ORCH_MAIN" && git merge -q --ff-only "$ORCH_REMOTE/$ORCH_MAIN"; } || log "note: main checkout not fast-forwarded"
  main=$(git log --oneline -1 "$ORCH_REMOTE/$ORCH_MAIN" | cat)
  for s in "${CAND_IN[@]}"; do
    url=$(qget "$s" url); wt=$ORCH_WT_PREFIX$(qget "$s" wt); br=$(qget "$s" branch); note=
    for i in 1 2 3 4 5 6; do [ "$(gh pr view "$url" --json state -q .state 2>/dev/null)" = MERGED ] && break; nap 10; done
    [ "$(gh pr view "$url" --json state -q .state 2>/dev/null)" = MERGED ] || note="note: $url is not marked MERGED on GitHub yet (its commits are in $ORCH_MAIN; left open, check it)"
    [ -n "${ORCH_POST_MERGE:-}" ] && (nohup bash -c "$ORCH_POST_MERGE" _ "$wt" "$br" "$s" >/dev/null 2>&1 &)
    (nohup "$BIN/cleanup-merged.sh" "$wt" "$s" >/dev/null 2>&1 &)
    git worktree remove --force "$wt" 2>/dev/null; git branch -q -D "$br" 2>/dev/null
    [ -z "$note" ] && { git push -q "$ORCH_REMOTE" --delete "$br" 2>/dev/null || true; }
    if [ -n "$note" ]; then finish "$s" "GitHub CI passed on batch $CAND_URL" "$note" "merged" "$main"
    else finish "$s" "GitHub CI passed on batch $CAND_URL" "merged" "$main"; fi
  done
  git -C "$RW" checkout -q --detach 2>/dev/null; git -C "$RW" branch -q -D "$CAND_NAME" 2>/dev/null
  git push -q "$ORCH_REMOTE" --delete "$CAND_NAME" 2>/dev/null || true
}
# attempt <isolated 0|1> <stem>...: one candidate; on red, bisect into halves (each fresh from main).
attempt() {
  local iso=$1; shift
  [ $# -eq 0 ] && return
  [ $# -eq 1 ] && { single "$iso" "$1"; return; }
  local rc in n h s
  candidate "$@"; rc=$?
  in=("${CAND_IN[@]}"); n=${#in[@]}
  case $rc in
    0) green ;;
    1) log "red: $CAND_FAIL; bisecting ${in[*]}"; drop_candidate; h=$((n / 2))
       attempt 1 "${in[@]:0:h}"; attempt 1 "${in[@]:h}" ;;
    3) [ "$n" -eq 1 ] && single "$iso" "${in[0]}" ;;
    4) drop_candidate; STALE_N=$((STALE_N + 1)); log "$CAND_FAIL (stale $STALE_N)"
       if [ "$STALE_N" -gt 2 ]; then for s in "${in[@]}"; do finish "$s" "MERGE FAIL STALE: $CAND_FAIL"; done; fi ;;
    *) drop_candidate
       if [ -n "$CAND_CI" ]; then for s in "${in[@]}"; do finish "$s" "MERGE FAIL CI: $CAND_FAIL (batch $CAND_URL; PR left open)"; done
       else for s in "${in[@]}"; do finish "$s" "MERGE FAIL: batch: $CAND_FAIL (PR left open)"; done; fi ;;
  esac
}
# round: returns 1 when the queue is empty.
round() {
  local max t0 s url head st oid e all ready pend now pp
  max=$(cat "$D/merge-batch-max" 2>/dev/null); case "$max" in ''|*[!0-9]*|0) max=8 ;; esac
  t0=$(date +%s)
  while :; do
    all=(); ready=(); pend=0; pp=; now=$(date +%s)
    for s in $(order); do
      alive "$(qget "$s" owner)" || { rm -f "$Q/$s"; log "$s: merge-seq gone; dropped"; continue; }
      url=$(qget "$s" url); head=$(qget "$s" head)
      read -r st oid <<<"$(gh pr view "$url" --json state,headRefOid -q '.state + " " + .headRefOid' 2>/dev/null)"
      case "$st" in
        OPEN) ;;
        MERGED) git -C "$ORCH_REPO" fetch -q "$ORCH_REMOTE" "$ORCH_MAIN"; finish "$s" "merged" "$(git -C "$ORCH_REPO" log --oneline -1 "$ORCH_REMOTE/$ORCH_MAIN" | cat)"; continue ;;
        CLOSED) finish "$s" "MERGE FAIL: $url is closed"; continue ;;
        *) pend=$((pend + 1)); continue ;;   # gh hiccup: look again next poll
      esac
      [ "$oid" = "$head" ] || { moved "$s"; continue; }
      e=$(early "$url")
      case "$e" in
        pass) all+=("$s"); ready+=("$s") ;;
        fail*) finish "$s" "MERGE FAIL CI: ${e#fail } failed on $url (early PR CI on ${head:0:9}; PR left open)" ;;
        *) all+=("$s"); if [ $((now - $(qget "$s" t))) -ge "$EARLY_MAX" ]; then ready+=("$s"); log "$s: early CI still pending; including"
           else pend=$((pend + 1)); [ "$s" = "$(prio)" ] && pp=1; fi ;;
      esac
    done
    [ ${#all[@]} -eq 0 ] && [ "$pend" -eq 0 ] && return 1
    [ ${#all[@]} -eq 1 ] && { ready=("${all[@]}"); break; }   # a lone item runs at once, like the classic train
    [ ${#ready[@]} -ge "$max" ] && [ -z "$pp" ] && break   # a pending priority stem holds the batch (bounded)
    [ "$pend" -gt 0 ] && [ $((now - t0)) -lt "$EARLY_MAX" ] && { nap "$ORCH_POLL"; continue; }
    [ ${#ready[@]} -gt 0 ] && break
    nap "$ORCH_POLL"
  done
  attempt 0 "${ready[@]:0:max}"
  return 0
}
runner() {
  reclaim "$L"; mkdir "$L" 2>/dev/null || exit 0
  echo $$ > "$L/pid"; echo batch > "$L/runner"
  trap '[ "$(lock_pid)" = "$$" ] && rm -rf "$L"' EXIT
  RW=${ORCH_WT_PREFIX}batch; STALE_N=0
  [ "$(cat "$D/merge-spec" 2>/dev/null)" = on ] && log "note: merge-spec is gone (batching replaced speculation); ignoring it"
  log "runner $$ started"; close_stale_batches
  while :; do
    p=$(prio); if [ -n "$p" ] && [ ! -f "$Q/$p" ]; then log "merge-priority names $p, not in the batch queue: yielding the lock"; exit 0; fi
    round || { log "runner $$: queue empty, exiting"; exit 0; }
    nap "$ORCH_POLL"   # never spin: a round that changed nothing must not repeat at once
  done
}

case "${1:-}" in
  item) item "$2" ;;
  runner) runner ;;
  *) echo "usage: merge-batch.sh item <wt>:<branch>:<stem> | runner" >&2; exit 2 ;;
esac
