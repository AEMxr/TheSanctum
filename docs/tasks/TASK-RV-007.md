# TASK-RV-007 - Emit schema-safe marketing telemetry event

## Objective lane
revenue

## Goal (single measurable outcome)
On successful `lead_enrich`, emit a deterministic, schema-safe telemetry event object (not just a stub) in the revenue result payload, with coarse-only geo and stable reason lineage.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-007.md`

## Non-goals
- No changes to release-gate semantics.
- No changes to control-plane schemas/contracts outside revenue response shaping.
- No edits outside scoped files.

## Acceptance checklist
- [ ] `lead_enrich` success includes `result.telemetry_event` (or equivalent final field name) with deterministic values.
- [ ] Telemetry object includes only coarse-safe location fields (`geo_coarse`, `region_code`) and excludes precise coordinates.
- [ ] Telemetry object preserves language + channel + campaign lineage from payload when present.
- [ ] Variant lineage is carried into telemetry (`selected_variant_id` when available).
- [ ] Reason lineage remains deterministic and includes template/variant rationale where applicable.
- [ ] Revenue smoke tests include explicit assertions for telemetry event shape + privacy constraints.
- [ ] Exactly one task commit for implementation using the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
`rollback/TASK-RV-007-pre`

## Commit message (exact)
`feat(revenue): emit deterministic schema-safe marketing telemetry event (TASK-RV-007)`

## Verification gates (STRICT+)
1. `tests/run_staging_v2_3.Tests.ps1`
2. `tests/run_release_candidate.Tests.ps1`
3. `tests/release_gate_helpers.Tests.ps1`
4. `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
5. `apps/api/tests/api.contract.Tests.ps1`

## Closeout format required
- TASK-RV-007 completed.
- Commit SHA
- Commit message
- Exact changed files
- Scope validator result + output
- Gate results (pass/fail counts per suite)
- Drift status (committed vs pre-existing unstaged)
- Rollback anchor used
- Next first command

## Execution notes
- Determinism requirement: no randomness/time-based branching in telemetry event generation.
- Preserve existing result fields and add telemetry event without breaking backward compatibility.
- Include template/variant reason lineage in telemetry reason codes when available.
- Next first command: `Get-Content docs/tasks/TASK-RV-007.md -Raw`
