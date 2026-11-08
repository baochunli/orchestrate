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
  `/tmp` for state, not even through a symlink: a reboot wipes it. Typed subfolders (variables in `orch-env.sh`):

  | Folder | Holds | In the state repo |
  |---|---|---|
  | `briefs/` | `<branch>.md`, `common.md` | yes |
  | `reports/` | builder reports `<branch>.md` | yes |
  | `reviews/` | verdicts `<stem>-review<N>.md` | yes |
  | `pr/` | PR texts `<stem>.txt` | yes |
  | `pipes/` | pipeline and merge-train output `<name>.out`; runner log `merge-queue.out` | yes |
  | `logs/` | `decisions-<date>.md` (tracked); train and gate logs (untracked) | partly |
  | `plans/` | plans, batches, approved mockups | yes |
  | `run/` | `merge.lock`, `merge-queue/`, `merge-result/`, pause files, `model-overrides.txt` | overrides only |
  | `archive/<yyyy-mm>/` | finished one-off scripts, prompts, old notes | text only |
  | `artifacts/<yyyy-mm>/` | screenshots, scratch databases, large logs | no |

  Optionally make the state dir a private git repo with a whitelist `.gitignore` and push it hourly.
- **Scripts.** `S=~/.claude/skills/orchestrate/scripts`. All read `orch-env.sh` (env vars documented there;
  per-repo overrides in `$ORCH_STATE/env.sh`).
- **Decisions log.** Append to `$ORCH_LOGS/decisions-<date>.md`: one line per decision, ruling, merge, failure, miss.
- **15-minute check.** Create it with CronCreate (`7,22,37,52 * * * *`, recurring) using the prompt in §9. Tell the
  user cron jobs are session-only (gone when the session ends, auto-expire after 7 days) and re-create them on resume.
- **Supplementary watcher (optional).** `$S/watch-all.sh` with the harness's `run_in_background` (never `&`);
  restart after every exit. It is never the only safeguard.

## 1. Lane flow

```
plan → worktree → builder → report → review (verdict) → [fix → delta review]* → PR text → merge train → merged
```

- **Granularity: coarse bundles, not a PR per request.** Each branch, review, PR text and CI run has a fixed cost,
  and the merge queue is serial, so tiny PRs pile up behind each other. Keep one open **bundle branch per area**
  (e.g. live-test fixes, dashboard/UI tweaks, email changes) and add each new small request to the matching bundle
  while it is still building (append to its brief, prompt the lane). Small fixes (CI fixes, docs or test tweaks,
  follow-ups) ride along in a related branch, never their own PR. One review per bundle (delta re-review after
  fixes), one CI run per bundle. Start a separate branch only for large or risky work (migrations, auth,
  confidentiality, data rewrites), work that blocks others, or when the area's bundle is already in review or the
  merge queue. Aim for a handful of PRs per day, not dozens.
- **Naming.** branch `area-tN` (kebab); stem = branch with `-` removed (`area-t3` → `areat3`);
  worktree `$ORCH_WT_PREFIX<stem>` (default `<repo>-<stem>`).
- **Files:**
  - `briefs/<branch>.md` — what to build; shared rules in `briefs/common.md` (from `templates/brief-common.md`).
  - `reports/<branch>.md` — builder's report: root cause, change, tests red→green, docs, owner questions.
  - `reviews/<stem>-review<N>.md` — verdict; **first line exactly `PASS` or `FAIL`**, then findings with `file:line`.
  - `pr/<stem>.txt` — **line 1 the title**, blank line, body, a line `[GATES]`, blank line, attribution line.
    `merge-pr.sh` replaces `[GATES]` with the gate summary. Check line 1 is a title, not a body sentence.
  - `pipes/<branch>.out` — pipeline and merge-train output (start every pipeline with `run-pipe.sh`).
- **Create a worktree:** `git worktree add -b <branch> <repo>-<stem> origin/main`.
- **Builder** (agent `orch-builder`, or an external lane): one brief, one branch, push, no PR, report.
- **Review** (agent `orch-reviewer`): against `git merge-base origin/main HEAD` (or the parent for stacked branches).
- **PR text:** a writer agent (or yourself) from brief + report + verdict + diff stat → `pr/<stem>.txt`.
- **Queue:** `$S/run-pipe.sh <branch> $S/merge-seq.sh <stem>:<branch>:<stem>` (run in background).
- **Chained external lanes:** `launch.sh` is single-stage (starts one lane and stops). `pipeline.sh` chains
  build → report check → review → PR text → merge train: `$S/run-pipe.sh <branch> $S/pipeline.sh <branch> '<deps>|-' [full]`.
  For an already-built branch run `review-chain.sh <stem> <branch>`; `CHAIN_NO_MERGE=1` stops after the PR text.
  A failed review prints `CHAIN FAIL <stem>: <verdict head>`; the 15-minute check must grep `pipes/*.out` for it.
