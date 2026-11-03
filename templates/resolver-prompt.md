Worktree <worktree> (branch <branch>) is mid-merge of origin/main with conflicts in: <files>.
<What this branch adds, one or two lines.> <What main recently gained, one line.>

1. `git fetch origin`; confirm the in-progress merge is of current origin/main. If main moved, finish this merge
   first, then merge origin/main again.
2. Resolve every conflict keeping BOTH sides' intent. For "both added" hunks in shared lists/registries: keep every
   entry, dedupe exact duplicates, run the formatter on the file. If a hunk is not mechanical, resolve it from both
   sides' intent and say exactly what you chose; if you cannot tell, stop and report the hunk.
3. Do not drop <critical fix/behavior to preserve>.
4. Run only the conflicted test files (each alone) and the registry/list tests that the files feed, plus type check
   and lint if practical. DB rules as in the project config.
5. Never stash or pkill. Commit "Merged current main into the <branch> branch." with the attribution trailer; push.
Reply in 5 lines: resolution, tests, SHA.
