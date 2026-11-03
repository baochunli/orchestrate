Review branch <branch> (commit <sha>) in <worktree> against `git merge-base origin/main HEAD`
(for a stacked branch: against origin/<parent>). Brief: <brief path/section>. Builder's report: <report path>.

Check:
- <the exact rules the brief demands — list them; for refactors: "NO behavior change: predicates, locks, texts,
  response shapes unchanged; registry complete">;
- <confidentiality / security focus if relevant: "no information leaks to <actor> through text, shape, timing">;
- docs and UI match the behavior (a mismatch is HIGH); project copy rules from the config;
- changed existing tests are justified by the brief, not hiding a behavior change.

Fail only on HIGH issues or regressions; list MEDIUM and lower as follow-ups.
Test budget: run only the branch's changed or new test files, each alone<, plus these existing files: ...>.
Integration: throwaway DB per the project config (CI's time zone, never the real port), stopped afterwards.
If a permission check blocks you, note it and don't work around it. Never stash or pkill. Do not modify the branch.
Write the verdict to $ORCH_STATE/<stem>-review<N>.md — first line exactly PASS or FAIL, then findings with file:line.
Reply in 3 lines.
