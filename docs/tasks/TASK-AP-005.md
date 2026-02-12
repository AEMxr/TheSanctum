# TASK-AP-005 - OpenAPI specs and live localhost integration tests

## Objective lane
api

## Goal (single measurable outcome)
Add OpenAPI specs and live localhost integration tests for both APIs covering auth, validation, rate limit, idempotency, and deterministic responses.

## Scope (allowed files)
- `docs/openapi/language_api.yaml`
- `docs/openapi/marketing_revenue_api.yaml`
- `docs/postman/language_api.postman_collection.json`
- `docs/postman/marketing_revenue_api.postman_collection.json`
- `tests/integration/language_api.http.Tests.ps1`
- `tests/integration/revenue_api.http.Tests.ps1`
- `tests/integration/common_http_test_utils.ps1`
- `apps/api/src/index.ps1`
- `scripts/dev/start_both_apis.ps1`
- `scripts/dev/stop_both_apis.ps1`
- `scripts/dev/wait_for_health.ps1`
- `scripts/dev/run_both_apis_smoke.ps1`
- `scripts/lib/http_service_common.ps1`
- `tests/both_apis.smoke.Tests.ps1`
- `docs/tasks/TASK-AP-005.md`

## Non-goals
- No release-gate semantic changes.
- No edits outside scoped files.

## Acceptance checklist
- [ ] OpenAPI specs are present for both APIs with auth, rate limit, idempotency, and error examples.
- [ ] Postman collections are present for both APIs.
- [ ] Integration tests spin up localhost services and validate:
  - [ ] health/readiness
  - [ ] happy path
  - [ ] invalid payload -> 400 problem+json
  - [ ] missing/invalid API key -> 401/403
  - [ ] rate limit -> 429
  - [ ] idempotency replay returns same payload
- [ ] Existing smoke/start-stop scripts use live HTTP checks.
- [ ] Existing tests remain compatible.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
`rollback/TASK-AP-005-pre`

## Commit message (exact)
`TASK-AP-005 test(api): add openapi contracts and live localhost integration tests`

## Execution notes
- Next first command: `Get-Content docs/tasks/TASK-RV-028.md -Raw`