- **Stacked branches:** create from `origin/<parent>`; queue with
  `$S/wait-merged.sh <#parent-PR> $ORCH_PR/<stem>.txt -- $S/run-pipe.sh <branch> $S/merge-seq.sh ...`.
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
- **Real-browser verification for app-wide client changes.** If a branch runs on every page or touches page loading,
  reload/recovery, inline or head scripts, routing, caching headers, session/auth refresh or global error boundaries,
  the builder must run the production build in real browsers (e.g. Playwright Chromium and WebKit, desktop and phone
  width), signed in and out, idle for minutes (clock fast-forward), with focus/visibility changes, a session refresh and
  a client navigation, and report the evidence: no self-reload, no error page, no console errors. The reviewer repeats
  the check and fails the branch without it. Unit tests and review alone missed a site-wide self-reload loop.
- If a reviewer is blocked by a permission check, it notes it and does not work around it; CI covers the gap.

## 4. Merge train

- `merge-seq.sh` is a **FIFO** train: one branch at a time, one CI run per attempt (`merge-queue.sh`).
  - **Enqueue:** checks the worktree (`TRAIN rc=2`, `MERGE FAIL DIRTY`), pushes the branch only if it has no open PR
    (a push to an open PR starts CI), and appends it to `$ORCH_RUN/merge-queue/<stem>` with the next sequence number:
    `<wt> queued at position N`. It never opens or updates the PR. Requeueing a queued stem keeps its position
    (`already queued: keeping position N`; the newest merge-seq takes over the waiting, the older one exits).
    `merge-queue-len.sh --list` prints the queue in order.
  - **Turn (front item only; one runner under `$ORCH_RUN/merge.lock`, a dead owner's lock is reclaimed):** merge
    current main into the lane ("Merged current main into the <branch> branch."; conflict → `<wt> TRAIN rc=3` +
    `CONFLICT` + files, removed from the queue), optional local gates, push, create/update the PR from
    `pr/<stem>.txt` — the single CI run — wait for **every check on the exact pushed commit** (`ci-wait.sh`),
    `gh pr merge --match-head-commit`, delete worktree + branch. Lines are the classic train's (`<wt> gates: ...`,
    URL, `waiting for GitHub CI`, `GitHub CI passed`, `merged`, main commit line).
  - **CI red:** `MERGE FAIL CI: ...` + `<wt> moved to the end of the merge queue (position N)`; the next item goes.
    At its next turn: new commits on the branch (pushed or committed in the worktree) → a fresh attempt; unchanged →
    one rerun (merge main again; if the commit is identical, `gh run rerun --failed`, printed as `rerunning the
    failed CI`); a second failure with no new commits → `MERGE FAIL CI: ... (removed after 2 attempts; requeue after
    fixing)`. So for a red branch: fix and push; the queued item picks the fix up at its turn (no requeue needed).
  - **Head moved while waiting:** if the PR head changes during the CI wait (a fix was pushed), `ci-wait.sh` stops at
    once (exit 4, `HEAD MOVED: head moved from X to Y; requeue to test the new head`). Not a failure: the item keeps its
    position and attempt count (`<wt> stays at position N`) and its next turn tests the new head.
  - **Infra-outage tolerance:** when every failed run's `--log-failed` shows an infrastructure error (HTTP 5xx such as
    `Unexpected HTTP response: 504`, `curl: (22) ... error: 503`, download failures; patterns in `ci-infra.sh`) and no
    real test failure, `ci-wait.sh` reruns the failed jobs (`gh run rerun --failed`) after a backoff and keeps waiting;
    it prints no `MERGE FAIL CI` and no attempt is used. `ORCH_INFRA_RERUNS` (default 6, 0 = off) caps the reruns,
    `ORCH_INFRA_BACKOFF` (default 300 s, grows per rerun up to 600 s) is the wait. Exhausted → a normal
    `MERGE FAIL CI: ... (infra outage persisted after N reruns)`. Any real test failure counts at once.
  - **Label-gated CI (`ORCH_TURN_LABEL`, e.g. `merge-turn`; unset = off).** For a repo whose workflow runs the full PR
    suite only while the PR carries that label (other pushes to an open PR run only cheap jobs, so fix pushes never
    hold a CI runner outside their turn). At the turn, `merge-pr.sh` records the commit's existing workflow runs,
    pushes, opens/updates the PR, removes the label if a crashed turn left it (`removed a leftover <label> label`) and
    adds it (`added the <label> label ...`): the `labeled` event starts exactly one full run on the current head, also
    when the push was a no-op. `ci-wait.sh` then ignores the cheap runs' skipped checks and cancelled runs and passes
    only when a run started at this turn succeeded with the job `ORCH_REQUIRED_CHECK` (a job that runs only in full
    runs and only succeeds when they do); any failed run fails. The label is removed when the turn ends (merged, red,
    or any failure). An identical-commit second attempt gets a fresh full run via the label instead of
    `gh run rerun --failed` (`rerunning the full CI ... via the <label> label`). To start a full run by hand, add the
    label to the PR; remove it afterwards. Enable the setting before (or together with) the workflow change: with the
    gated workflow on main and the setting unset, the classic wait passes on skipped checks.
  - Stopping a waiting merge-seq by PID removes its item (never stop the runner). Runner log: `pipes/merge-queue.out`.
  - The batch train and `merge-priority` are retired; `merge-batch.sh` is a shim, and the runner drains any
    leftover `$ORCH_RUN/batch-queue/` items first with classic trains.
  - Tests: `tests/queue-test.sh` (bare origin + fake `gh`; fifo, red, flake, twofail, conflict, legacy; label-gated:
    label, race, leftover, noop, prelabel).
