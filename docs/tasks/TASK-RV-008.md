# TASK-RV-008 - Deterministic dual-CTA campaign packet emission

## Objective lane
revenue

## Goal (single measurable outcome)
On successful `lead_enrich`, emit a deterministic `campaign_packet` object with buy and subscribe CTA stubs so the same input always yields the same campaign-ready payload.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-008.md`

## Non-goals
- No changes to release-gate semantics.
- No control-plane schema/version changes outside scoped response shaping.
- No edits outside scoped files.

## Acceptance checklist
- [ ] Successful `lead_enrich` emits `campaign_packet` with deterministic values.
- [ ] `campaign_packet` includes machine-readable fields: `campaign_id`, `tier`, `channels`, `copy_variants`, `cta_buy_stub`, `cta_subscribe_stub`, `reason_codes`.
- [ ] Dual-CTA routing behavior is deterministic and stable across repeated runs.
- [ ] Revenue smoke tests include explicit assertions for campaign packet shape, deterministic dual CTA stubs, and repeated-run equality.
- [ ] Exactly one implementation commit using the exact message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
`rollback/TASK-RV-008-pre`

## Commit message (exact)
`feat(revenue): emit deterministic dual-cta campaign packet output (TASK-RV-008)`

## Verification gates (STRICT+)
1. `tests/run_staging_v2_3.Tests.ps1`
2. `tests/run_release_candidate.Tests.ps1`
3. `tests/release_gate_helpers.Tests.ps1`
4. `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
5. `apps/api/tests/api.contract.Tests.ps1`

## Closeout format required
- TASK-RV-008 completed.
- Commit SHA
- Commit message
- Exact changed files
- Scope validator result + output
- Gate results (pass/fail counts per suite)
- Drift status (committed vs pre-existing unstaged)
- Rollback anchor used
- Next first command

## Execution notes
- Determinism required: no randomness/time-based branching for campaign packet outputs.
- Preserve backward compatibility of existing response fields unless explicitly stated.
- Keep reason lineage stable and explicit.
- Next first command: `Get-Content docs/tasks/TASK-RV-008.md -Raw`
