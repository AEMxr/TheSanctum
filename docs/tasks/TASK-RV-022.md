# TASK-RV-022 - Emit deterministic proof verification output

## Objective lane
revenue

## Goal (single measurable outcome)
On successful `lead_enrich`, emit a deterministic `proof_verification` object derived from `ledger_attestation`.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-022.md`

## Non-goals
- No release-gate semantic changes.
- No schema/version changes outside scoped response shaping.
- No edits outside scoped files.

## Acceptance checklist
- [ ] Successful `lead_enrich` emits `result.proof_verification`.
- [ ] Output includes deterministic lineage IDs and ordered `accepted_action_types` (`cta_buy`, `cta_subscribe`).
- [ ] Output reason codes include `proof_verification_emitted` plus lineage reasons.
- [ ] FAILED/malformed path does not emit `proof_verification`.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary: route/index/test updates for deterministic proof verification.

## Rollback anchor
`rollback/TASK-RV-022-pre`

## Commit message (exact)
`feat(revenue): emit deterministic proof verification output (TASK-RV-022)`

## Verification gates (STRICT+)
1. `tests/run_staging_v2_3.Tests.ps1`
2. `tests/run_release_candidate.Tests.ps1`
3. `tests/release_gate_helpers.Tests.ps1`
4. `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
5. `apps/api/tests/api.contract.Tests.ps1`

## Execution notes
- Preserve backward compatibility of existing fields.
- Determinism only; no randomness or timestamp-derived IDs.
- Next first command: `Get-Content docs/tasks/TASK-RV-023.md -Raw`
