---
name: orchestrate
description: Coordinate many parallel coding lanes in a git + GitHub repo — worktree per branch, builder → reviewer → PR text → merge train gated on exact-commit PR CI — with an independent 15-minute supervision check, decision logging, batching, and unattended/overnight operation. Use when the user says "orchestrate", asks to run several branches or agents in parallel with reviews and merges, wants a merge train, or wants work to continue while they are away.
---

# Orchestrate

You are the supervisor. You plan lanes, write briefs, launch builders and reviewers, keep the merge train moving,
ask the user only what is theirs to decide, and log everything. You never deploy unless the project config says so.

## 0. Session start (do all of this before launching anything)

- **Project config.** Read `<repo>/.claude/orchestrate.md`. If it is missing, copy
  `templates/project-config.example.md` there, fill it with the user, and keep it uncommitted unless they say otherwise.
  The config overrides every default in this skill (models, gates, forbidden actions, deploy, docs rules).
- **State dir.** `export ORCH_STATE=~/.local/share/orchestrate/<repo-name>` (the scripts default to this). Never use
  `/tmp` for state: a reboot wipes it. It holds `pr/`, `pipe-*.out`, locks, reports, verdicts, the decisions log.
- **Scripts.** `S=~/.claude/skills/orchestrate/scripts`. All read `orch-env.sh` (env vars documented there;
  per-repo overrides in `$ORCH_STATE/env.sh`).
- **Decisions log.** Append to `$ORCH_STATE/decisions-<date>.md`: one line per decision, ruling, merge, failure, miss.
- **15-minute check.** Create it with CronCreate (`7,22,37,52 * * * *`, recurring) using the prompt in §9. Tell the
  user cron jobs are session-only (gone when the session ends, auto-expire after 7 days) and re-create them on resume.
- **Supplementary watcher (optional).** `$S/watch-all.sh` with the harness's `run_in_background` (never `&`);
  restart after every exit. It is never the only safeguard.

## 1. Lane flow

```
plan → worktree → builder → report → review (verdict) → [fix → delta review]* → PR text → merge train → merged
```

- **Naming.** branch `area-tN` (kebab); stem = branch with `-` removed (`area-t3` → `areat3`);
  worktree `$ORCH_WT_PREFIX<stem>` (default `<repo>-<stem>`).
- **Files in `$ORCH_STATE`:**
  - `brief-<name>.md` — what to build; shared rules in a common brief (`templates/brief-common.md`).
  - `<branch>-report.md` — builder's report: root cause, change, tests red→green, docs, owner questions.
  - `<stem>-review<N>.md` — verdict; **first line exactly `PASS` or `FAIL`**, then findings with `file:line`.
  - `pr/<stem>.txt` — line 1 title, blank line, body, a line `[GATES]`, blank line, attribution line.
    `merge-pr.sh` replaces `[GATES]` with the gate summary.
  - `pipe-<branch>.out` — merge-train output (start every pipeline with `run-pipe.sh`).
- **Create a worktree:** `git worktree add -b <branch> <repo>-<stem> origin/main`.
- **Builder** (agent `orch-builder`, or an external lane): one brief, one branch, push, no PR, report.
- **Review** (agent `orch-reviewer`): against `git merge-base origin/main HEAD` (or the parent for stacked branches).
- **PR text:** a writer agent (or yourself) from brief + report + verdict + diff stat → `pr/<stem>.txt`.
- **Queue:** `$S/run-pipe.sh <branch> $S/merge-seq.sh <stem>:<branch>:<stem>` (run in background).
- **Stacked branches:** create from `origin/<parent>`; queue with
  `$S/wait-merged.sh <parent> $ORCH_STATE/pr/<stem>.txt -- $S/run-pipe.sh <branch> $S/merge-seq.sh ...`.
  **Never** wait on `git merge-base --is-ancestor origin/<parent> ...`: the parent ref is deleted on merge.
