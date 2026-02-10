# TASK-CTL-004 - Lineage/product isolation policy v1

## Objective lane
Control Plane / Security Governance

## Goal (single measurable outcome)
Define hard trust boundaries between lineage systems and product tenant systems.

## Scope (allowed files)
- `docs/security/LINEAGE_PRODUCT_ISOLATION_POLICY.md`
- `docs/security/KEY_DOMAIN_SEPARATION.md`
- `docs/roadmap/ROADMAP.md`
- `docs/tasks/TASK-CTL-004.md`

## Non-goals
- No KMS/HSM provisioning changes.
- No identity provider implementation changes.

## Acceptance checklist
- [ ] Non-crossable data classes are explicitly defined.
- [ ] Separate signing authorities are explicitly defined.
- [ ] Failure-domain isolation requirements are defined.
- [ ] Prohibited joins and trust-boundary violations are explicit.
- [ ] `docs/roadmap/ROADMAP.md` references isolation requirement.
- [ ] Required validation sequence passes with no drift.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- `rollback/TASK-CTL-004-pre`

## Execution notes
- Validate staged scope first:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-CTL-004.md -ChangedFiles <cached_files>`
- Run required suites:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
- Commit message:
  - `chore(control-plane): enforce lineage and product trust boundaries (TASK-CTL-004)`

