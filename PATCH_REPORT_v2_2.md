# PATCH_REPORT_v2_2

## FILE CHANGE SUMMARY
- `sanctum_v2_2_runtime.sql`: hardened consent nonce flow, append-only/event governance triggers, memory supersession checks, onboarding state machine guards, projection redaction/index parity.
- `telemetry_pack_v2_1.sql`: fixed and parameterized dashboard windowing, normalized 7 core metrics, refresh procedure, grants.
- `p0_db_checks.sql`: replaced with deterministic 12-check PASS/FAIL SQL harness + non-zero fail behavior.
- `p0_ci_gate.ps1`: full hard/warn telemetry gate logic, env-driven thresholds, P0 flow fixes, clearer failure reporting.
- `openapi_hgmoe_v2_2.yaml`: tightened schemas, explicit guardrail behavior docs, telemetry contract parity, stable errors, 409 mapping.
- `council_contracts_v2_2.json`: strict role schema parity (including Economist extension + nullable recommended_action), guardrail semantics.

## POST-AUDIT PATCHES (THIS PASS)
- `p0_ci_gate.ps1`
  - Added baseline-aware nonce-misuse hard gate to avoid false failures from intentional negative tests.
  - Added env switches:
    - `enforce_nonce_misuse_hard_gate`
    - `expected_nonce_replay_from_p0`
    - `expected_nonce_binding_mismatch_from_p0`
  - Removed duplicate DB check execution in normal API-test path (DB checks run via P0-12 test, or via `Run-DbChecks` only when `-SkipApiTests`).
  - Method-aware idempotency header handling (unsafe methods only unless explicit key is supplied).
  - Added robust error body parsing fallback (`ResponseStream` -> `ErrorDetails.Message` -> regex extraction).
  - Added retry/timeout wrapper for telemetry GET and JSON artifact output (`ResultsJsonPath`).
- `telemetry_pack_v2_1.sql`
  - Policy check parsing is now fail-closed for malformed booleans.
  - Window parameters capped to max 365 days.
  - Added explicit note that onboarding completion metric is cumulative.
- `sanctum_v2_2_runtime.sql`
  - Added high-utility indexes for global dashboards:
    - `idx_event_type_ts_user`
    - `idx_decision_actionability_ts`
  - Hardened `SECURITY DEFINER` posture:
    - revoke public execute on `get_user_projection`
    - grant execute only to `app_role` (if present).
  - Simplified nonce generation to strong random token (`encode(gen_random_bytes(32), 'hex')`) while preserving tuple binding checks at confirmation.
  - Refactored nonce failure diagnostics to single-row nonce lookup branch (reduces edge-case ambiguity around concurrent status checks).
  - Tightened non-privileged projection redaction for high-sensitivity memories to placeholder-only.
  - Cleaned duplicate/overlapping `decision_records` recommendation checks and consolidated to a single stronger constraint (`chk_recommendation_id_not_blank` with `btrim(...) <> ''`).
  - Tightened upgrade constraint guards to table-scoped checks (`conrelid = 'decision_records'::regclass`) to avoid false positives from same-named constraints on other relations.
  - Clarified `material_action_confirmed` `ALTER TABLE ... IF NOT EXISTS` as upgrade safety (legacy schema compatibility).
- `openapi_hgmoe_v2_2.yaml`
  - Clarified `onboarding_completion_rate_current` semantics as cumulative completion-to-date.
  - Added `recommendation_id` to required `DecisionEvaluateResponse` contract.
  - Added missing error code `GOVERNANCE_TICKET_INVALID` to `ApiError` enum.
  - Tightened `ProjectionResponse` from loose object to required structured keys.
  - Added bearer auth scheme + global security requirement.
  - Added operationIds and `x-idempotency-required` markers on mutating endpoints.
  - Tightened onboarding step response schema (`GenericStepResponse`) with required keys.
  - Added `caller_role` and `domain` enums for `DecisionEvaluateRequest`.
  - Added transient error codes (`RATE_LIMITED`, `SERVICE_UNAVAILABLE`, `TIMEOUT_UPSTREAM`) + `retry_after_seconds`.
  - Tightened `recommendation_id` schema with non-whitespace validation (`minLength: 1`, `pattern: '.*\\S.*'`) in both evaluate response and confirm request, matching DB constraint semantics.