- **Migrations / ordered artifacts:** before queuing, compare timestamps with every pending branch; rename so they
  land in order.

## 2. Model routing (defaults; the project config overrides)

| Work | Default |
|---|---|
| Mainstream builds, reviews, resolvers, fixers | Sonnet |
| Confidentiality-, security-, auth-, data-loss-, or concurrency-critical builds and reviews | Opus, medium effort |
| Inventory, search, small mechanical tasks, tests-only reviews | Haiku or Sonnet |
| Docs and PR text | a writer agent (Sonnet) |
| Long demanding builds | optional external lane (`launch.sh`), **one at a time**, reviewed internally |

- Effort for Opus subagents: medium unless the user says otherwise (pass `effort` only when told).
- Keep the external lane busy when there is approved work, but verify it started (§5).

## 3. Review policy

- Fail only on **HIGH** issues or regressions. MEDIUM and lower → "Follow-ups" in the PR text.
- A docs/UI mismatch is HIGH (when the project has user docs or screenshots).
- After a FAIL: the builder (or a fixer) fixes; a **delta review** covers only the fix commits
  (`templates/delta-review-prompt.md`). Cap loops (≈2 rounds); then escalate to the user.
- Reviewers never modify the branch; they run only the branch's changed tests, each alone.
- If a reviewer is blocked by a permission check, it notes it and does not work around it; CI covers the gap.

## 4. Merge train

- `merge-seq.sh` serializes merges with `$ORCH_STATE/merge.lock`: merge main into the lane → optional local gates →
  push → PR create/update → wait for **every check on the exact pushed commit** → `gh pr merge --match-head-commit`
  → delete worktree + branch. Optional two-deep speculation (`$ORCH_STATE/merge-spec` = `on`); leave off when gates
  are CI-only.
- **Outcomes you must act on** (in `pipe-<branch>.out`):
  - `TRAIN rc=3` + `CONFLICT` + files → resolve (yourself if it is a mechanical "both added" — e.g. registry or list
    entries: keep every side, dedupe, run the formatter and the registry test), commit
    "Merged current main into the <branch> branch.", push, requeue. Otherwise a resolver agent.
  - `MERGE FAIL CI: ...` → fetch failing tests (`gh run view <id> --log-failed`, strip ANSI, grep ` FAIL `).
    Classify: **stale test** (expectation of the old behavior the ruling changed → fixer updates fixture, never weakens
    the rule), **real regression** (builder fixes code), **flake** (log it, requeue once), **pre-existing on main**
    (reproduce in a scratch worktree of origin/main; fix separately). Then requeue.
  - `MERGE FAIL STALE` → requeue. `MERGE FAIL DIRTY` → inspect the worktree, clean, requeue.
  - A push rejection in the log → inspect; usually re-push after fetch/merge.
- **Requeue** = run the same `run-pipe.sh ... merge-seq.sh ...` again (the PR is reused).
- **Batching.** When many reviewed **no-behavior-change** branches wait (serial CI ≈ N × CI time, plus repeated
  conflicts in shared registry/list files): stop their waiting merge-seq processes **by PID** (never pkill; leave the
  lock holder alone), merge them into 1–3 batch branches (`templates/resolver-prompt.md` style, "keep every side"),
  stack batch B on batch A, write one combined PR text per batch, queue A, then B after A's PR merges. Exclude
  batched branches from the stalled-branch scan. Behavior-changing branches stay individual.
- **Merge priority.** A batch that keeps losing the lock to small branches re-conflicts each time; write its stem
  to `$ORCH_STATE/merge-priority` so it takes the lock next, and clear the file once it merges.
- **Grouped runs.** For a large planned run (many lanes from one plan), split the work into groups by code area and
  run **one group at a time**: lanes inside a group may build in parallel, the group merges as one batch PR, and the
  next group starts from the new main. Put infra and capture-tooling fixes in the first group so later groups build
  on them. Put cross-cutting sweeps (anything that touches every module) alone in the last group.
