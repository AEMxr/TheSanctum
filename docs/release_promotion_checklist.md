# Release Promotion Checklist (v2.3)

## Purpose
Promote only when staging evidence is real, complete, and clean under strict gate semantics.

## Preconditions
1. Use a clean runner/shell session (no stale artifacts from prior failed runs).
2. Required tools on PATH:
   - `powershell` or `pwsh`
   - `psql`
   - `newman`
3. Required source artifacts present in the evidence directory:
   - `p0_ci_gate.ps1`
   - `p0_db_checks.sql`
   - `preflight_env.ps1`
   - `verify_evidence.ps1`
   - `sanctum_v2_2_runtime.sql`
   - `openapi_hgmoe_v2_2.yaml`
   - `council_contracts_v2_2.json`
   - `STAGING_EVIDENCE_v2_3.md`
4. Runtime dependencies reachable:
   - API health endpoint responds at `<BaseUrl>/health`
   - DB is reachable with the same `psql` args used by the gate

## Pre-run Sanity Checks
```powershell
Get-Command psql,newman | Select-Object Name,Source
Invoke-RestMethod -Method GET -Uri "<BaseUrl>/health" -TimeoutSec 10
```

## Promotion Run
Run the release-candidate wrapper from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_release_candidate.ps1 `
  -BaseUrl "<BaseUrl>" `
  -EvidenceDir "." `
  -UserId "<stable-user-id>" `
  -ApiKey "<optional-bearer-token>" `
  -PsqlExe "psql" `
  -PsqlArgs @("<db-arg-1>", "<db-arg-2>") `
  -NewmanExe "newman" `
  -PostmanCollection ".\collection.json"
```

Note: CI secret parsing for `PSQL_ARGS` is intentionally non-quote-aware in whitespace mode. Use JSON-array form for values containing spaces (example: `["-h","db local","-U","svc"]`).

## Required Promotion Outcome
Promotion is valid only if all are true:
1. Process exit code is `0`.
2. `run_staging_summary.json`:
   - `release_decision == "PASS"`
   - `strict_release_gate_ready == true`
   - `used_fallback_artifacts == false`
   - `release_gate_reason` is empty
3. `verify_evidence_report.strict.json`:
   - `verdict == "RC-STAGING-READY"`
   - `blocker_count == 0`

## Task Execution and Reporting Gate (Required)
Before final promotion sign-off for a task-driven change set:
1. Scope validator must pass against the active task card and staged files.
2. The required 4-suite gate must pass:
   - `tests/run_staging_v2_3.Tests.ps1`
   - `tests/run_release_candidate.Tests.ps1`
   - `tests/release_gate_helpers.Tests.ps1`
   - `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
3. Completion report must include:
   - task ID
   - commit SHA
   - exact changed files
   - scope validator result
   - 4-suite pass/fail counts
   - drift status
   - rollback anchor used
   - next first command

## Evidence Bundle (Archive Canonical Pass)
Archive at least:
1. `run_staging_summary.json`
2. `run_release_candidate_summary.json`
3. `verify_evidence_report.strict.json`
4. `p0_gate_results.json`
5. `db_verification_results.sql.out`
6. `newman_summary.json` or `newman_results.xml`
7. `telemetry_before.json`
8. `telemetry_after.json`
9. `api_negative_tests.json`
10. `checksums.txt`
11. `artifacts/toolchain_manifest.txt`
12. `artifacts/logs/*`

## Tagging Guidance
After a canonical clean pass bundle is archived:
1. Tag release candidate (example): `v2.3-rc1`
2. Link archived evidence bundle in release notes/change ticket
3. Record timestamp and runner identity used for the pass

## Immutable Evidence Manifest (Release Notes)
For each promoted RC, include this immutable manifest line set:
1. `git_commit_sha`: full commit SHA promoted
2. `workflow_run_id`: CI run identifier
3. `artifact_name_windows-powershell-5_1`: uploaded artifact bundle name
4. `artifact_name_windows-pwsh-7`: uploaded artifact bundle name
5. `checksums_sha256`: SHA256 of `checksums.txt`

Example:
```text
git_commit_sha=<40-char-sha> workflow_run_id=<id> artifact_name_windows-powershell-5_1=release-gate-evidence-windows-powershell-5_1 artifact_name_windows-pwsh-7=release-gate-evidence-windows-pwsh-7 checksums_sha256=<sha256>
```

## Branch Protection Recommendation
Require both status checks for merge:
1. `release-gate (windows-powershell-5_1)`
2. `release-gate (windows-pwsh-7)`
