# TASK-RV-020 - Emit deterministic immutability receipt output

## Objective lane
revenue

## Goal (single measurable outcome)
On successful `lead_enrich`, emit a deterministic `immutability_receipt` object derived from `retention_manifest` that is directly consumable by downstream notarization/attestation/append-only ledger pipelines.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-020.md`

## Non-goals
- No release-gate semantic changes.
- No control-plane schema/version bumps outside scoped response shaping.
- No edits outside scoped files.
- No randomness/time-based branching.

## Acceptance checklist
- [ ] Successful `lead_enrich` emits `result.immutability_receipt`.
- [ ] `immutability_receipt` includes:
  - `immutability_id`
  - `manifest_id`
  - `envelope_id`
  - `record_id`
  - `event_id`
  - `receipt_id`
  - `request_id`
  - `idempotency_key`
  - `campaign_id`
  - `channel`
  - `language_code`
  - `selected_variant_id`
  - `provider_mode`
  - `dry_run`
  - `status`
  - `accepted_action_types`
  - `reason_codes`
- [ ] `accepted_action_types` is deterministic and ordered exactly:
  1) `cta_buy`
  2) `cta_subscribe`
- [ ] Action mapping is deterministic from `retention_manifest.accepted_action_types`:
  - includes only action-type lineage in stable order
- [ ] `immutability_id` is deterministic from stable lineage inputs (task/campaign/channel/variant/manifest), with no timestamp/randomness.
- [ ] `immutability_receipt.reason_codes` includes:
  - `immutability_receipt_emitted`
  - `dispatch_receipt_dry_run` (when `dry_run=true`)
  - template lineage (e.g., `template_lang_native` or `template_lang_fallback_en`)
  - variant lineage (e.g., `variant_lang_perf_win`, `variant_lang_tiebreak`, or deterministic fallback code)
- [ ] `immutability_receipt` is deterministic across repeated runs for identical input.
- [ ] `immutability_receipt` contains no precise geo or direct-contact fields (`latitude`, `longitude`, `email`, `phone`, `ip_address` absent).
- [ ] FAILED/malformed `lead_enrich` path does **not** emit `immutability_receipt`.
- [ ] Revenue smoke tests include explicit shape, ordering, lineage, privacy, and repeated-run equality assertions.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary:
  - Revenue route result adds deterministic `immutability_receipt` for successful `lead_enrich`.
  - Top-level revenue index surfaces `immutability_receipt`.
  - Smoke tests validate receipt shape, ordering, lineage, privacy, and determinism.

## Rollback anchor
`rollback/TASK-RV-020-pre`

## Commit message (exact)
`feat(revenue): emit deterministic immutability receipt output (TASK-RV-020)`

## Verification gates (STRICT+)
1. `tests/run_staging_v2_3.Tests.ps1`
2. `tests/run_release_candidate.Tests.ps1`
3. `tests/release_gate_helpers.Tests.ps1`
4. `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
5. `apps/api/tests/api.contract.Tests.ps1`

## Closeout format required
- TASK-RV-020 completed.
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
- Keep action-type ordering stable (`cta_buy`, then `cta_subscribe`) and lineage explicit.
- `immutability_id` must be deterministic and stable across retries for identical input.
- Next first command: `Get-Content docs/tasks/TASK-RV-020.md -Raw`
