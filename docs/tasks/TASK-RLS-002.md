# TASK-RLS-002 - Task/reporting standard normalization for Codex execution

## Objective lane
Release / Ops Interface

## Goal (single measurable outcome)
Normalize reporting requirements and eliminate ambiguity (4 Pester suites + scope validator).

## Scope (allowed files)
- `docs/tasks/TASK_EXECUTION_STANDARD.md`
- `docs/release_promotion_checklist.md`
- `docs/roadmap/ROADMAP.md`
- `docs/tasks/TASK-RLS-002.md`

## Non-goals
- No test content changes.
- No CI workflow changes.

## Acceptance checklist
- [ ] Execution standard explicitly requires scope validator as a mandatory separate gate.
- [ ] Execution standard explicitly defines the 4 required Pester suites.
- [ ] Release checklist includes drift reporting and rollback-anchor reporting requirements.
- [ ] `docs/roadmap/ROADMAP.md` references normalized execution standard.
- [ ] Required validation sequence passes with no drift.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- `rollback/TASK-RLS-002-pre`

## Execution notes
- Validate staged scope first:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-RLS-002.md -ChangedFiles <cached_files>`
- Run required suites:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
- Commit message:
  - `chore(release): normalize task execution and reporting standard (TASK-RLS-002)`

