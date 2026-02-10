# TASK-RV-002 - Revenue Fixture Expansion + Negative-Path Assertions

## Objective lane
Revenue Plane

## Goal (single measurable outcome)
Expand deterministic fixture coverage (including failure/edge contracts) and assert negative-path behavior without changing default-off safety model.

## Scope (allowed files)
- `apps/revenue_automation/fixtures/*.json`
- `apps/revenue_automation/scripts/replay_fixtures.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-002.md`
- `docs/phase1_revenue_scaffold.md`

## Non-goals
- No release-gate runtime semantics or control-plane schema changes.
- No changes to default flags:
  - `enable_revenue_automation=false`
  - `safe_mode=true`
  - `dry_run=true`
- No live HTTP provider execution requirement.
- No CI gating topology changes.

## Acceptance checklist
- [ ] Add fixtures covering at least:
  - known task success path(s)
  - unknown task type (SKIPPED contract)
  - malformed/invalid envelope negative-path case(s)
  - missing required field negative-path case(s)
- [ ] Replay runner reports deterministic per-fixture contract validation and status expectations.
- [ ] Replay runner exits non-zero when any fixture violates contract/expected result.
- [ ] Revenue smoke tests assert negative-path outcomes explicitly.
- [ ] Phase 1 revenue doc includes fixture categories and failure semantics.
- [ ] All required suites remain green with control-plane behavior unchanged.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- Tag: `phase1-revenue-scaffold-v0`

## Execution notes
- Validate staged scope first:
  - `git diff --name-only --cached`
  - `pwsh -File scripts/dev/validate_task_scope.ps1 -TaskFile docs/tasks/TASK-RV-002.md -ChangedFiles <cached_files>`
- Run local replay:
  - `pwsh -File apps/revenue_automation/scripts/replay_fixtures.ps1 -ConfigPath apps/revenue_automation/config.example.json -FixturesDir apps/revenue_automation/fixtures`
- Run required suites:
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
- Next first command:
  - `git diff --name-only --cached`
