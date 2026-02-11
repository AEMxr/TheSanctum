# TASK-RV-014 - Emit deterministic adapter request output

## Objective lane
revenue

## Goal (single measurable outcome)
On successful `lead_enrich`, emit a deterministic `adapter_request` object derived from `sender_envelope` that is directly consumable by downstream provider adapters/executors.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-014.md`

## Non-goals
- No release-gate semantic changes.
- No control-plane schema/version bumps outside scoped response shaping.
- No edits outside scoped files.
- No randomness/time-based branching.

## Acceptance checklist
- [ ] Successful `lead_enrich` emits `result.adapter_request`.
- [ ] `adapter_request` includes:
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
  - `scheduled_actions`
  - `reason_codes`
- [ ] `scheduled_actions` is deterministic and ordered exactly:
  1) `cta_buy`
  2) `cta_subscribe`
- [ ] Action mapping is deterministic from `sender_envelope.scheduled_actions`:
  - `action_type`
  - `action_stub`
  - `ad_copy`
  - `reply_template`
- [ ] `request_id` and `idempotency_key` are deterministic from stable lineage inputs (no timestamp/randomness).
- [ ] `adapter_request.reason_codes` includes:
  - `adapter_request_emitted`
  - template lineage (e.g., `template_lang_native` or `template_lang_fallback_en`)
  - variant lineage (e.g., `variant_lang_perf_win`, `variant_lang_tiebreak`, or deterministic fallback code)
- [ ] `adapter_request` is deterministic across repeated runs for identical input.
- [ ] `adapter_request` contains no precise geo or direct-contact fields (`latitude`, `longitude`, `email`, `phone`, `ip_address` absent).
- [ ] FAILED/malformed `lead_enrich` path does **not** emit `adapter_request`.
- [ ] Revenue smoke tests include explicit shape, ordering, lineage, privacy, idempotency, and repeated-run equality assertions.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary:
  - Revenue route result adds deterministic `adapter_request` for successful `lead_enrich`.
  - Top-level revenue index surfaces `adapter_request`.
  - Smoke tests validate request shape, action ordering, lineage, privacy, idempotency, and determinism.

## Rollback anchor
`rollback/TASK-RV-014-pre`

## Commit message (exact)
`feat(revenue): emit deterministic adapter request output (TASK-RV-014)`

## Verification gates (STRICT+)
1. `tests/run_staging_v2_3.Tests.ps1`
2. `tests/run_release_candidate.Tests.ps1`
3. `tests/release_gate_helpers.Tests.ps1`
4. `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
5. `apps/api/tests/api.contract.Tests.ps1`

## Closeout format required
- TASK-RV-014 completed.
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
- Keep scheduled action ordering stable (`cta_buy`, then `cta_subscribe`) and lineage explicit.
- `idempotency_key` must be deterministic and stable across retries for identical input.
- Next first command: `Get-Content docs/tasks/TASK-RV-014.md -Raw`
