# TASK-RV-005 - Deterministic Proposal Packet + Checkout Stub

## Objective lane
revenue

## Goal (single measurable outcome)
For successful `lead_enrich` runs that produce an `offer`, emit a deterministic `proposal` object (commercial summary + checkout stub) so the same input always yields the same buyer-facing proposal payload.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-005.md`

## Non-goals
- No roadmap/governance/release checklist edits.
- No external payment provider integration.
- No network calls or new dependencies.
- No schema version bumps.
- No edits outside scoped files.
- No release-gate behavior changes.

## Acceptance checklist
- [ ] `task_router.ps1` derives a deterministic `proposal` when:
  - [ ] task type is `lead_enrich`
  - [ ] routing succeeded
  - [ ] `offer` exists
- [ ] `proposal` includes machine-readable fields:
  - [ ] `proposal_id`
  - [ ] `tier`
  - [ ] `headline`
  - [ ] `monthly_price_usd`
  - [ ] `setup_fee_usd`
  - [ ] `due_now_usd`
  - [ ] `checkout_stub`
  - [ ] `reason_codes` (stable strings)
- [ ] Deterministic ID/packet generation:
  - [ ] no randomness
  - [ ] no clock-based branching
  - [ ] same input => byte-equivalent proposal JSON
- [ ] Guardrails enforced:
  - [ ] `due_now_usd = monthly_price_usd + setup_fee_usd`
  - [ ] all monetary fields are non-negative integers
  - [ ] tier must be one of `free`, `starter`, `pro`
  - [ ] invalid offer -> safe fallback proposal or explicit failed path with stable error
- [ ] `index.ps1` includes `proposal` in result JSON without breaking existing fields.
- [ ] Smoke tests cover:
  - [ ] `pro` offer => deterministic proposal with expected totals + reason code
  - [ ] `starter` offer => deterministic proposal with expected totals
  - [ ] `free` offer => deterministic proposal with zero due-now + free checkout stub
  - [ ] repeated runs return identical `proposal` payload
  - [ ] malformed lead payload still fails cleanly and does not emit proposal
- [ ] Scope validator PASS against staged files and this task card.
- [ ] 4-suite gate PASS:
  - [ ] `tests/run_staging_v2_3.Tests.ps1`
  - [ ] `tests/run_release_candidate.Tests.ps1`
  - [ ] `tests/release_gate_helpers.Tests.ps1`
  - [ ] `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- [ ] Exactly one commit.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
`rollback/TASK-RV-005-pre`

## Commit message (exact)
`feat(revenue): add deterministic proposal packets and checkout stubs (TASK-RV-005)`

## Execution notes
- Keep proposal reason codes concise/stable, e.g.:
  - `proposal_from_offer_pro`
  - `proposal_from_offer_starter`
  - `proposal_from_offer_free`
  - `proposal_guardrail_applied`
- `checkout_stub` is deterministic placeholder only (e.g., `stub://checkout/{tier}/{offer_id}`), not a live payment link.
- Preserve backward compatibility for existing result fields:
  - `status`, `provider_used`, `artifacts`, `route`, `offer`, `reason_codes`
- Next first command: `Get-Content docs/tasks/TASK-RV-005.md -Raw`
