# TASK-CP-003 — Task Card Completeness Lint

## Objective lane
Control Plane

## Goal (single measurable outcome)
Fail validation when a task card is missing required governance sections so incomplete tasks cannot proceed.

## Scope (allowed files)
- `scripts/dev/validate_task_scope.ps1`
- `docs/tasks/TASK-CP-003.md`
- `docs/tasks/TASK_TEMPLATE.md`
- `docs/checklists/pre_commit_drift_alarm.md`

## Non-goals
- No release-gate runtime semantics changes.
- No schema/version changes.
- No CI matrix changes.
- No revenue scaffold behavior changes.

## Acceptance checklist
- [ ] Validator enforces required task-card headings:
  - `## Objective lane`
  - `## Goal (single measurable outcome)`
  - `## Scope (allowed files)`
  - `## Non-goals`
  - `## Acceptance checklist`
  - `## Deliverables (SHA, diff summary)`
  - `## Rollback anchor`
  - `## Execution notes`
- [ ] Validation fails non-zero with clear missing-section output.
- [ ] Validation is applied only when a changed task card matches `docs/tasks/TASK-*.md`.
- [ ] Existing suites remain green with no expectation drift.
- [ ] Checklist doc reflects task-card completeness requirement.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- Tag: `control-plane-scope-guard-v1`

## Execution notes
- Validate staged scope first:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-CP-003.md -ChangedFiles <cached_files>`
- Run required suites:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
- Next first command:
  - `git diff --name-only --cached`
