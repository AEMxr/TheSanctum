# STAGING_EVIDENCE_v2_3

HG-MoE v2.3 Staging Gate Execution Report

- Date (local): `2026-02-09T00:36:48.3391701-08:00`
- Executor: Codex (real local execution in this workspace)
- Gate verdict: **FAIL**
- Recommended tag: **v2.3-rc1-blocked**

## Environment facts
- `psql`: missing
- `newman`: missing
- API base used: `http://localhost:8080` (unreachable in this environment)
- User id used: `719b86b7-7467-4f94-8eb9-23d6a7077410`

## Generated artifacts
- `db_verification_results.sql.out` (contains command-not-found errors for psql)
- `p0_gate_console.out` (full gate console output)
- `p0_gate_results.json` (derived from real console output)
- `telemetry_before.json` / `telemetry_after.json` (real request failure captures)
- `api_negative_tests.json` (real failed request captures, no simulated pass claims)
- `newman_summary.json` (captures missing newman failure)
- `checksums.txt` (generated after artifact creation)

## Blocking cause
- Missing DB/API/Newman runtime capabilities in this machine/session; cannot produce passing staging evidence.