- **Outcomes you must act on** (in `pipes/<branch>.out`):
  - `TRAIN rc=3` + `CONFLICT` + files → resolve (yourself if it is a mechanical "both added" — e.g. registry or list
    entries: keep every side, dedupe, run the formatter and the registry test), commit
    "Merged current main into the <branch> branch.", push, requeue. Otherwise a resolver agent.
  - `MERGE FAIL CI: ...` (item moved to the end, or removed after 2 attempts) → fetch failing tests (`gh run view <id> --log-failed`, strip ANSI, grep ` FAIL `).
    Classify: **stale test** (expectation of the old behavior the ruling changed → fixer updates fixture, never weakens
    the rule), **real regression** (builder fixes code), **flake** (log it, requeue once), **pre-existing on main**
    (reproduce in a scratch worktree of origin/main; fix separately). Push the fix; requeue only if it was removed.
  - `MERGE FAIL STALE` → requeue. `MERGE FAIL DIRTY` → inspect the worktree, clean, requeue.
  - `MERGE FAIL PUSH` (push rejected, or the remote branch is not a fast-forward of the worktree) → fetch, merge the
    remote branch, requeue.
  - A push rejection in the log → inspect; usually re-push after fetch/merge.
- **Requeue** = run the same `run-pipe.sh ... merge-seq.sh ...` again (the PR is reused; a removed item goes to the end).
- **Manual batch branches** are only needed for branches that conflict with each other in shared registry/list
  files (each one conflicts after the other merges): merge them into one branch (`templates/resolver-prompt.md` style,
  "keep every side"), write one combined PR text, queue it. Exclude batched branches from the stalled-branch scan.
- **Grouped runs.** For a large planned run (many lanes from one plan), split the work into groups by code area and
  run **one group at a time**: lanes inside a group may build in parallel, the group merges as one batch PR, and the
  next group starts from the new main. Put infra and capture-tooling fixes in the first group so later groups build
  on them. Put cross-cutting sweeps (anything that touches every module) alone in the last group.
- After a user deploy, log which commit it took; list pending migrations for the next deploy.

## 5. External lanes

