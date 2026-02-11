# TASK-RV-021 - Emit deterministic ledger attestation output

## Objective lane
revenue

## Goal (single measurable outcome)
On successful `lead_enrich`, emit a deterministic `ledger_attestation` object derived from `immutability_receipt` that is directly consumable by downstream anchoring/indexing/proof-verification pipelines.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-021.md`

## Non-goals
- No release-gate semantic changes.
- No control-plane schema/version bumps outside scoped response shaping.
- No edits outside scoped files.
- No randomness/time-based branching.

## Acceptance checklist
- [ ] Successful `lead_enrich` emits `result.ledger_attestation`.
- [ ] `ledger_attestation` includes:
  - `attestation_id`
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
- [ ] Action mapping is deterministic from `immutability_receipt.accepted_action_types`:
  - includes only action-type lineage in stable order
- [ ] `attestation_id` is deterministic from stable lineage inputs (task/campaign/channel/variant/immutability), with no timestamp/randomness.
- [ ] `ledger_attestation.reason_codes` includes:
  - `ledger_attestation_emitted`
  - `dispatch_receipt_dry_run` (when `dry_run=true`)
  - template lineage (e.g., `template_lang_native` or `template_lang_fallback_en`)
  - variant lineage (e.g., `variant_lang_perf_win`, `variant_lang_tiebreak`, or deterministic fallback code)
- [ ] `ledger_attestation` is deterministic across repeated runs for identical input.
- [ ] `ledger_attestation` contains no precise geo or direct-contact fields (`latitude`, `longitude`, `email`, `phone`, `ip_address` absent).
- [ ] FAILED/malformed `lead_enrich` path does **not** emit `ledger_attestation`.
- [ ] Revenue smoke tests include explicit shape, ordering, lineage, privacy, and repeated-run equality assertions.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary:
  - Revenue route result adds deterministic `ledger_attestation` for successful `lead_enrich`.
  - Top-level revenue index surfaces `ledger_attestation`.
  - Smoke tests validate attestation shape, ordering, lineage, privacy, and determinism.

## Rollback anchor
`rollback/TASK-RV-021-pre`

## Commit message (exact)
`feat(revenue): emit deterministic ledger attestation output (TASK-RV-021)`

## Verification gates (STRICT+)
1. `tests/run_staging_v2_3.Tests.ps1`
2. `tests/run_release_candidate.Tests.ps1`
3. `tests/release_gate_helpers.Tests.ps1`
4. `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
5. `apps/api/tests/api.contract.Tests.ps1`

## Closeout format required
- TASK-RV-021 completed.
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
- `attestation_id` must be deterministic and stable across retries for identical input.
- Next first command: `Get-Content docs/tasks/TASK-RV-021.md -Raw`
