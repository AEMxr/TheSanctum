# TASK-RV-026 - Emit deterministic notarization ticket output

## Objective lane
revenue

## Goal (single measurable outcome)
On successful `lead_enrich`, emit a deterministic `notarization_ticket` object derived from `archive_manifest`.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-026.md`

## Non-goals
- No release-gate semantic changes.
- No schema/version changes outside scoped response shaping.
- No edits outside scoped files.

## Acceptance checklist
- [ ] Successful `lead_enrich` emits `result.notarization_ticket`.
- [ ] Output includes deterministic lineage IDs and ordered `accepted_action_types` (`cta_buy`, `cta_subscribe`).
- [ ] Output reason codes include `notarization_ticket_emitted` plus lineage reasons.
- [ ] FAILED/malformed path does not emit `notarization_ticket`.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary: route/index/test updates for deterministic notarization ticket.

## Rollback anchor
`rollback/TASK-RV-026-pre`

## Commit message (exact)
`feat(revenue): emit deterministic notarization ticket output (TASK-RV-026)`

## Verification gates (STRICT+)
1. `tests/run_staging_v2_3.Tests.ps1`
2. `tests/run_release_candidate.Tests.ps1`
3. `tests/release_gate_helpers.Tests.ps1`
4. `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
5. `apps/api/tests/api.contract.Tests.ps1`

## Execution notes
- Preserve backward compatibility of existing fields.
- Determinism only; no randomness or timestamp-derived IDs.
- Next first command: `Get-Content docs/tasks/TASK-AP-001.md -Raw`
