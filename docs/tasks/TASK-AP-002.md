# TASK-AP-002 - Add zero-touch dual-API start/stop scripts

## Objective lane
ops

## Goal (single measurable outcome)
Provide scripts that start and stop both APIs deterministically so operators can run both without manual sequencing.

## Scope (allowed files)
- `scripts/dev/start_both_apis.ps1`
- `scripts/dev/stop_both_apis.ps1`
- `scripts/dev/wait_for_health.ps1`
- `docs/tasks/TASK-AP-002.md`

## Non-goals
- No API business logic changes.
- No release-gate semantic changes.
- No edits outside scoped files.

## Acceptance checklist
- [ ] Start script launches both APIs and waits for readiness.
- [ ] Stop script shuts down both APIs idempotently.
- [ ] Health wait script uses deterministic retries/timeout and stable exit codes.
- [ ] Exactly one implementation commit uses the exact commit message below.

## Deliverables (SHA, diff summary)
- Commit SHA(s): recorded at closeout.
- Diff summary: dual-API lifecycle scripts added.

## Rollback anchor
`rollback/TASK-AP-002-pre`

## Commit message (exact)
`feat(ops): add zero-touch dual-api start stop scripts (TASK-AP-002)`

## Execution notes
- Next first command: `Get-Content docs/tasks/TASK-AP-003.md -Raw`