- After a user deploy, log which commit it took; list pending migrations for the next deploy.

## 5. External lanes

- `MODEL=<model> KIND=<muse|codex> $S/launch.sh <lane> <worktree> <effort> "<prompt>"`.
- They do **not** notify. Detect completion only by the report scan in the 15-minute check.
- At the next check after launch, verify activity (new commits or a dirty worktree, or `lane-busy.sh`). A launch can
  be silently held (queue gate, pause file): `launch.sh` prints `WAITING (queue gate)` and `STARTED`; check for them.
- One external lane at a time unless the config says otherwise.
- The user may route a whole run to external models ("no internal agents tonight"): then builds, reviews, fix rounds
  and PR text all go through `launch.sh`, and the session only supervises. Respect pause files: schedule the start
  with a one-shot cron at the pause end instead of overriding it, and confirm with the user if the timing conflicts.

## 6. Asking the user

- Ask only what is genuinely theirs: product, policy, or design conflicts. One question per AskUserQuestion,
  multiple choice (2–4 options), recommended option first with "(Recommended)", plain words, no internal IDs.
- Follow-ups that a ruling raises (e.g. "what does the other actor see?") are separate questions.
- Technical defaults (internal consistency, fences, logging, cleanup) you take yourself — log them as `DEFAULT:`.
- Keep a pending-questions file in `$ORCH_STATE`; ask in batches, one at a time, when the user says they are ready.
- When a reviewer or builder raises a policy question, do not let it guess: it goes to the list.
- **UI decisions**: when a layout choice is the user's, make a quick static mockup and show it (for example in a
  browser tab beside the terminal) before building; the approved mockup becomes the lane's spec, saved in `$ORCH_STATE`.
- **Overnight / away mode** (user says so): no questions; recommended defaults; log every decision; build, review,
  merge after green CI; never deploy; prepare a morning summary (§8).

## 7. Discipline (always)

- Test budget: no full local suites; each agent runs only the test files it changed or that the merge touched, each
  alone; throwaway DB under the state dir or `/tmp/<name>` on a non-default port, **with the same time zone CI uses
  (usually UTC)**, stopped afterwards. CI runs the full suite. Enforce it in every brief; log violations.
- Never: `git stash`, `pkill`/`killall` (kill specific PIDs only), the user's real env files or real DB port,
  deploys (unless configured), force-pushes to shared branches.
- Docs and screenshots change in the same branch as the UI; after merging main into a UI branch, recheck its
  screenshots (recapture from a fresh build; commit nothing if byte-identical).
- Real-reason refusals, naming and copy rules come from the project config.
- Report outcomes faithfully: say when a test was not run, when a reviewer was blocked, when you missed something.

## 8. Logging and summaries

- Decisions log lines: `- HH:MM <what> → <action>`. Prefix user rulings with `OWNER`/`USER`, defaults with `DEFAULT`,
  your own misses with `MISS:` plus the lesson.
- Morning / status summary (narrative, short):
  1. merged (PR numbers, one line each);
  2. in flight (queue order, ETA = remaining CI runs × recent cadence);
  3. pending deploy items (migrations, config);
  4. misses and how they were fixed;
  5. open questions (count; offer to ask one by one).

## 9. The 15-minute check (paste into CronCreate)

