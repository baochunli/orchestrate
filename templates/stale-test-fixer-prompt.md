PR #<n> (branch <branch>, worktree <worktree>) failed CI in <file> on: <test names>, with "<error excerpt>".

Classify first:
- STALE: the test exercises the old behavior that the branch's ruling (<rule>) intentionally changed → update the
  fixture/expectation to the new rule, keep what each test asserts, never weaken the rule.
- REAL: the branch broke something (e.g. a rewrite bypassed a mocked call path) → fix the code, not the test.
- PRE-EXISTING: also fails on origin/main → stop and report (reproduce once in a scratch worktree).
Merge origin/main first. Grep for other tests with the same stale setup and fix them too.
Run only the changed files, each alone (DB rules as in the project config); gates once. Never stash or pkill.
Commit with the attribution trailer; push. Reply in 3 lines: STALE/REAL per file, files changed, SHA.