- `p0_ci_gate.ps1`
  - Removed recommendation-id fallback ambiguity; CI now requires `recommendation_id` to be present in evaluate responses.
  - Removed deprecated CLI switches (`PsqlCommand`, `NewmanCommand`) to enforce the v2.2 execution contract.
  - Added command portability options: `PsqlExe/PsqlArgs` and `NewmanExe/NewmanArgs`.
  - Added timeout/retry controls for telemetry calls.
  - Added strict `recommendation_id` string assertions (non-null, string, non-whitespace) in P0 evaluate checks.
  - Added strict non-negative integer validation for baseline/current nonce misuse counters before delta math.
  - Added safe numeric environment parsing helpers (`Get-EnvIntOrDefault`, `Get-EnvDoubleOrDefault`) with warning + fallback behavior.
  - Added transient-only retry behavior in API retry wrapper (retries only transport/timeout, 408/425/429, and 5xx).
  - Switched DB-check invocation to script-relative path resolution (`$PSCommandPath`) to remove CWD dependency in CI.
  - Added map-shape assertions for telemetry objects (`nonce_misuse_events_7d`, `override_rate_by_domain_7d`) before field extraction.
  - Added per-test duration capture (`DurationMs`) and richer API error diagnostics.
  - Updated `P0-08` duplicate-primarch test to invoke second step-4 call as active primarch (matches post-step4 governance gate, still asserts 409/`PRIMARCH_ALREADY_EXISTS`).
- `p0_db_checks.sql`
  - Updated check #8 to invoke the duplicate step-4 call with the first primarch node as caller, preserving uniqueness semantics under primarch-only governance after step 4.

## WHAT WAS WRONG

### sanctum_v2_2_runtime.sql
- Nonce function signature drift and mixed secret handling patterns.
- Risk of cross-layer mismatch on nonce semantics and material-action confirmation.
- Needed explicit app-role permission hardening for `event_log`.

### telemetry_pack_v2_1.sql
- Needed explicit window parameterization for portability and CI threshold alignment.
- Dashboard consumers needed stable key contract and clamped [0,1] metrics.

### p0_db_checks.sql
- Previously only partial checks (immutability/deletes), not full required 12 P0 assertions.

### p0_ci_gate.ps1
- Missing hard/warn telemetry gate semantics.
- Missing env-driven threshold handling.
- Nonce tests had recommendation-id variable mismatch risk.

### openapi_hgmoe_v2_2.yaml
- `DecisionEvaluateResponse` was too generic for strict contract compliance.
- Missing explicit orchestration guardrail descriptions and richer role schemas.
- Needed explicit 409 conflict behavior for duplicate primarch.

### council_contracts_v2_2.json
- `recommended_action` was string-only, not `string|null`.
- Needed explicit documented economist priority note for runtime alignment.

## WHAT CHANGED (WITH EVIDENCE)

### `sanctum_v2_2_runtime.sql`
- **Nonce index/lookup parity**: `uq_nonce_binding_active`, `idx_nonce_lookup` (`lines 238, 246`).
- **Append-only event log**: `deny_event_log_mutation` + update/delete triggers (`lines 347-364`).
- **Governance mutation gates**: `enforce_boundary_governance` (`line 375`), lineage/policy gate triggers nearby.
- **Memory supersession legality + cycle prevention**: `enforce_memory_supersession` (`line 465`).
- **Projection function ship-path**: `get_user_projection` with `co_primarch`, redaction/filtering + metadata (`line 513`, role check around `line 533`).
- **Nonce create function hardened signature**: `create_or_get_consent_nonce(p_user_stable_id, p_session_id, p_record_id, p_action_hash, p_ttl_seconds)` (`line 678`) with `FOR UPDATE` and hashed event payload (`line 771`).
- **Confirm taxonomy + atomic consume**: `confirm_material_action` (`line 788`) with hash-only event logging (`line 849`).
- **Onboarding hardening**: `onboarding_status` table (`line 195`) and `onboarding_confirm` (`line 1217`) returning projection (`line 1261`).
- **Caller scope lookup index**: `idx_ln_caller_read_scope` (`line 247`).

### `telemetry_pack_v2_1.sql`
- **7 required metrics surfaced** in dashboard payload (`lines 581-609`).
- **Dashboard function parameterized windows**: `get_dashboard_snapshot(..., p_short_window_days, p_long_window_days)` (`line 388`).
- **Material nonce metric aligned to confirmed actions** in daily MV + snapshot (`line 410`, `line 581`).
- **Refresh orchestration**: `telemetry.refresh_all_telemetry` (`line 648`).

### `p0_db_checks.sql`
- Full deterministic PASS/FAIL matrix via `tmp_p0_results` (`lines 5-10`).
- 12 checks mapped and executed (`sections starting lines 50, 119, ... 398`).
- Script exits non-zero on any failure via `P0_DB_CHECKS_FAILED` (`line 449`).

### `p0_ci_gate.ps1`
- Added env-threshold ingestion (`lines 26-31`).
- 12 P0 API tests retained/fixed (`lines 173-457`).
- Telemetry hard/warn gate implemented (`line 473` onward).
- Hard failures for nonce misuse replay/binding mismatch (`lines 515-522`).
- Clear pass/fail summary and non-zero exit on hard failures (`line 566`).

