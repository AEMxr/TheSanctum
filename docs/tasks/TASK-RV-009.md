# TASK-RV-009 - Emit deterministic localized dispatch plan output

## Objective lane
revenue

## Goal (single measurable outcome)
On successful `lead_enrich`, emit a deterministic `dispatch_plan` object that is directly usable for ad delivery (channel + localized copy + CTA stubs), with stable lineage and no privacy leakage.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-009.md`

## Non-goals
- No release-gate semantic changes.
- No control-plane schema/version changes.
- No edits outside scoped files.
- No randomness/time-based branching in dispatch output generation.

## Acceptance checklist
- [ ] Successful `lead_enrich` emits `result.dispatch_plan`.
- [ ] `dispatch_plan` includes: `dispatch_id`, `campaign_id`, `channel`, `language_code`, `selected_variant_id`, `ad_copy`, `reply_template`, `cta_buy_stub`, `cta_subscribe_stub`, `reason_codes`.
- [ ] `dispatch_plan` is deterministic across repeated runs for identical input.
- [ ] `dispatch_plan` carries template + variant lineage in `reason_codes`.
- [ ] `dispatch_plan` contains no precise geo fields (no `latitude`/`longitude`).
- [ ] Revenue smoke tests assert shape, lineage, privacy, and repeated-run equality.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary:
  - Revenue route result adds deterministic `dispatch_plan` for successful `lead_enrich`.
  - Top-level revenue index surfaces `dispatch_plan`.
  - Smoke tests validate dispatch shape, lineage, privacy, and determinism.

## Rollback anchor
`rollback/TASK-RV-009-pre`

## Commit message (exact)
`feat(revenue): emit deterministic localized dispatch plan output (TASK-RV-009)`

## Verification gates (STRICT+)
1. `tests/run_staging_v2_3.Tests.ps1`
2. `tests/run_release_candidate.Tests.ps1`
3. `tests/release_gate_helpers.Tests.ps1`
4. `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
5. `apps/api/tests/api.contract.Tests.ps1`

## Closeout format required
- TASK-RV-009 completed.
- Commit SHA
- Commit message
- Exact changed files
- Scope validator result + output
- Gate results (pass/fail counts per suite)
- Drift status (committed vs pre-existing unstaged)
- Rollback anchor used
- Next first command

## Execution notes
- Preserve backward compatibility of existing response fields.
- `dispatch_id` must be deterministic and derived from stable inputs (e.g., task/campaign/variant/channel).
- Keep reason lineage explicit and stable.
- Next first command: `Get-Content docs/tasks/TASK-RV-009.md -Raw`
