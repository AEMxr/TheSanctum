# TASK-CTL-005 - Agent tool risk matrix v1

## Objective lane
Control Plane / Governance

## Goal (single measurable outcome)
Define risk tiers, approval thresholds, and hard stop controls for agentic tool execution.

## Scope (allowed files)
- `docs/governance/AGENT_TOOL_RISK_MATRIX.md`
- `docs/governance/TOOL_EXECUTION_GUARDRAILS.md`
- `docs/roadmap/ROADMAP.md`
- `docs/tasks/TASK-CTL-005.md`

## Non-goals
- No tool router code changes.
- No budget enforcement implementation changes.

## Acceptance checklist
- [ ] Tool tiers are defined by impact class (read-only/transactional/irreversible).
- [ ] Each tier maps to explicit approval requirements.
- [ ] Budget/time/spend caps and auto-stop triggers are documented.
- [ ] Deny/stop conditions and escalation path are explicit.
- [ ] `docs/roadmap/ROADMAP.md` references guardrail dependency.
- [ ] Required validation sequence passes with no drift.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- `rollback/TASK-CTL-005-pre`

## Execution notes
- Validate staged scope first:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-CTL-005.md -ChangedFiles <cached_files>`
- Run required suites:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
- Commit message:
  - `chore(control-plane): define agent tool risk matrix and guardrails (TASK-CTL-005)`

