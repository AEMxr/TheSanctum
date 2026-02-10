# TASK-CTL-002 - Crisis / expedite protocol v1 (bounded emergency path)

## Objective lane
Control Plane / Governance

## Goal (single measurable outcome)
Formalize crisis mode triggers, allowed actions, duration bounds, and mandatory post-hoc review.

## Scope (allowed files)
- `docs/governance/CRISIS_EXPEDITE_PROTOCOL.md`
- `docs/governance/GOVERNANCE_CHANGE_CONTROL.md`
- `docs/roadmap/ROADMAP.md`
- `docs/tasks/TASK-CTL-002.md`

## Non-goals
- No live incident automation scripts.
- No pager/alert integrations.

## Acceptance checklist
- [ ] Trigger conditions and activation authority are explicitly defined.
- [ ] Maximum duration, auto-expiry, and rollback path are documented.
- [ ] Post-hoc review deadlines and evidence requirements are defined.
- [ ] No-silent-bypass language is explicit.
- [ ] `docs/roadmap/ROADMAP.md` includes crisis protocol dependency.
- [ ] Required validation sequence passes with no drift.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- `rollback/TASK-CTL-002-pre`

## Execution notes
- Validate staged scope first:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-CTL-002.md -ChangedFiles <cached_files>`
- Run required suites:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
- Commit message:
  - `chore(control-plane): codify crisis expedite protocol v1 (TASK-CTL-002)`

