# A workflow skill for the orchestrating argent

This is a Claude Code skill for running many parallel coding lanes in a git + GitHub repository: one worktree per branch, builder → reviewer → PR text → a merge train that merges only after CI passes on the exact pushed commit, with an independent 15-minute supervision check, decision logging, batching of refactor lanes, and an unattended ("overnight") mode. Project-specific rules live in a per-project config, not in the skill.

## Install

```sh
git clone git@github.com:baochunli/orchestrate.git ~/.claude/skills/orchestrate
mkdir -p ~/.claude/agents
for a in orch-builder orch-reviewer orch-resolver; do
  ln -sf ~/.claude/skills/orchestrate/agents/$a.md ~/.claude/agents/$a.md
done
# per project:
cp ~/.claude/skills/orchestrate/templates/project-config.example.md <project>/.claude/orchestrate.md
# then fill it in (tests, gates, forbidden actions, deploy, copy/docs rules, models)
```

Requirements: `git`, `gh` (authenticated), `bash`, `python3`. External lanes (`launch.sh`) need the `herdr` CLI.

## Use

In a session in the project, say "orchestrate" (or ask to run lanes in parallel with a merge train). The skill reads
the project config, sets up `~/.local/share/orchestrate/<repo>/` as its state directory, and creates the 15-minute
check (session-only cron job). See `SKILL.md`.

## Files

```
SKILL.md                      procedure the supervisor follows (lane flow, routing, review policy, merge train,
                              questions, overnight mode, the 15-minute check prompt, lessons)
agents/                       subagent definitions (symlink into ~/.claude/agents/)
  orch-builder.md  orch-reviewer.md  orch-resolver.md
scripts/                      merge train and lane tooling (see below)
  orch-env.sh  run-pipe.sh  merge-seq.sh  train.sh  merge-pr.sh  wait-merged.sh
  merge-queue-len.sh  launch.sh  pipeline.sh  review-chain.sh  wait-lanes.sh  lane-busy.sh
  watch-all.sh  cleanup-merged.sh
templates/                    briefs and prompts to copy and fill
  brief-common.md  brief-port.md  review-prompt.md  delta-review-prompt.md
  resolver-prompt.md  stale-test-fixer-prompt.md  pr-text-prompt.md  project-config.example.md
```

# Scripts for the orchestrating agent

All scripts source `orch-env.sh` (variables documented there; per-repo overrides in `$ORCH_STATE/env.sh`).
Run them from anywhere inside the repo, or set `ORCH_REPO`.

| Script | Purpose |
|---|---|
| `run-pipe.sh <name> <cmd...>` | Start a pipeline detached; output → `$ORCH_PIPES/<name>.out`. |
| `merge-seq.sh <wt>:<branch>:<stem> ...` | The merge train (lock → train → PR → exact-commit CI → merge). |
| `train.sh <wt> <tag>` | Merge the default branch into the lane; optional `ORCH_LOCAL_GATES`. Exit 3 = conflict. |
| `merge-pr.sh <wt> <branch> <stem> "<gates>"` | Push, create/update PR from `pr/<stem>.txt`, wait for CI, merge, clean up. |
| `wait-merged.sh <parent> [file] -- <cmd...>` | Run a command once the parent branch's PR is MERGED (stacked branches). |
| `merge-queue-len.sh [--real]` | Count live merge-seq processes. |
| `launch.sh <lane> <dir> <effort> "<prompt>"` | Start an external herdr lane (MODEL, KIND); prints STARTED / WAITING / LAUNCH FAIL. |
| `pipeline.sh <branch> [deps\|-] [full\|quick]` | Chain a whole lane: wait for dependency PRs, worktree, build lane, report check, then `review-chain.sh`. |
| `review-chain.sh <stem> <branch> [full\|quick]` | Review lane, then on PASS the PR-text lane, then `merge-seq.sh`. Prompts from `templates/`. Prints `CHAIN FAIL <stem>: <verdict head>` on FAIL; `CHAIN_NO_MERGE=1` stops after the PR text. |
| `wait-lanes.sh <lane>...` | Block until any herdr lane really finishes (or ~29 min); re-prompts lanes stopped by a model-capacity error. |
| `lane-busy.sh <lane>` | Exit 0 while an external lane is working. |
| `watch-all.sh` | Supplementary event watcher (run in background; restart after each exit). |
| `cleanup-merged.sh <wt> <stem>` | Post-merge cleanup of idle workspaces and merged scratch worktrees. |

`launch.sh` is single-stage: it starts ONE external lane and stops. `pipeline.sh` chains build, review, PR text and
merge (`review-chain.sh` is its second half; run it alone for a branch that is already built). Both need the herdr CLI.
Models: `BUILD_MODEL`/`BUILD_EFFORT`, `REVIEW_MODEL`/`REVIEW_EFFORT`, `PRTEXT_MODEL`/`PRTEXT_EFFORT`, each falling back
to `ORCH_MODEL`/`ORCH_EFFORT` (set them in `$ORCH_STATE/env.sh`). Project rules (test budget, gates) go in the brief and
in `BUILD_EXTRA`/`REVIEW_EXTRA`/`PRTEXT_EXTRA`, or in filled copies of the templates via `REVIEW_PROMPT_FILE`/
`PRTEXT_PROMPT_FILE`. Template tokens: `{{STEM}} {{BRANCH}} {{SHA}} {{WORKTREE}} {{REPO}} {{BRIEF}} {{REPORT}}
{{VERDICT}} {{VERDICTS}} {{PRFILE}}`.

Full chain: `$S/run-pipe.sh area-t3 $S/pipeline.sh area-t3 'dep-branch-a|dep-branch-b' quick`

Typical queue command:
`S=~/.claude/skills/orchestrate/scripts; $S/run-pipe.sh area-t3 $S/merge-seq.sh areat3:area-t3:areat3`
