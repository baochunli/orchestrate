# Common rules for every builder (copy to $ORCH_BRIEFS/common.md and fill the <placeholders>)

Read the project config first: `<repo>/.claude/orchestrate.md`. It wins over anything here.

- **Scope.** Fix only what your brief names, with the simplest change. No unrequested features, no drive-by refactors.
  If a finding needs a product or policy decision the brief doesn't settle, stop and write it as an owner question
  (options + a recommendation) in your report instead of guessing.
- **Refusals and copy.** <project rule, e.g. "refusals state the real reason; authority refusals stay uniform">.
  Register any new user-visible text where the project requires (<registry path>). <naming/spelling/copy rules>.
- **Tests: red, then green.** Write or update tests that fail before the fix and pass after. Run ONLY the files you
  change or add, each alone (`<single-file test command>`). Never run full suites — CI does.
  - Integration tests: a throwaway database under `/tmp/<lane>-db` on a free port that is NOT `<forbidden port>`,
    a database name ending in `<suffix>`, started in CI's time zone (`<e.g. -c timezone=UTC>`); stop it afterwards.
  - If a permission check blocks a command, don't work around it; note it in the report.
- **Docs and UI change together.** If the change is user-visible, update `<docs paths>` in the same branch. If a
  screenshot shows the change: merge the latest default branch first, rebuild fresh, recapture only affected scenes
  (`<capture command>`), and look at every recaptured image. UI uses `<component library>`.
- **Gates** (once, on the final commit): `<gate commands>`.
- **Never:** `<forbidden actions, e.g. git stash, pkill, real env files, the real DB port, deploys>`.
- **Commits:** past tense; end with `<attribution trailer>`. Push to `origin <branch>`; do NOT open a PR.
- **Report** to `$ORCH_REPORTS/<branch>.md`: root cause, the change (file:line), tests (red then green, with
  counts), docs/screenshot changes, owner questions. Then reply with the SHA and a 4-line summary.
