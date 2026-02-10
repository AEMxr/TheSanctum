# TASK-CP-005 — Task Scope Reference Integrity Check

## Objective lane
Control Plane

## Goal (single measurable outcome)
Ensure task-card `Scope (allowed files)` entries reference valid paths/patterns to prevent dead scope rules.

## Scope (allowed files)
- `scripts/dev/validate_task_scope.ps1`
- `docs/tasks/TASK-CP-005.md`
- `docs/tasks/TASK_TEMPLATE.md`

## Non-goals
- No release-gate behavior changes.
- No CI matrix changes.
- No revenue scaffold changes.

## Acceptance checklist
- [ ] Validator verifies referenced literal paths exist (when not wildcard).
- [ ] Validator returns clear failures for invalid scope entries.
- [ ] Task template includes guidance for wildcard vs literal entries.
- [ ] Existing suites remain green.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- Tag: `control-plane-scope-guard-v1`

## Execution notes
- Validate:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
