# orchestrate scripts

All scripts source `orch-env.sh` (variables documented there; per-repo overrides in `$ORCH_STATE/env.sh`).
Run them from anywhere inside the repo, or set `ORCH_REPO`.

| Script | Purpose |
|---|---|
| `run-pipe.sh <name> <cmd...>` | Start a pipeline detached; output → `$ORCH_STATE/pipe-<name>.out`. |
| `merge-seq.sh <wt>:<branch>:<stem> ...` | The merge train (lock → train → PR → exact-commit CI → merge). |
| `train.sh <wt> <tag>` | Merge the default branch into the lane; optional `ORCH_LOCAL_GATES`. Exit 3 = conflict. |
| `merge-pr.sh <wt> <branch> <stem> "<gates>"` | Push, create/update PR from `pr/<stem>.txt`, wait for CI, merge, clean up. |
| `wait-merged.sh <parent> [file] -- <cmd...>` | Run a command once the parent branch's PR is MERGED (stacked branches). |
| `merge-queue-len.sh [--real]` | Count live merge-seq processes. |
| `launch.sh <lane> <dir> <effort> "<prompt>"` | Start an external herdr lane (MODEL, KIND); prints STARTED / WAITING / LAUNCH FAIL. |
| `lane-busy.sh <lane>` | Exit 0 while an external lane is working. |
| `watch-all.sh` | Supplementary event watcher (run in background; restart after each exit). |
| `cleanup-merged.sh <wt> <stem>` | Post-merge cleanup of idle workspaces and merged scratch worktrees. |

Typical queue command:
`S=~/.claude/skills/orchestrate/scripts; $S/run-pipe.sh area-t3 $S/merge-seq.sh areat3:area-t3:areat3`
