#!/bin/bash
# usage: watch-all.sh — a SUPPLEMENTARY event watcher (never the only safeguard; the 15-minute cron check is).
# Run with the harness's run_in_background (never "&"); it exits, printing what happened, when:
#   - any $ORCH_STATE/pipe-*.out log gains a line;
#   - the default branch gains first-parent merges (checked every 5 min);
#   - a completed CI run on the default branch is not "success" (reported once per run);
#   - a merge-seq.sh process ends.
# Restart it after every exit.
. "$(dirname "$0")/orch-env.sh"
st=${WATCH_STATE:-$ORCH_STATE/.watch-all.state}; R=$ORCH_REPO; touch "$st"
REPO=$(cd "$R" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
setkey() { grep -v "^$1 " "$st" > "$st.t"; [ -n "$2" ] && echo "$1 $2" >> "$st.t"; mv "$st.t" "$st"; }
pipes() { ps -axo pid=,args= | awk '$2 ~ /bash$/ && $3 ~ /\/merge-seq\.sh$/ {pid=$1; $1=""; $2=""; sub(/^ +/,""); print pid, $0}'; }
last_fetch=0; last_ci=0
while :; do
  new=""
  for f in "$ORCH_STATE"/pipe-*.out; do [ -f "$f" ] || continue; n=$(wc -l < "$f"); o=$(grep "^$f " "$st" | awk '{print $2}'); o=${o:-0}
    if [ "$n" -gt "$o" ]; then new="$new$(tail -n $((n-o)) "$f" | sed "s|^|$(basename "$f" .out): |")\n"; setkey "$f" "$n"; fi; done
  if [ $(( $(date +%s) - last_fetch )) -ge 300 ]; then
    git -C "$R" fetch -q "$ORCH_REMOTE" "$ORCH_MAIN" 2>/dev/null; last_fetch=$(date +%s)
    h=$(git -C "$R" rev-parse "$ORCH_REMOTE/$ORCH_MAIN" 2>/dev/null); o=$(grep "^main " "$st" | awk '{print $2}')
    if [ -n "$h" ] && [ "$h" != "$o" ]; then
      [ -n "$o" ] && new="$new$(git -C "$R" log --first-parent --format='main: merged %h %s' "$o..$h" 2>/dev/null | tail -r)\n"
      setkey main "$h"; fi; fi
  if [ -n "$REPO" ] && [ $(( $(date +%s) - last_ci )) -ge 300 ]; then last_ci=$(date +%s)
    while read -r rid concl sha; do [ -n "$rid" ] || continue; grep -q "^ci $rid\$" "$st" && continue
      echo "ci $rid" >> "$st"; [ "$concl" = success ] || new="${new}CI $concl on $ORCH_MAIN ${sha:0:9}: gh run view $rid --log-failed\n"
    done < <(gh run list -R "$REPO" --branch "$ORCH_MAIN" --status completed --limit 5 --json databaseId,conclusion,headSha \
               --jq '.[] | "\(.databaseId) \(.conclusion) \(.headSha)"' 2>/dev/null)
  fi
  cur=$(pipes)
  while read -r k pid args; do [ "$k" = pid ] || continue
    echo "$cur" | grep -q "^$pid " || { new="${new}ENDED: $args\n"; setkey "pid $pid" ""; }
  done < <(grep "^pid " "$st")
  while read -r pid args; do [ -n "$pid" ] && setkey "pid $pid" "$args"; done <<< "$cur"
  [ -n "$new" ] && { printf "$new"; exit 0; }
  sleep 60
done
