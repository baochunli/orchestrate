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
  | `pipes/` | pipeline and merge-train output `<name>.out`; batch runner log `merge-batch.out` | yes |
  | `logs/` | `decisions-<date>.md` (tracked); train and gate logs (untracked) | partly |
  | `plans/` | plans, batches, approved mockups | yes |
  | `run/` | `merge.lock`, `merge-priority`, `merge-batch-max`, `batch-queue/`, `batch-result/`, pause files, `model-overrides.txt` | overrides only |
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
- If a reviewer is blocked by a permission check, it notes it and does not work around it; CI covers the gap.

## 4. Merge train

- `merge-seq.sh` is a **batched** train. Per item it pushes the branch, creates/updates the PR from `pr/<stem>.txt`
  (so early PR CI starts at once), prints the PR URL and `<wt> queued for the merge batch (head <sha>)`, joins
  `$ORCH_RUN/batch-queue/<stem>` and waits. One runner (`merge-batch.sh runner`, started by a waiting item; it holds
  `$ORCH_RUN/merge.lock`, a dead owner's lock is reclaimed and its queue retried) works the queue in rounds:
  - drops items whose PR head moved (the item prints `PR head moved: requeued at <sha>` and rejoins), evicts items
    whose **early** PR CI failed (`MERGE FAIL CI: <jobs> failed on <url> (early PR CI on <sha>; PR left open)`), and
    waits while early CI is pending (bounded: `ORCH_BATCH_EARLY_MAX`, default 1200 s). `merge-priority` goes first.
  - **One item:** the classic single train — merge main into the lane, optional local gates, push, wait for
    **every check on the exact pushed commit** (`ci-wait.sh`), `gh pr merge --match-head-commit`, delete worktree +
    branch. Same lines as before (`<wt> gates: ...`, URL, `waiting for GitHub CI`, `merged`, main commit line).
  - **Several (cap `$ORCH_RUN/merge-batch-max`, default 8):** a candidate in `${ORCH_WT_PREFIX}batch` = current main
    + each branch as a merge commit ("Merged <branch> (#PR) into the batch."), pushed as `batch/<yyyymmdd-hhmm>`
    with PR "Merge train batch: #a, #b, ..." (body lists each PR). One CI run on the exact candidate commit; green →
    merge (merge commit) and every item PR shows MERGED; items print `GitHub CI passed on batch <url>`, `merged`,
    the main commit line. An item PR not marked MERGED within a minute gets a `note: ... not marked MERGED` line
    (left open; check it). Batch branches are deleted; a dead runner's open batch PRs are closed by the next runner.
  - **Red batch → bisect:** close the candidate, split in halves and run them one after the other, each rebuilt
    from the CURRENT main, down to single trains; the culprit prints `MERGE FAIL CI: ... (isolated in batch)`,
    everything else merges. A failure that needs two branches together (each green alone) reappears in the second
    half (main + first half + second half) and is isolated there; nothing merges unless its base is the current
    main. CI timeouts are not bisected (every item gets `MERGE FAIL CI: ... (batch <url>; PR left open)`: requeue).
  - **Conflicts:** a branch that conflicts with main is evicted with `<wt> TRAIN rc=3` + `CONFLICT` + files; one that
    only conflicts with a batch-mate waits for the next round (then main contains the mate).
  - While `gh` fails, the runner frees `merge.lock` and exits; waiting items start a new runner after
    `$ORCH_RUN/batch-backoff` (`ORCH_BATCH_BACKOFF`, default 120 s).
  - Stopping a waiting merge-seq by PID removes its item from the queue (never stop the runner mid-candidate).
  - A candidate merge that fails without conflict markers (a commit hook, a missing commit) evicts that item with
    `MERGE FAIL: batch merge of <branch> failed` + the git output. The batch worktree `${ORCH_WT_PREFIX}batch` is a
    plain `git worktree add` (no dependency install): if the repo has merge/commit hooks that need dependencies,
    set them up there once.
  - Tests: `tests/batch-test.sh` (bare origin + fake `gh`; green, conflict, mates, bisect, pair, gherr, early, single).
- **Outcomes you must act on** (in `pipes/<branch>.out`):
  - `TRAIN rc=3` + `CONFLICT` + files → resolve (yourself if it is a mechanical "both added" — e.g. registry or list
    entries: keep every side, dedupe, run the formatter and the registry test), commit
    "Merged current main into the <branch> branch.", push, requeue. Otherwise a resolver agent.
  - `MERGE FAIL CI: ...` → fetch failing tests (`gh run view <id> --log-failed`, strip ANSI, grep ` FAIL `).
    Classify: **stale test** (expectation of the old behavior the ruling changed → fixer updates fixture, never weakens
    the rule), **real regression** (builder fixes code), **flake** (log it, requeue once), **pre-existing on main**
    (reproduce in a scratch worktree of origin/main; fix separately). Then requeue.
  - `MERGE FAIL STALE` → requeue. `MERGE FAIL DIRTY` → inspect the worktree, clean, requeue.
  - `MERGE FAIL PUSH` (push rejected at enqueue) → fetch, merge the remote branch, requeue.
  - A push rejection in the log → inspect; usually re-push after fetch/merge.
- **Requeue** = run the same `run-pipe.sh ... merge-seq.sh ...` again (the PR is reused).
- **Manual batch branches** are only needed for branches that conflict with each other in shared registry/list
  files (the train evicts those one at a time): merge them into one branch (`templates/resolver-prompt.md` style,
  "keep every side"), write one combined PR text, queue it. Exclude batched branches from the stalled-branch scan.
- **Merge priority.** A batch that keeps losing the lock to small branches re-conflicts each time; write its stem
  to `$ORCH_RUN/merge-priority` so it takes the lock next, and clear the file once it merges.
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
