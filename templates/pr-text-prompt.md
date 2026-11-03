Write the PR title and description for branch <branch> (commit <sha>).
Sources: brief <path/section>; builder's report <path>; review verdict(s) <paths>; diff stat:
`git -C <repo> diff origin/main...origin/<branch> --stat` (for stacked branches use origin/<parent>).
Follow the project's PR instructions (<path, if any>) and copy rules from the project config.
Say what changed and why, call out migrations/deploy steps, list docs/screenshot updates, put the review's MEDIUM and
lower items and open owner questions under "Follow-ups", and put only the focused test runs under "Testing".
Write to $ORCH_STATE/pr/<stem>.txt: title on line 1, blank line, body, a line exactly `[GATES]`, blank line,
then the attribution line. Do not create the PR. Reply in one line.
