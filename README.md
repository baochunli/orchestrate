# orchestrate

A Claude Code skill for running many parallel coding lanes in a git + GitHub repository: one worktree per branch,
builder → reviewer → PR text → a merge train that merges only after CI passes on the exact pushed commit, with an
independent 15-minute supervision check, decision logging, batching of refactor lanes, and an unattended
("overnight") mode. Project-specific rules live in a per-project config, not in the skill.

## Install

```sh
git clone <your-remote>/orchestrate.git ~/.claude/skills/orchestrate
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
scripts/                      merge train and lane tooling (see scripts/README.md)
  orch-env.sh  run-pipe.sh  merge-seq.sh  train.sh  merge-pr.sh  wait-merged.sh
  merge-queue-len.sh  launch.sh  lane-busy.sh  watch-all.sh  cleanup-merged.sh
templates/                    briefs and prompts to copy and fill
  brief-common.md  brief-port.md  review-prompt.md  delta-review-prompt.md
  resolver-prompt.md  stale-test-fixer-prompt.md  pr-text-prompt.md  project-config.example.md
```
