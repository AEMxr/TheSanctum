# TASK-CP-004 - Session Log Integrity + Next-Command Enforcement

## Objective lane
Control Plane

## Goal (single measurable outcome)
Require session-log integrity for changed control-plane work by validating presence of a "Next first command" entry format.

## Scope (allowed files)
- `scripts/dev/validate_task_scope.ps1`
- `docs/tasks/TASK-CP-004.md`
- `docs/session_log.md`
- `docs/checklists/pre_commit_drift_alarm.md`

## Non-goals
- No release-gate runtime semantics changes.
- No schema/version changes.
- No CI workflow changes.
- No revenue-plane behavior changes.

## Acceptance checklist
- [ ] Validator checks changed `docs/session_log.md` entries for a non-empty `Next first command:` line.
- [ ] Validator fails non-zero if `Next first command:` is missing/blank in changed log entry blocks.
- [ ] Validator output identifies the offending file and entry context.
- [ ] Checklist includes explicit session-log integrity confirmation.
- [ ] Existing suites remain green and unchanged semantically.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- Tag: `control-plane-scope-guard-v1`

## Execution notes
- Validate staged scope first:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-CP-004.md -ChangedFiles <cached_files>`
- Run required suites:
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
- Next first command:
  - `git diff --name-only --cached`
