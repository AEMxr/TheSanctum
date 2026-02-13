# Growth Autopilot Runbook

## Purpose
`scripts/dev/start_growth_autopilot.ps1` runs a deterministic multilingual growth pipeline that:
- discovers opportunities from campaign keywords and channel policy data,
- localizes campaign content by language,
- auto-publishes only for allowlisted channels in live mode,
- sends unknown/unsafe channels to draft-only,
- writes tracking and summary artifacts for review.

Policy boundary is enforced:
- `delivery_mode=tenant_only`
- `cross_sell_allowed=false`

Unknown policy always results in draft-only routing.

## Required inputs
- `config/growth_autopilot.json`
- `data/growth/allowlist.json`
- `data/growth/campaigns/<campaign>.json`

## One-command start
Dryrun:
```powershell
pwsh -NoProfile -File scripts/dev/start_growth_autopilot.ps1 `
  -Mode dryrun `
  -CampaignId sample `
  -Languages all `
  -LandingUrl https://example.com/pilot
```

Live:
```powershell
pwsh -NoProfile -File scripts/dev/start_growth_autopilot.ps1 `
  -Mode live `
  -CampaignId sample `
  -Languages all `
  -LandingUrl https://example.com/pilot
```

## Modes
- `dryrun`: deterministic full pipeline, no live posting actions executed. Output is draft queue + metrics projection.
- `live`: executes autopost only for channels with `autopost_allowed=true` and `requires_human_review=false`. All other channels are draft-only.

## Artifacts
Each run writes:
- `artifacts/runtime/growth_autopilot.summary.json`
- `artifacts/runtime/growth_autopilot.posts.json`
- `artifacts/runtime/growth_autopilot.drafts.json`
- `artifacts/runtime/growth_autopilot.metrics.json`
- `artifacts/runtime/growth_autopilot.errors.json`

Run state snapshot:
- `data/growth/state/<campaign_id>.<run_signature>.json`

## Safety and kill switches
- `global_emergency_stop=true` in config forces draft-only behavior.
- `safe_mode=true` in config forces draft-only behavior.
- Unknown channel policy is fail-closed (`policy_unknown_draft_only`).

## Troubleshooting
- `Config delivery_mode must remain tenant_only.`:
  config was edited outside approved boundary.
- `Config cross_sell_allowed must remain false.`:
  config violated release boundary.
- No posts in live mode:
  check allowlist policy flags and safe mode settings.
- Unexpected drafts:
  inspect `reason_codes` in `growth_autopilot.drafts.json`.

## Rollback
- Stop usage of the script and switch to dryrun:
```powershell
pwsh -NoProfile -File scripts/dev/start_growth_autopilot.ps1 -Mode dryrun -CampaignId sample
```
- Revert branch commit if required:
```bash
git revert <commit_sha>
```
