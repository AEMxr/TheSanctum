# TASK-RV-004 - Deterministic Offer Packaging + Quote Output

## Objective lane
revenue

## Goal (single measurable outcome)
For successful `lead_enrich` runs, emit a deterministic `offer` object (tier + pricing + reason codes) derived from routing/scoring so the same input always yields the same commercial output.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-004.md`

## Non-goals
- No roadmap/governance/release checklist edits.
- No new dependencies or external API calls.
- No schema version bumps.
- No edits outside scoped files.
- No changes to release-gate semantics.

## Acceptance checklist
- [ ] `task_router.ps1` derives a deterministic `offer` for `lead_enrich` success paths.
- [ ] `offer` includes machine-readable fields:
  - [ ] `offer_id`
  - [ ] `tier`
  - [ ] `monthly_price_usd`
  - [ ] `setup_fee_usd`
  - [ ] `sla_hours`
  - [ ] `reason_codes` (stable strings)
- [ ] Route/score -> offer mapping is deterministic and documented in code comments.
- [ ] Guardrails enforced in code:
  - [ ] allowed tiers only (`free`, `starter`, `pro`)
  - [ ] non-negative pricing
  - [ ] ceiling check (hard cap) with fail-closed or safe fallback
- [ ] `index.ps1` includes `offer` in result JSON without breaking existing fields.
- [ ] Smoke tests cover:
  - [ ] high-priority route returns `pro` offer and expected reason code(s)
  - [ ] medium-priority route returns `starter` offer
  - [ ] low-priority route returns `free` offer
  - [ ] determinism across repeated runs (same offer payload)
  - [ ] malformed lead payload still fails cleanly (existing negative path preserved)
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
`rollback/TASK-RV-004-pre`

## Commit message (exact)
`feat(revenue): add deterministic offer packaging and quote output (TASK-RV-004)`

## Execution notes
- Determinism requirement: no randomness/time-based branching in offer selection.
- Keep reason codes concise + stable (e.g., `offer_pro_priority`, `offer_starter_nurture`, `offer_free_low_signal`, `price_guardrail_applied`).
- Preserve backward compatibility for existing result fields (`status`, `provider_used`, `artifacts`, `route`, `reason_codes`).
- Next first command: `Get-Content docs/tasks/TASK-RV-004.md -Raw`
