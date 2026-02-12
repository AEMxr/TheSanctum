# Sanctum Language API

Deterministic language detection/translation API with script mode and HTTP mode.

## Run in HTTP mode
```powershell
pwsh -NoProfile -File apps/api/src/index.ps1 -Serve -ConfigPath apps/api/config.example.json
```

## Core endpoints
- `GET /health`
- `GET /ready`
- `POST /v1/language/detect`
- `POST /v1/language/translate`
- `GET /v1/admin/usage` (admin key)

## One-command local startup (both APIs)
```powershell
pwsh -NoProfile -File scripts/dev/start_both_apis.ps1
```

## One-command smoke
```powershell
pwsh -NoProfile -File scripts/dev/run_both_apis_smoke.ps1 -OutputPath artifacts/dual_api_smoke_summary.json
```

## Contract and examples
- OpenAPI: `docs/openapi/language_api.yaml`
- Postman: `docs/postman/language_api.postman_collection.json`

## Usage export
```powershell
pwsh -NoProfile -File scripts/dev/export_usage_ledger.ps1 -Api language -Format json -OutputPath artifacts/language_usage.json
```
