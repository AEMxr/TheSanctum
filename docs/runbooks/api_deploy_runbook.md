# API Deploy Runbook

## Purpose
Deploy and operate both Sanctum APIs in HTTP mode with deterministic behavior, auth, rate limiting, idempotency, and usage metering.

## Services
- Language API: `apps/api/src/index.ps1`
- Marketing/Revenue API: `apps/revenue_automation/src/index.ps1`

## Local Run (One-command)
```powershell
pwsh -NoProfile -File scripts/dev/start_both_apis.ps1
```

## Local Smoke (One-command)
```powershell
pwsh -NoProfile -File scripts/dev/run_both_apis_smoke.ps1 -OutputPath artifacts/dual_api_smoke_summary.json
```

## Stop Services
```powershell
pwsh -NoProfile -File scripts/dev/stop_both_apis.ps1
```

## Export Usage Ledger
JSON:
```powershell
pwsh -NoProfile -File scripts/dev/export_usage_ledger.ps1 -Api both -Format json -OutputPath artifacts/usage_export.json
```

CSV:
```powershell
pwsh -NoProfile -File scripts/dev/export_usage_ledger.ps1 -Api both -Format csv -OutputPath artifacts/usage_export.csv
```

## Windows Service Option
Use NSSM/SC to wrap each command as a service process:
- Language API:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File apps/api/src/index.ps1 -Serve -ConfigPath apps/api/config.example.json`
- Revenue API:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File apps/revenue_automation/src/index.ps1 -Serve -ConfigPath apps/revenue_automation/config.example.json`

Set service recovery to restart on failure and monitor `/ready` endpoints.

## Reverse Proxy Note
Place IIS/NGINX/Caddy in front of both APIs:
- TLS termination
- Request size guard and timeout alignment with API settings
- Header forwarding for request tracing (`X-Request-Id`)
- Optional IP allowlists for admin usage endpoint `/v1/admin/usage`

## Production Hardening Checklist
- [ ] Replace default API keys with strong secrets; no default keys in runtime.
- [ ] Prefer `key_sha256` entries in config for at-rest key protection (clear `key` remains supported for local dev).
- [ ] Separate standard vs admin API keys.
- [ ] Restrict `/v1/admin/usage` to admin keys and trusted networks.
- [ ] Tune rate limits per key tier.
- [ ] Set `http.state_backend` to `file` and configure a durable `http.shared_state_path` per service for multi-process consistency.
- [ ] Tune request body limits and timeouts per environment.
- [ ] Store usage ledgers on durable storage with log rotation.
- [ ] Run smoke and integration suites before deployment.
- [ ] Enable centralized log shipping for response status and latency.

## Shared State + Outage Mode
- `http.state_backend` supports `memory` (default) and `file`.
- For horizontal scale or multi-process hosts, use `file` with a shared durable path and filesystem locking support.
- Current outage behavior:
  - Rate limiting: **fail-closed** (request returns server error when shared state lock/read fails).
  - Idempotency replay: **fail-closed** (request returns server error when shared state lock/read/write fails).
- Follow-up hardening:
  - Introduce explicit per-endpoint fail-open/fail-closed toggles if business policy requires degraded-availability handling.
- Keep shared state storage free of PII and rotate/backup based on retention policy.

## API Marketplace Readiness Checklist
- [ ] OpenAPI specs published:
  - `docs/openapi/language_api.yaml`
  - `docs/openapi/marketing_revenue_api.yaml`
- [ ] Postman collections published:
  - `docs/postman/language_api.postman_collection.json`
  - `docs/postman/marketing_revenue_api.postman_collection.json`
- [ ] Auth, rate limit, idempotency behavior documented publicly.
- [ ] Billing export pipeline validated using usage ledger export.
- [ ] Support SLA and incident response playbook linked.
