# TASK-CP-002 — Enforce Scope Validator in CI Pre-Test Gate

## Objective lane
Control Plane

## Goal (single measurable outcome)
Require task-scope validation to pass in CI before test execution so out-of-scope file changes are blocked automatically.

## Scope (allowed files)
- `.github/workflows/release-gate-v2_3.yml`
- `scripts/dev/validate_task_scope.ps1`
- `docs/tasks/TASK-CP-002.md`
- `docs/checklists/pre_commit_drift_alarm.md`

## Non-goals
- No changes to release-gate runtime semantics.
- No schema version changes.
- No changes to existing test expectations or decision criteria.
- No changes to production automation behavior outside CI pre-test guard wiring.

## Acceptance checklist
- [ ] CI workflow runs `scripts/dev/validate_task_scope.ps1` before tests.
- [ ] Scope validation step is required (non-optional) and fails on out-of-scope paths.
- [ ] Task file is configurable (input/env) with a deterministic default.
- [ ] Existing Pester suites still pass with no expectation changes.
- [ ] Docs/checklist updated to reflect CI-enforced scope guard.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:
  - Added required CI pre-test scope validation step(s).
  - Updated any supporting scope-validator script/docs as needed.

## Rollback anchor
- Tag: `release-gate-postfreeze-clean-v2.4.0`

## Execution notes
- Validate locally before push:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-CP-002.md -ChangedFiles <paths>`
- Next first command:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
