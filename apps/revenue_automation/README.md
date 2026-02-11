# Revenue Automation API

Deterministic marketing/revenue task execution engine with script mode and HTTP mode.

## Safety defaults
- `enable_revenue_automation=false` (must be enabled to execute tasks)
- `safe_mode=true`
- `dry_run=true`

## Script mode
```powershell
pwsh -NoProfile -File apps/revenue_automation/src/index.ps1 -ConfigPath apps/revenue_automation/config.example.json -TaskPath <task.json>
```

## HTTP mode
```powershell
pwsh -NoProfile -File apps/revenue_automation/src/index.ps1 -Serve -ConfigPath apps/revenue_automation/config.example.json
```

## Core endpoints
- `GET /health`
- `GET /ready`
- `POST /v1/marketing/task/execute`
- `POST /v1/revenue/task/execute` (alias)
- `GET /v1/admin/usage` (admin key)

## One-command startup for both APIs
```powershell
pwsh -NoProfile -File scripts/dev/start_both_apis.ps1
```

## One-command smoke
```powershell
pwsh -NoProfile -File scripts/dev/run_both_apis_smoke.ps1 -OutputPath artifacts/dual_api_smoke_summary.json
```

## Usage export
```powershell
pwsh -NoProfile -File scripts/dev/export_usage_ledger.ps1 -Api revenue -Format json -OutputPath artifacts/revenue_usage.json
```

## Contract and examples
- OpenAPI: `docs/openapi/marketing_revenue_api.yaml`
- Postman: `docs/postman/marketing_revenue_api.postman_collection.json`
