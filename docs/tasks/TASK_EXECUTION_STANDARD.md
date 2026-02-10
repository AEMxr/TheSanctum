# Task Execution Standard

## Purpose
Define a deterministic, lane-safe execution and reporting contract for task work so results are reproducible and auditable.

## Mandatory Gates
Every task execution must pass all gates in this order:
1. `git diff --name-only --cached` reviewed for scope-only staging.
2. Scope validator hard gate:
   - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/<TASK-ID>.md -ChangedFiles <cached_files>`
3. Required 4-suite Pester gate:
   - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
   - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
   - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
   - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`

If any gate fails: stop immediately, no commit.

## Scope Discipline
1. Stage only files listed in `## Scope (allowed files)` of the active task card.
2. Do not mix lanes in one task commit.
3. Do not include unrelated generated artifacts in task commits.

## Reporting Standard
Each task completion report must include:
1. Task ID.
2. Commit SHA.
3. Exact changed files list.
4. Scope validator result (`PASS` or `FAIL`).
5. Pester pass/fail counts for all 4 required suites.
6. Drift status (must be none for accepted task completion).
7. Rollback anchor used.
8. Next first command.

## Rollback and Traceability
1. Every task card must declare a rollback anchor.
2. Commit messages must follow lane-correct conventions from the task card.
3. If drift is detected, re-scope before continuing.
