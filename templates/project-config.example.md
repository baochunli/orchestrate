# Orchestrate project config — <project name>

Copy to `<repo>/.claude/orchestrate.md` and fill in. Agents read this before any brief. Keys are examples; delete
what doesn't apply.

## Repo
- Default branch: `main`. Remote: `origin`. Worktrees: `<repo>-<stem>`.
- State dir: `~/.local/share/orchestrate/<repo-name>` (`ORCH_STATE`). Optional `$ORCH_STATE/env.sh` for script vars.

## Tests and gates
- Single test file: `<e.g. bunx vitest run <file>>` / `<pytest path::test>`.
- Integration DB: throwaway `<postgres|mysql|...>` under `/tmp/<lane>-db`, free port, NOT `<real port, e.g. 5432>`,
  DB name ending `<_test>`, time zone `<UTC>` (match CI), env var `<DATABASE_URL_TEST>`; stop afterwards.
- Gates (final commit): `<install --frozen-lockfile; codegen; lint; build; type check>`.
- Full suites: CI only (`<workflow name>`). Local full runs: <forbidden>.
- `ORCH_LOCAL_GATES`: `<empty = CI only>`. `ORCH_GATES_TEXT`: `<"full suite in PR CI: ...">`.

## Forbidden
- `<git stash>`, `<pkill/killall>`, `<real env file, e.g. .env.local>`, `<real DB port>`, `<deploys>`,
  `<force-push to main>`, `<names that must never appear, e.g. hostnames>`.

## Deploy
- `<Who deploys and how, e.g. "owner only, by hand: <command>">`. Agents never deploy.

## Copy, docs and UI
- Spelling/locale: `<e.g. US spelling>`. Names vs IDs: `<rule>`. Words never to use: `<e.g. competitor names>`.
- Refusals: `<e.g. state the real reason; authority refusals stay uniform>`; registry `<path>`.
- Docs paths: `<user docs>`, `<admin docs>`; public docs never mention `<internals>`.
- UI component library: `<library>`. Screenshots: `<capture command>`; recapture after merging main; view each image.

## Models and lanes (override the skill defaults)
- Mainstream: `<sonnet>`. Critical: `<opus, medium effort>`. Simple: `<haiku>`. Writer agent: `<name>`.
- External lane: `<MODEL=... KIND=muse|codex launch.sh ...>`, one at a time; paused/blocked models: `<...>`.

## Owner preferences
- Questions: one at a time, multiple choice, recommended first.
- Away/overnight mode: no questions, defaults, log, merge after green CI, never deploy, morning summary.
- `<Other standing rulings, each with a date>`.
