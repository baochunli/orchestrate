Delta review of branch <branch> in <worktree>: review `git diff <old-sha> <new-sha>` only.
Previous verdict (FAIL): $ORCH_STATE/<stem>-review<N-1>.md. Fixer's notes: <report section>.

Verify each previous HIGH is fixed:
- <H1: expected fix>
- <H2: expected fix>
Check the fixes introduce no regression and no new leak; formatting-only changes are formatting only; new tests
would fail without the fixes.
Fail only on HIGH issues or regressions. Run only the files changed in the delta, each alone (DB rules as in the
project config). Never stash or pkill; do not modify the branch.
Write $ORCH_STATE/<stem>-review<N>.md (first line PASS or FAIL). Reply in 2 lines.
