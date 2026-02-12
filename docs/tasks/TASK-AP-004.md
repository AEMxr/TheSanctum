# TASK-AP-004 - Language API HTTP mode with production middleware

## Objective lane
api

## Goal (single measurable outcome)
Add HTTP service mode to Language API with API key auth, per-key rate limiting, idempotency for POST, request limits/timeouts, problem+json errors, and usage metering while preserving existing script mode.

## Scope (allowed files)
- `apps/api/src/index.ps1`
- `apps/api/config.example.json`
- `scripts/lib/http_service_common.ps1`
- `docs/tasks/TASK-AP-004.md`

## Non-goals
- No release-gate semantic changes.
- No breaking changes to existing script-mode invocation.
- No edits outside scoped files.

## Acceptance checklist
- [ ] Language API supports HTTP service mode with routes:
  - [ ] `GET /health`
  - [ ] `GET /ready`
  - [ ] `POST /v1/language/detect`
  - [ ] `POST /v1/language/translate`
- [ ] HTTP responses include `request_id`, `schema_version`, and `provider_used`.
- [ ] API key auth via `X-API-Key` is enforced for protected routes.
- [ ] Per-key and per-endpoint rate limiting returns HTTP 429 on exceed.
- [ ] POST idempotency via `Idempotency-Key` returns replayed response for same key+route+body hash.
- [ ] Request size and request timeout limits are enforced/configurable.
- [ ] Errors use problem+json with stable shape and `request_id`.
- [ ] Usage metering ledger appends per-request usage entries.
- [ ] Existing script mode behavior remains backward compatible.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
`rollback/TASK-AP-004-pre`

## Commit message (exact)
`TASK-AP-004 feat(api): add language api http mode with production middleware`

## Execution notes
- Next first command: `Get-Content docs/tasks/TASK-RV-027.md -Raw`
