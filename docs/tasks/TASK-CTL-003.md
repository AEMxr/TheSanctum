# TASK-CTL-003 - Memory governance and drift control v1

## Objective lane
Control Plane / Governance

## Goal (single measurable outcome)
Define memory anti-corruption controls and promotion rules to protect training integrity.

## Scope (allowed files)
- `docs/data/MEMORY_GOVERNANCE_AND_DRIFT_CONTROL.md`
- `docs/data/TRAINING_LINEAGE_STANDARD.md`
- `docs/roadmap/ROADMAP.md`
- `docs/tasks/TASK-CTL-003.md`

## Non-goals
- No vector database implementation changes.
- No training pipeline code changes.

## Acceptance checklist
- [ ] Hot/warm/cold promotion criteria are defined.
- [ ] Contradiction detection and quarantine states are defined.
- [ ] Truth-layer memory and style-layer personalization separation is explicit.
- [ ] Training candidates require lineage metadata.
- [ ] `docs/roadmap/ROADMAP.md` references memory governance gate.
- [ ] Required validation sequence passes with no drift.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- `rollback/TASK-CTL-003-pre`

## Execution notes
- Validate staged scope first:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-CTL-003.md -ChangedFiles <cached_files>`
- Run required suites:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
- Commit message:
  - `chore(control-plane): add memory drift governance and lineage rules (TASK-CTL-003)`

