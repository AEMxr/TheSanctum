# TASK-RLS-001 - Policy mutation lifecycle controls v1 (release-gated)

## Objective lane
Release / Gating

## Goal (single measurable outcome)
Eliminate silent policy mutation through signed lifecycle requirements and release-gate references.

## Scope (allowed files)
- `docs/governance/POLICY_LIFECYCLE_AND_MUTATION_CONTROLS.md`
- `docs/governance/GOVERNANCE_CHANGE_CONTROL.md`
- `docs/release_promotion_checklist.md`
- `docs/roadmap/ROADMAP.md`
- `docs/tasks/TASK-RLS-001.md`

## Non-goals
- No CI workflow YAML edits.
- No runtime verifier code changes.

## Acceptance checklist
- [ ] Lifecycle phases are defined: proposal -> review -> quorum sign -> staged rollout -> audit publication.
- [ ] Unsigned policy deltas are explicitly invalidated.
- [ ] Deny conditions and blocked-promotion conditions are explicit.
- [ ] Release checklist references lifecycle verification checkpoint.
- [ ] `docs/roadmap/ROADMAP.md` references this as hard gate.
- [ ] Required validation sequence passes with no drift.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- `rollback/TASK-RLS-001-pre`

## Execution notes
- Validate staged scope first:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-RLS-001.md -ChangedFiles <cached_files>`
- Run required suites:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
- Commit message:
  - `chore(release): define policy mutation lifecycle hard gates (TASK-RLS-001)`

