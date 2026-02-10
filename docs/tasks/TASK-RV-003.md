# TASK-RV-003 - Deterministic Lead Scoring + Routing

## Objective lane
revenue

## Goal (single measurable outcome)
Implement deterministic lead scoring and routing so the same fixture input always produces the same ranked output and route decision, with explicit reason codes.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-003.md`

## Non-goals
- No roadmap/governance/release checklist edits.
- No new external dependencies.
- No API contract/schema version changes.
- No changes outside scoped files.

## Acceptance checklist
- [ ] `task_router.ps1` exposes deterministic scoring function and deterministic route selection.
- [ ] Score output includes machine-readable reason codes (for auditability).
- [ ] Ties are resolved deterministically (stable sort + explicit tie-breaker).
- [ ] `index.ps1` consumes routing output without breaking existing execution flow.
- [ ] Smoke tests cover:
  - [ ] rank ordering stability
  - [ ] deterministic tie-break behavior
  - [ ] negative-path handling for malformed lead fixture
- [ ] Scope validator PASS against staged files and this task card.
- [ ] 4-suite gate PASS:
  - [ ] `tests/run_staging_v2_3.Tests.ps1`
  - [ ] `tests/run_release_candidate.Tests.ps1`
  - [ ] `tests/release_gate_helpers.Tests.ps1`
  - [ ] `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- [ ] Exactly one commit.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
`rollback/TASK-RV-003-pre`

## Execution notes
- Determinism requirement: no randomness; if score equal, tie-break by fixed key order (e.g., `lead_id` ascending).
- Reason codes should be concise, stable strings (e.g., `fit_segment`, `pain_match`, `budget_ok`, `low_signal`).
- Next first command: `Get-Content docs/tasks/TASK-RV-003.md -Raw`