### `openapi_hgmoe_v2_2.yaml`
- Guardrail + economist mission docs added under `/decisions/evaluate`.
- Added/strengthened schemas:
  - `DecisionEvaluateResponse` (`line 505`)
  - `CouncilRoleOutput` (`line 577`)
  - `NouraFinalOutput` (`line 621`)
  - `DecisionEvaluateMetadata` (`line 659`)
- Added telemetry query params and required response keys (`/telemetry/dashboard` around `line 359`, schema around `line 608`).
- Added explicit duplicate primarch 409 response at step 4 endpoint.

### `council_contracts_v2_2.json`
- Strict role schema maintained with required `policy_checks` and `position` enum (`lines 24-58`).
- Economist extension required when role is Economist (`lines 61-95`).
- `recommended_action` now `string|null`.
- Noura final schema parity includes `contest_path`, `blocked_by_roles` (`lines 101-140`).
- Guardrails include `INVALID_ROLE_OUTPUT` and `COUNCIL_INCOMPLETE` (`lines 147-151`).

## WHY THIS SATISFIES V2.2 INVARIANTS
1. **event_log append-only**: enforced by trigger + privilege hardening (`sanctum_v2_2_runtime.sql` lines 347-370).
2. **governance-gated protected mutations**: boundary/lineage/policy update triggers require approved ticket.
3. **memory supersession integrity**: state transitions constrained and forward traversal cycle detection implemented.
4. **material actions require valid nonce**: creation/confirm flow enforces bound tuple, expiry, single-use, and exact error taxonomy.
5. **onboarding step order + bootstrap exception**: step functions enforce order; step1 owner bootstrap; post-step4 primarch gate.
6. **projection redaction**: role-aware filtering + sensitivity redaction + domain-scope filtering.
7. **council strict schemas + arbiter semantics**: codified in JSON schema + OpenAPI docs/structures.
8. **telemetry hard gate parity**: SQL fields and CI hard/warn thresholds aligned.

## FINAL INVARIANT COVERAGE MATRIX
| Invariant | Enforcing artifact |
|---|---|
| event_log append-only | `sanctum_v2_2_runtime.sql` trigger `deny_event_log_mutation` + triggers `trg_event_log_no_update/no_delete` |
| governance-gated mutations | `enforce_boundary_governance`, `enforce_lineage_governance`, `enforce_policy_governance` |
| memory supersession legality + no cycles | `enforce_memory_supersession` trigger |
| material-action nonce validity | `consent_nonces` indexes + `create_or_get_consent_nonce` + `confirm_material_action` |
| onboarding order + bootstrap | onboarding step functions + `onboarding_status` |
| projection redaction | `get_user_projection` role/scope logic |
| council strict schema + arbiter short-circuit contract | `council_contracts_v2_2.json` + `openapi_hgmoe_v2_2.yaml` evaluate docs/schemas |
| telemetry CI hard gates | `telemetry_pack_v2_1.sql` + `p0_ci_gate.ps1` |

## RESIDUAL RISKS / DEFERRED ITEMS
- `p0_db_checks.sql` checks #10/#11 validate persistence/contract primitives at DB level; full orchestration-path behavior still depends on API-layer tests (`p0_ci_gate.ps1` + optionally Newman).
- If API implementation maps DB exceptions to different HTTP status/code pairs, CI expected-code mapping must be kept synchronized.
- Optional hardening (deferred): separate role-based DB schemas/ownership for security definer functions.

## POST-APPLY VALIDATION

### SQL compile checks
```powershell
psql -v ON_ERROR_STOP=1 -f sanctum_v2_2_runtime.sql
psql -v ON_ERROR_STOP=1 -f telemetry_pack_v2_1.sql
psql -v ON_ERROR_STOP=1 -f p0_db_checks.sql
```

### Trigger/function smoke checks
```sql
SELECT proname FROM pg_proc WHERE proname IN (
  'create_or_get_consent_nonce',
  'confirm_material_action',
  'get_user_projection',
  'enforce_memory_supersession',
  'enforce_boundary_governance'
);
```

### API schema checks
- Validate `openapi_hgmoe_v2_2.yaml` with your OpenAPI linter.
- Validate `council_contracts_v2_2.json` with JSON Schema validator.

### P0 + telemetry gate run
```powershell
.\p0_ci_gate.ps1 -BaseUrl http://localhost:8080 -UserId <uuid> -PsqlExe psql -PsqlArgs "-v","ON_ERROR_STOP=1"
```

## READY FOR STAGING
**YES** (assuming runtime API implementation matches the updated OpenAPI and error-code mapping).
