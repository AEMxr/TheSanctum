# TASK-RV-018 - Emit deterministic evidence envelope output

## Objective lane
revenue

## Goal (single measurable outcome)
On successful `lead_enrich`, emit a deterministic `evidence_envelope` object derived from `audit_record` that is directly consumable by downstream retention/signing/export pipelines.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-018.md`

## Non-goals
- No release-gate semantic changes.
- No control-plane schema/version bumps outside scoped response shaping.
- No edits outside scoped files.
- No randomness/time-based branching.

## Acceptance checklist
- [ ] Successful `lead_enrich` emits `result.evidence_envelope`.
- [ ] `evidence_envelope` includes:
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
- [ ] Action mapping is deterministic from `audit_record.accepted_action_types`:
  - includes only action-type lineage in stable order
- [ ] `envelope_id` is deterministic from stable lineage inputs (task/campaign/channel/variant/record), with no timestamp/randomness.
- [ ] `evidence_envelope.reason_codes` includes:
  - `evidence_envelope_emitted`
  - `dispatch_receipt_dry_run` (when `dry_run=true`)
  - template lineage (e.g., `template_lang_native` or `template_lang_fallback_en`)
  - variant lineage (e.g., `variant_lang_perf_win`, `variant_lang_tiebreak`, or deterministic fallback code)
- [ ] `evidence_envelope` is deterministic across repeated runs for identical input.
- [ ] `evidence_envelope` contains no precise geo or direct-contact fields (`latitude`, `longitude`, `email`, `phone`, `ip_address` absent).
- [ ] FAILED/malformed `lead_enrich` path does **not** emit `evidence_envelope`.
- [ ] Revenue smoke tests include explicit shape, ordering, lineage, privacy, and repeated-run equality assertions.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary:
  - Revenue route result adds deterministic `evidence_envelope` for successful `lead_enrich`.
  - Top-level revenue index surfaces `evidence_envelope`.
  - Smoke tests validate envelope shape, ordering, lineage, privacy, and determinism.

## Rollback anchor
`rollback/TASK-RV-018-pre`

## Commit message (exact)
`feat(revenue): emit deterministic evidence envelope output (TASK-RV-018)`

## Verification gates (STRICT+)
1. `tests/run_staging_v2_3.Tests.ps1`
2. `tests/run_release_candidate.Tests.ps1`
3. `tests/release_gate_helpers.Tests.ps1`
4. `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
5. `apps/api/tests/api.contract.Tests.ps1`

## Closeout format required
- TASK-RV-018 completed.
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
- `envelope_id` must be deterministic and stable across retries for identical input.
- Next first command: `Get-Content docs/tasks/TASK-RV-018.md -Raw`
