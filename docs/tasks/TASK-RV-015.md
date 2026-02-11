# TASK-RV-015 - Emit deterministic dispatch receipt output

## Objective lane
revenue

## Goal (single measurable outcome)
On successful `lead_enrich`, emit a deterministic `dispatch_receipt` object derived from `adapter_request` that is directly consumable by downstream retry/telemetry/audit workflows.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-015.md`

## Non-goals
- No release-gate semantic changes.
- No control-plane schema/version bumps outside scoped response shaping.
- No edits outside scoped files.
- No randomness/time-based branching.

## Acceptance checklist
- [ ] Successful `lead_enrich` emits `result.dispatch_receipt`.
- [ ] `dispatch_receipt` includes:
  - `receipt_id`
  - `request_id`
  - `idempotency_key`
  - `envelope_id`
  - `delivery_id`
  - `dispatch_id`
  - `campaign_id`
  - `channel`
  - `language_code`
  - `selected_variant_id`
  - `provider_mode`
  - `dry_run`
  - `status`
  - `accepted_actions`
  - `reason_codes`
- [ ] `accepted_actions` is deterministic and ordered exactly:
  1) `cta_buy`
  2) `cta_subscribe`
- [ ] Action mapping is deterministic from `adapter_request.scheduled_actions`:
  - `action_type`
  - `action_stub`
  - `ad_copy`
  - `reply_template`
- [ ] `status` is deterministic from stable request context:
  - when `dry_run = true`, status is `simulated`
- [ ] `dispatch_receipt.reason_codes` includes:
  - `dispatch_receipt_emitted`
  - `dispatch_receipt_dry_run` (when `dry_run=true`)
  - template lineage (e.g., `template_lang_native` or `template_lang_fallback_en`)
  - variant lineage (e.g., `variant_lang_perf_win`, `variant_lang_tiebreak`, or deterministic fallback code)
- [ ] `dispatch_receipt` is deterministic across repeated runs for identical input.
- [ ] `dispatch_receipt` contains no precise geo or direct-contact fields (`latitude`, `longitude`, `email`, `phone`, `ip_address` absent).
- [ ] FAILED/malformed `lead_enrich` path does **not** emit `dispatch_receipt`.
- [ ] Revenue smoke tests include explicit shape, ordering, lineage, privacy, dry-run status, and repeated-run equality assertions.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary:
  - Revenue route result adds deterministic `dispatch_receipt` for successful `lead_enrich`.
  - Top-level revenue index surfaces `dispatch_receipt`.
  - Smoke tests validate receipt shape, ordering, lineage, privacy, dry-run determinism, and repeated-run stability.

## Rollback anchor
`rollback/TASK-RV-015-pre`

## Commit message (exact)
`feat(revenue): emit deterministic dispatch receipt output (TASK-RV-015)`

## Verification gates (STRICT+)
1. `tests/run_staging_v2_3.Tests.ps1`
2. `tests/run_release_candidate.Tests.ps1`
3. `tests/release_gate_helpers.Tests.ps1`
4. `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
5. `apps/api/tests/api.contract.Tests.ps1`

## Closeout format required
- TASK-RV-015 completed.
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
- Keep accepted action ordering stable (`cta_buy`, then `cta_subscribe`) with explicit lineage.
- `receipt_id` must be deterministic from stable lineage inputs (task/campaign/channel/variant/request), with no timestamp/randomness.
- Next first command: `Get-Content docs/tasks/TASK-RV-015.md -Raw`
