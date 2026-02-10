# v2.4 Skeleton Plan

## Goal
Add reliability ergonomics without changing release-gate semantics.

## Scope
1. Reusable helper module for secret-arg parsing and reason ordering.
2. Summary schema version stamping for staging and RC summaries.
3. CI test-result export (NUnit XML) for contract suites.
4. Pure unit tests for helper behavior.

## Execution Order
1. Add `scripts/lib/release_gate_helpers.psm1`:
   - `Get-ReleaseGateSchemaVersion`
   - `ConvertTo-SecretArgArray`
   - `Get-OrderedUniqueReleaseGateReasons`
2. Wire `scripts/run_staging_v2_3.ps1`:
   - import helper module if present
   - use helper reason ordering
   - emit `summary_schema_version`
3. Wire `scripts/run_release_candidate.ps1`:
   - import helper module if present
   - emit `summary_schema_version`
4. Add `tests/release_gate_helpers.Tests.ps1`:
   - parser contract tests
   - reason ordering/dedupe test
   - schema version helper sanity test
5. Update `.github/workflows/release-gate-v2_3.yml`:
   - use `ConvertTo-SecretArgArray` in RC wrapper step
   - export NUnit XML test results for all suites
   - upload `artifacts/test-results/**`

## Non-goals
1. No changes to PASS/FAIL gate logic.
2. No changes to RC criteria definitions.
3. No branch-protection policy changes in code.
