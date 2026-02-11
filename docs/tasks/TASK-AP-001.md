# TASK-AP-001 - Harmonize dual-API runtime health contracts

## Objective lane
ops

## Goal (single measurable outcome)
Both APIs can boot with deterministic config defaults and expose stable readiness/health payload shape for automation checks.

## Scope (allowed files)
- `apps/revenue_automation/src/index.ps1`
- `apps/api/src/index.ps1`
- `apps/api/tests/api.contract.Tests.ps1`
- `docs/tasks/TASK-AP-001.md`

## Non-goals
- No business logic changes to task routing.
- No release-gate semantic changes.
- No edits outside scoped files.

## Acceptance checklist
- [ ] Both API entrypoints expose deterministic health/readiness payload keys.
- [ ] `apps/api` contract tests cover the updated health/readiness shape.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary: dual-API health contract alignment.

## Rollback anchor
`rollback/TASK-AP-001-pre`

## Commit message (exact)
`feat(ops): harmonize dual-api runtime health contracts (TASK-AP-001)`

## Execution notes
- Next first command: `Get-Content docs/tasks/TASK-AP-002.md -Raw`