- `MODEL=<model> KIND=<muse|codex> $S/launch.sh <lane> <worktree> <effort> "<prompt>"` starts ONE lane and stops.
  `pipeline.sh` (build, review, PR text, merge) and `review-chain.sh` chain lanes; `wait-lanes.sh <lane>...` waits on
  herdr status and re-prompts lanes stopped by a capacity error. Set `BUILD_MODEL`, `REVIEW_MODEL`, `PRTEXT_MODEL` (+
  `*_EFFORT`), falling back to `ORCH_MODEL`/`ORCH_EFFORT` in `$ORCH_STATE/env.sh`. Review and PR-text prompts come from
  `templates/review-prompt.md` and `pr-text-prompt.md` (tokens filled by the script; project rules via `BUILD_EXTRA`,
  `REVIEW_EXTRA`, `PRTEXT_EXTRA`).
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
- Keep a pending-questions file in `$ORCH_PLANS`; ask in batches, one at a time, when the user says they are ready.
- When a reviewer or builder raises a policy question, do not let it guess: it goes to the list.
- **UI decisions**: when a layout choice is the user's, make a quick static mockup and show it (for example in a
  browser tab beside the terminal) before building; the approved mockup becomes the lane's spec, saved in `$ORCH_PLANS`.
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
(2) grep -h "CHAIN FAIL" $ORCH_PIPES/*.out (a failed review or lane: act on it). For each branch in flight: tail -5 $ORCH_PIPES/<branch>.out (check the file time; ignore lines older than the latest requeue) and ps for merge-seq.sh. An rc=3 CONFLICT, MERGE FAIL CI or push rejection with no live merge-seq for that branch and no resolver running is UNHANDLED: dispatch a fix now (resolve mechanical conflicts yourself), then requeue.
(3) Scan every $ORCH_REPORTS/*.md modified today (external lanes do NOT notify; this scan is how you learn they finished). Skip branches listed in $ORCH_PLANS/batches.md. STALLED = no reviews/<stem>-review*.md, or a PASS review without pr/<stem>.txt, or both but no pipes/<branch>.out and no live merge-seq. Advance it (review → PR text → merge-seq).
(4) External lanes launched since the last check: verify they actually started (new commits / dirty worktree / lane-busy.sh; WAITING lines in pipes/launch-waits.out mean a gate is holding them).
(5) Batches and gated rows: queue a batch when its report and PR text exist; queue a stacked branch or start a gated lane only after its parent's PR shows MERGED.
(6) Any waiter looping > 30 min: verify its condition still makes sense (PR merged state, never parent refs).
(7) Main CI on the newest commit: gh run list --branch main -L 3.
(8) Keep the external lane busy if there is approved work.
(9) Log every action in the decisions log.
Never deploy, never stash, never pkill, never touch forbidden resources from the project config. If everything is moving and healthy, reply in one line.
```

## 10. Lessons (failures seen in practice, and the fix)

- **A page-load recovery script took the whole site down** — it passed unit tests and review, but in real Chrome the
  router re-ran the inline head script, and every page reloaded itself after 30 s and then showed an error. Verify
  app-wide client changes in real browsers, idle for minutes (§3).
- **Fourteen PRs in one afternoon backed the queue up for hours** — one branch per small request meant fourteen reviews,
  PR texts and serial CI runs on one runner. Bundle small requests per area (§1 Granularity).
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
- **State kept in /tmp was lost on reboot** — everything lives in `$ORCH_STATE` (typed subfolders, a private git
  repo pushed hourly); never a /tmp symlink. Archiving a file a live script reads breaks it: grep every script for
  a file's name before moving it.
- **A batch of separately reviewed lanes still failed CI** — tests outside every lane's own files went stale: factory
  mocks missing a newly exported function, fixtures asserting a rule the batch changed, contract tests (one-sentence
  copy, refusal registries, demo navigation). Before queuing a batch, run each lane's changed unit tests, the
  contract and guard tests, and every unit test that factory-mocks a module the batch changed.
- **merge-priority named the wrong stem** — the train waited 10 minutes for a stem that was never queued. Write the
  exact queued stem, and clear the file after the merge.
- **A requeued, unchanged commit failed again at once** — the train reuses the exact commit's CI result. After a
  flake, rerun the failed job (`gh run rerun <id> --failed`) before requeuing.
- **A PR title was a body sentence** — the PR-text lane left out the title line. Check line 1 of `pr/<stem>.txt`.
- **Review loops kept finding new HIGHs** — after the first fix round, review only the delta (`templates/delta-review-prompt.md`).
- **Docs screenshots drift visually** — capture tooling must enforce one framing (uniform margin of page background);
  add a check so tightly cropped captures fail, and fix the tool before any lane recaptures.
