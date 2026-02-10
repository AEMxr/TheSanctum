# TASK-CP-006 — Checklist Hygiene and Drift-Alarm Lint

## Objective lane
Control Plane

## Goal (single measurable outcome)
Eliminate duplicate checklist items and enforce checklist hygiene with a lightweight lint check in CI/local validation.

## Scope (allowed files)
- `docs/checklists/pre_commit_drift_alarm.md`
- `scripts/dev/validate_task_scope.ps1`
- `docs/tasks/TASK-CP-006.md`

## Non-goals
- No release-gate runtime semantics changes.
- No schema/version changes.
- No changes to Pester decision criteria.

## Acceptance checklist
- [ ] Duplicate checklist line(s) removed.
- [ ] Validator can detect duplicate checklist entries.
- [ ] Validator exits non-zero on duplicates.
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
