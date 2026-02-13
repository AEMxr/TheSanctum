# Growth Autopilot Runbook

## Purpose
`scripts/dev/start_growth_autopilot.ps1` runs a deterministic multilingual growth pipeline that:
- discovers opportunities from campaign keywords and channel policy data,
- localizes campaign content by language,
- in `dryrun`: produces drafts only (no adapter execution),
- in `live`: executes policy-gated adapter publishing and emits receipts,
- writes tracking and summary artifacts for review.

Release boundary is enforced:
- `delivery_mode=tenant_only`
- `cross_sell_allowed=false`

Unknown policy always results in draft-only routing.

## Required inputs
- `config/growth_autopilot.json`
- `data/growth/allowlist.json`
- `data/growth/campaigns/<campaign>.json`

## Self-promotion guard
Default is fail-closed for live adapter execution:
- `config.self_promotion_mode = explicit_only`
- campaign must opt in with `self_promotion_allowed=true`

Without opt-in, live mode routes everything to drafts with reason code `self_promotion_explicit_only`.

## Publish transport
- `mock` (default): deterministic adapter execution, no network calls (safe for tests).
- `http`: posts to operator-provided HTTP endpoints (no secrets in repo).

HTTP adapter environment variables:
- X adapter:
  - `SANCTUM_GROWTH_X_ENDPOINT`
  - `SANCTUM_GROWTH_X_API_KEY` (optional)
- Discourse adapter:
  - `SANCTUM_GROWTH_DISCOURSE_ENDPOINT`
  - `SANCTUM_GROWTH_DISCOURSE_API_KEY` (optional)

## One-command start
Dryrun:
```powershell
pwsh -NoProfile -File scripts/dev/start_growth_autopilot.ps1 `
  -Mode dryrun `
  -CampaignId sample `
  -Languages all `
  -LandingUrl https://example.com/pilot
```

Live (mock):
```powershell
pwsh -NoProfile -File scripts/dev/start_growth_autopilot.ps1 `
  -Mode live `
  -PublishTransport mock `
  -CampaignId sample `
  -Languages all `
  -LandingUrl https://example.com/pilot
```

Live (http):
```powershell
pwsh -NoProfile -File scripts/dev/start_growth_autopilot.ps1 `
  -Mode live `
  -PublishTransport http `
  -CampaignId sample `
  -Languages all `
  -LandingUrl https://example.com/pilot
```

## Modes
- `dryrun`: deterministic full pipeline; no adapter execution; outputs drafts + metrics projection.
- `live`: executes adapter publishing only when:
  - policy is known,
  - `autopost_allowed=true` and `requires_human_review=false`,
  - `safe_mode=false` and `global_emergency_stop=false`,
  - campaign opted in to self-promotion (when `explicit_only` is enabled),
  - daily caps/budget allow.
  All other channels are draft-only.

## Artifacts
Each run writes:
- `artifacts/runtime/growth_autopilot.summary.json`
- `artifacts/runtime/growth_autopilot.posts.json`
- `artifacts/runtime/growth_autopilot.drafts.json`
- `artifacts/runtime/growth_autopilot.metrics.json`
- `artifacts/runtime/growth_autopilot.errors.json`
- `artifacts/runtime/growth_autopilot.adapter_requests.json`
- `artifacts/runtime/growth_autopilot.publish_receipts.json`

Run state snapshot:
- `data/growth/state/<campaign_id>.<run_signature>.json`

Idempotency ledger (prevents duplicate adapter attempts for the same run signature):
- `data/growth/state/publish_ledger.<campaign_id>.json`

## Safety and kill switches
- `global_emergency_stop=true` in config forces draft-only behavior.
- `safe_mode=true` in config forces draft-only behavior.
- Unknown channel policy is fail-closed (`policy_unknown_draft_only`).

## Troubleshooting
- `Config delivery_mode must remain tenant_only.`:
  config violated release boundary.
- `Config cross_sell_allowed must remain false.`:
  config violated release boundary.
- No posts in live mode:
  check allowlist policy flags, self-promotion opt-in, and safe mode settings.
- Unexpected drafts:
  inspect `reason_codes` in `growth_autopilot.drafts.json`.
- HTTP transport fails with `adapter_http_endpoint_missing`:
  set the required `SANCTUM_GROWTH_*_ENDPOINT` environment variable(s) or use `-PublishTransport mock`.

## Rollback
- Stop usage of the script and switch to dryrun:
```powershell
pwsh -NoProfile -File scripts/dev/start_growth_autopilot.ps1 -Mode dryrun -CampaignId sample
```
- Revert the merge commit if required:
```bash
git revert <merge_commit_sha>
```
