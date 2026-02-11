# TASK-RV-012 - Emit deterministic delivery manifest output

## Objective lane
revenue

## Goal (single measurable outcome)
On successful `lead_enrich`, emit a deterministic `delivery_manifest` object that is immediately usable by a downstream sender/executor, with stable lineage and privacy-safe fields.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-012.md`

## Non-goals
- No release-gate semantic changes.
- No schema version bumps outside scoped response shaping.
- No edits outside scoped files.
- No randomness/time-based branching in manifest generation.

## Acceptance checklist
- [ ] Successful `lead_enrich` emits `result.delivery_manifest`.
- [ ] `delivery_manifest` includes:
  - `delivery_id`
  - `dispatch_id`
  - `campaign_id`
  - `channel`
  - `language_code`
  - `selected_variant_id`
  - `provider_mode`
  - `dry_run`
  - `actions`
  - `reason_codes`
- [ ] `actions` is deterministic and ordered exactly:
  1) `cta_buy`
  2) `cta_subscribe`
- [ ] Action payloads map deterministically from existing outputs:
  - buy action uses `dispatch_plan.cta_buy_stub`
  - subscribe action uses `dispatch_plan.cta_subscribe_stub`
  - localized copy fields come from `dispatch_plan.ad_copy` / `dispatch_plan.reply_template`
- [ ] `delivery_manifest.reason_codes` includes:
  - `delivery_manifest_emitted`
  - template lineage (e.g., `template_lang_native` or `template_lang_fallback_en`)
  - variant lineage (e.g., `variant_lang_perf_win` or deterministic fallback/tiebreak code)
- [ ] `delivery_manifest` is deterministic across repeated runs for identical input.
- [ ] `delivery_manifest` contains no precise geo or direct-contact fields (`latitude`, `longitude`, `email`, `phone`, `ip_address` absent).
- [ ] FAILED/malformed `lead_enrich` path does **not** emit `delivery_manifest`.
- [ ] Revenue smoke tests include explicit shape, lineage, privacy, and repeated-run equality assertions.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary:
  - Revenue route result adds deterministic `delivery_manifest` for successful `lead_enrich`.
  - Top-level revenue index surfaces `delivery_manifest`.
  - Smoke tests validate manifest shape, action ordering, lineage, privacy, and determinism.

## Rollback anchor
`rollback/TASK-RV-012-pre`

## Commit message (exact)
`feat(revenue): emit deterministic delivery manifest output (TASK-RV-012)`

## Verification gates (STRICT+)
1. `tests/run_staging_v2_3.Tests.ps1`
2. `tests/run_release_candidate.Tests.ps1`
3. `tests/release_gate_helpers.Tests.ps1`
4. `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
5. `apps/api/tests/api.contract.Tests.ps1`

## Closeout format required
- TASK-RV-012 completed.
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
- `delivery_id` must be deterministic from stable inputs (task/campaign/channel/variant lineage), with no timestamps/randomness.
- Keep action ordering stable (`cta_buy`, then `cta_subscribe`) and keep reason lineage explicit.
- Next first command: `Get-Content docs/tasks/TASK-RV-012.md -Raw`
