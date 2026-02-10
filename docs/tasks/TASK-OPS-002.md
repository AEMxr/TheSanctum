# TASK-OPS-002 - Security drill calendar and incident runbook v1

## Objective lane
Ops / Security Resilience

## Goal (single measurable outcome)
Set recurring adversarial drills and measurable recovery readiness.

## Scope (allowed files)
- `docs/security/SECURITY_DRILL_CALENDAR.md`
- `docs/security/INCIDENT_RESPONSE_RUNBOOK.md`
- `docs/roadmap/ROADMAP.md`
- `docs/tasks/TASK-OPS-002.md`

## Non-goals
- No SIEM integration changes.
- No pager or ticketing automation changes.

## Acceptance checklist
- [ ] Monthly drill cadence and scenario matrix are documented.
- [ ] RTO/RPO targets and validation steps are documented.
- [ ] Mandatory remediation loop after each drill is documented.
- [ ] Incident runbook includes containment, recovery, verification, communication.
- [ ] `docs/roadmap/ROADMAP.md` references resilience milestones.
- [ ] Required validation sequence passes with no drift.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- `rollback/TASK-OPS-002-pre`

## Execution notes
- Validate staged scope first:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-OPS-002.md -ChangedFiles <cached_files>`
- Run required suites:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
- Commit message:
  - `chore(ops): establish security drills and incident recovery runbook (TASK-OPS-002)`

