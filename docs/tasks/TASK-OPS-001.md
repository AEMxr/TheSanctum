# TASK-OPS-001 - Runtime budgets for GTX 1660 and fallback policy v1

## Objective lane
Ops / Runtime

## Goal (single measurable outcome)
Set enforceable runtime budgets and fallback behavior under local hardware constraints.

## Scope (allowed files)
- `docs/runtime/RUNTIME_BUDGETS_GTX1660.md`
- `docs/runtime/INFERENCE_FALLBACK_POLICY.md`
- `docs/roadmap/ROADMAP.md`
- `docs/tasks/TASK-OPS-001.md`

## Non-goals
- No inference server code changes.
- No model quantization script changes.

## Acceptance checklist
- [ ] Runtime budget table includes target and limit thresholds for VRAM, latency, context, throughput.
- [ ] Saturation behavior and graceful degradation rules are documented.
- [ ] Local-first and approved cloud fallback conditions are documented.
- [ ] Fallback trigger and reversion rules are explicit.
- [ ] `docs/roadmap/ROADMAP.md` includes runtime budget dependency.
- [ ] Required validation sequence passes with no drift.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- `rollback/TASK-OPS-001-pre`

## Execution notes
- Validate staged scope first:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-OPS-001.md -ChangedFiles <cached_files>`
- Run required suites:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
- Commit message:
  - `chore(ops): lock runtime budgets and fallback policy for gtx1660 (TASK-OPS-001)`

