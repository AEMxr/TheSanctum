# TASK-RV-013 - Emit deterministic sender envelope output

## Objective lane
revenue

## Goal (single measurable outcome)
On successful `lead_enrich`, emit a deterministic `sender_envelope` object derived from `delivery_manifest` that is directly consumable by downstream sender adapters.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-013.md`

## Non-goals
- No release-gate semantic changes.
- No control-plane schema/version bumps outside scoped response shaping.
- No edits outside scoped files.
- No randomness/time-based branching.

## Acceptance checklist
- [ ] Successful `lead_enrich` emits `result.sender_envelope`.
- [ ] `sender_envelope` includes:
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
- [ ] Action mapping is deterministic from `delivery_manifest.actions`:
  - `scheduled_actions[0]` maps from `cta_buy`
  - `scheduled_actions[1]` maps from `cta_subscribe`
  - localized fields preserve `ad_copy` / `reply_template`
  - stubs map from action `action_stub`
- [ ] `sender_envelope.reason_codes` includes:
  - `sender_envelope_emitted`
  - template lineage (e.g., `template_lang_native` or `template_lang_fallback_en`)
  - variant lineage (e.g., `variant_lang_perf_win`, `variant_lang_tiebreak`, or deterministic fallback code)
- [ ] `sender_envelope` is deterministic across repeated runs for identical input.
- [ ] `sender_envelope` contains no precise geo or direct-contact fields (`latitude`, `longitude`, `email`, `phone`, `ip_address` absent).
- [ ] FAILED/malformed `lead_enrich` path does **not** emit `sender_envelope`.
- [ ] Revenue smoke tests include explicit shape, ordering, lineage, privacy, and repeated-run equality assertions.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary:
  - Revenue route result adds deterministic `sender_envelope` for successful `lead_enrich`.
  - Top-level revenue index surfaces `sender_envelope`.
  - Smoke tests validate envelope shape, ordering, lineage, privacy, and determinism.

## Rollback anchor
`rollback/TASK-RV-013-pre`

## Commit message (exact)
`feat(revenue): emit deterministic sender envelope output (TASK-RV-013)`

## Verification gates (STRICT+)
1. `tests/run_staging_v2_3.Tests.ps1`
2. `tests/run_release_candidate.Tests.ps1`
3. `tests/release_gate_helpers.Tests.ps1`
4. `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
5. `apps/api/tests/api.contract.Tests.ps1`

## Closeout format required
- TASK-RV-013 completed.
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
- `envelope_id` must be deterministic from stable lineage inputs (task/campaign/channel/variant/delivery lineage), with no timestamps/randomness.
- Keep scheduled action ordering stable (`cta_buy`, then `cta_subscribe`) and lineage explicit.
- Next first command: `Get-Content docs/tasks/TASK-RV-013.md -Raw`