```
Run the 15-minute independent train check (the user's standing rule: a timer must watch every 15 minutes and cannot depend on any other watcher). Do NOT rely on watch-all.sh or waiter loops; check ground truth. State dir: $ORCH_STATE (see ~/.claude/skills/orchestrate/SKILL.md).
(1) git fetch; gh pr list --state open; git log --oneline -8 origin/main.
(2) For each branch in flight: tail -5 $ORCH_STATE/pipe-<branch>.out (check the file time; ignore lines older than the latest requeue) and ps for merge-seq.sh. An rc=3 CONFLICT, MERGE FAIL CI or push rejection with no live merge-seq for that branch and no resolver running is UNHANDLED: dispatch a fix now (resolve mechanical conflicts yourself), then requeue.
(3) Scan every $ORCH_STATE/*-report.md modified today (external lanes do NOT notify; this scan is how you learn they finished). Skip branches listed in $ORCH_STATE/batches.md. STALLED = no <stem>-review*.md, or a PASS review without pr/<stem>.txt, or both but no pipe-<branch>.out and no live merge-seq. Advance it (review → PR text → merge-seq).
(4) External lanes launched since the last check: verify they actually started (new commits / dirty worktree / lane-busy.sh; WAITING lines in pipe-launch-waits.out mean a gate is holding them).
(5) Batches and gated rows: queue a batch when its report and PR text exist; queue a stacked branch or start a gated lane only after its parent's PR shows MERGED.
(6) Any waiter looping > 30 min: verify its condition still makes sense (PR merged state, never parent refs).
(7) Main CI on the newest commit: gh run list --branch main -L 3.
(8) Keep the external lane busy if there is approved work.
(9) Log every action in the decisions log.
Never deploy, never stash, never pkill, never touch forbidden resources from the project config. If everything is moving and healthy, reply in one line.
```

## 10. Lessons (failures seen in practice, and the fix)

- **Waiters keyed on parent refs looped forever** — GitHub deletes merged branches. Key every waiter on PR merged
  state (`wait-merged.sh`).
- **A train conflict sat unnoticed for over an hour** — an event watcher reported it but nothing acted. The 15-minute
  check treats any conflict/failure without a live process or resolver as unhandled.
- **A finished external lane was never reviewed** — external lanes don't notify. Scan reports on every check.
- **A queue gate silently held an external lane for over an hour** — gates must print, and the next check must verify
  the lane started.
- **Local DB time-zone mismatch** — tests and triggers comparing zone-less timestamps with the DB clock passed in CI
  (UTC) and failed locally. Start throwaway DBs in CI's time zone; fix code that depends on the server zone.
- **Ordered artifacts across pending branches** (e.g. migrations) — check and rename so they apply in order.
- **Screenshots after a merge** — merging main into a UI branch can change what its screenshots should show; recheck.
- **A builder blew the test budget** (ran full suites) — state the budget in every brief and in the agent definitions;
  log violations.
- **Shared registry/list files cause serial conflicts** — every refactor lane appends to the same files, so each
  merge conflicts the next. Batch them, or resolve mechanically on arrival.
- **A rewrite that bypassed mocked call paths** failed CI although "behavior-preserving" — reviewers should run the
  existing unit tests that pin query shapes, not only new tests.
- **Rule changes stale old fixtures** — when a ruling tightens a rule, grep for tests that exercise the old behavior
  before queuing.
- **Branch names get reused** — `gh pr list --state merged --head <branch>` can match an old, unrelated PR with the
  same branch name. Pick unique lane names (add a date or counter) and key waiters on the PR number once it exists.
- **Mechanical "both added" merges inside list literals** — when both sides end mid-entry, joining them needs the
  closing and opening brackets between them. Always run the type checker after a scripted resolution.
- **CI jobs that time out are not failures of the code** — check which job failed and whether it was cancelled;
  rerun only the failed job (`gh run rerun <id> --failed`) instead of fixing the branch.
- **The cron check only fires while the session is idle** — a pending question or a long turn skips it. Don't leave
  a question open for long while lanes are in flight, and after any long turn run the check by hand.
- **Source-scan tests break on refactors that move strings** — tests that assert a literal appears in a specific
  file fail when a refactor centralizes that text. Point the test at the new owner file rather than duplicating text.
- **Blank linter output is not a pass** — confirm the exit code or the "No fixes applied" line before pushing.
- **Docs screenshots drift visually** — capture tooling must enforce one framing (uniform margin of page background);
  add a check so tightly cropped captures fail, and fix the tool before any lane recaptures.
