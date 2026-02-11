# TASK-AP-003 - Add dual-API smoke and one-command run-all entrypoint

## Objective lane
ops

## Goal (single measurable outcome)
A single command validates that both APIs are up and serving expected minimal contracts.

## Scope (allowed files)
- `tests/both_apis.smoke.Tests.ps1`
- `scripts/dev/run_both_apis_smoke.ps1`
- `apps/api/tests/api.contract.Tests.ps1`
- `docs/tasks/TASK-AP-003.md`

## Non-goals
- No revenue task-routing logic changes.
- No release-gate semantic changes.
- No edits outside scoped files.

## Acceptance checklist
- [ ] Smoke tests validate both APIs are reachable and return minimal contract keys.
- [ ] Run-all script executes start/wait/smoke/stop deterministically.
- [ ] Existing API contract tests remain green.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary: dual-API smoke and run-all entrypoint added.

## Rollback anchor
`rollback/TASK-AP-003-pre`

## Commit message (exact)
`test(ops): add dual-api smoke and run-all entrypoint (TASK-AP-003)`

## Execution notes
- Next first command: `Get-ChildItem docs/tasks/TASK-*.md | Sort-Object Name`
