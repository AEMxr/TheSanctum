# TASK-CTL-001 - Council arbitration specification v1 (deterministic conflict resolution)

## Objective lane
Control Plane / Governance

## Goal (single measurable outcome)
Define deterministic council conflict resolution, tie-break rules, escalation, and Primarch override semantics.

## Scope (allowed files)
- `docs/governance/COUNCIL_ARBITRATION_SPEC.md`
- `docs/roadmap/ROADMAP.md`
- `docs/tasks/TASK-CTL-001.md`

## Non-goals
- No runtime orchestration code changes.
- No tool router logic changes.
- No policy engine implementation details.

## Acceptance checklist
- [ ] Spec includes weighted scoring rubric for council outputs.
- [ ] Spec includes deterministic tie-break rules and deadlock timeout/escalation chain.
- [ ] Spec defines advisory-only role behavior vs final authority.
- [ ] Spec defines explicit deny and invalid states.
- [ ] `docs/roadmap/ROADMAP.md` references the arbitration spec in governance section.
- [ ] Required validation sequence passes with no drift.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- `rollback/TASK-CTL-001-pre`

## Execution notes
- Validate staged scope first:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-CTL-001.md -ChangedFiles <cached_files>`
- Run required suites:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
- Commit message:
  - `chore(control-plane): define deterministic council arbitration v1 (TASK-CTL-001)`
