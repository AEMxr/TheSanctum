# TASK-RV-006 - Language + Marketing API Finish Closeout

## Objective lane
revenue

## Goal (single measurable outcome)
Finalize TASK-RV-006 process evidence by recording the deterministic Language API + Marketing API finish commits, verification gates, and rollback anchor in one task card.

## Scope (allowed files)
- `docs/tasks/TASK-RV-006.md`

## Non-goals
- No product/runtime logic changes.
- No release-gate semantic changes.
- No schema version changes.
- No edits outside scoped files.

## Acceptance checklist
- [x] Language API finish commit recorded:
  - [x] `cc84ed8bc2549265b8892fcaa877b0bdb514158f`
- [x] Marketing API finish commit recorded:
  - [x] `a664b925285380a613eaf4679bc9cc458ab7b72c`
- [x] Gate suite snapshot included for verification rerun:
  - [x] `tests/run_staging_v2_3.Tests.ps1`
  - [x] `tests/run_release_candidate.Tests.ps1`
  - [x] `tests/release_gate_helpers.Tests.ps1`
  - [x] `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
  - [x] `apps/api/tests/api.contract.Tests.ps1`
- [x] Exactly one docs-only commit for card closeout.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
  - `cc84ed8bc2549265b8892fcaa877b0bdb514158f` — `feat(api): add deterministic language conversion modes and contract outputs`
  - `a664b925285380a613eaf4679bc9cc458ab7b72c` — `feat(revenue): finalize deterministic marketing response contract and telemetry-safe output`
- Diff summary:
  - Language API: mode contract (`detect|convert|detect_and_convert`), deterministic conversion/fallback reason codes, mode coverage tests.
  - Marketing API: explicit proposal/template/variant lineage fields and telemetry-safe stub output.

## Rollback anchor
`rollback/TASK-RV-006-pre`

## Commit message (exact)
`docs(tasks): finalize TASK-RV-006 closeout and verification snapshot`

## Execution notes
- Verification snapshot (post-finish rerun):
  - `tests/run_staging_v2_3.Tests.ps1`: Passed 18, Failed 0
  - `tests/run_release_candidate.Tests.ps1`: Passed 8, Failed 0
  - `tests/release_gate_helpers.Tests.ps1`: Passed 10, Failed 0
  - `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`: Passed 26, Failed 0
  - `apps/api/tests/api.contract.Tests.ps1`: Passed 10, Failed 0
- Release-gate behavior unchanged.
- Next first command: `Get-Content docs/tasks/TASK-RV-007.md -Raw`
