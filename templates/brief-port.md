# Behavior-preserving refactor lane (one row per lane)

Your launch prompt names ONE row (e.g. "row R7: <module/field>"). The inventory with details is `<inventory file>`;
line numbers there may be stale — re-grep on current code.

## Before you start
- Read `$ORCH_BRIEFS/common.md` and the project config.
- Read the target pattern/kit (`<path>`) and the closest already-merged example (`<path>`).
- Time box: ~2.5 h. Keep the branch small.

## Do
1. Encode EXACTLY today's behavior in the new structure (table, helper, interface...). Anything that looks wrong:
   tag it `unintended`, leave it unfixed, and list it in the report as an owner question with options and a
   recommendation.
2. Route every writer/caller through it. NO behavior change: predicates, locks, fences, lock order, transaction
   boundaries, row-count handling, user-visible texts and response shapes stay equivalent. Fold duplicate copies
   only where they are byte-identical.
3. Register new writers/entries wherever the project's registry test requires (`<registry test>`).
4. Tests: exhaustive pure tests (layer 1) plus integration through the real functions (layer 2). Existing tests must
   pass unchanged — if one must change, behavior changed: stop and report.
5. Internal engineering docs only (`<path>`); no user-facing docs change.

## Rules
- NO behavior change, NO migration (list needed migrations as follow-ups).
- Merge the default branch right before the final gates. Push; no PR.
- Report: the new structure, unintended items + owner questions, old→new site mapping, red→green results.
