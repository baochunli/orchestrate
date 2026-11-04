Review branch {{BRANCH}} (commit {{SHA}}) in {{WORKTREE}} against `git merge-base origin/main HEAD`
(for a stacked branch: against origin/<parent>). Brief: {{BRIEF}}. Builder's report: {{REPORT}}.

Check:
- every acceptance criterion and rule in the brief (for refactors: NO behavior change: predicates, locks, texts,
  response shapes unchanged, registry complete);
- docs and UI match the behavior (a mismatch is HIGH); project copy rules from the config;
- changed existing tests are justified by the brief, not hiding a behavior change.

Fail only on HIGH issues or regressions; list MEDIUM and lower as follow-ups.
Test budget: run only the branch's changed or new test files, each alone, plus any existing tests the change affects.
Integration: throwaway DB per the project config (CI's time zone, never the real port), stopped afterwards.
If a permission check blocks you, note it and don't work around it. Never stash or pkill. Do not modify the branch.
Write the verdict to {{VERDICT}} — first line exactly PASS or FAIL, then findings with file:line.
Reply in 3 lines.
