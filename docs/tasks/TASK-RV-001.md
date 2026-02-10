# TASK-RV-001 — Revenue Fixture Pack and Deterministic Replay Runner

## Objective lane
Revenue Plane

## Goal (single measurable outcome)
Add a deterministic fixture pack and replay command that runs revenue scaffold tasks through `index.ps1` and validates expected status/output contract per fixture.

## Scope (allowed files)
- `apps/revenue_automation/fixtures/*.json`
- `apps/revenue_automation/scripts/replay_fixtures.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-001.md`
- `docs/phase1_revenue_scaffold.md`

## Non-goals
- No changes to release-gate runtime semantics, schema defaults, or control-plane tests.
- No live HTTP provider execution.
- No default flag changes (`enable_revenue_automation=false`, `safe_mode=true`, `dry_run=true`).
- No CI gating changes.

## Acceptance checklist
- [ ] Fixture envelopes added for known task types and at least one unknown task type.
- [ ] Replay script executes fixtures deterministically in safe/dry-run mode.
- [ ] Replay output includes per-fixture status and contract validation result.
- [ ] Existing revenue smoke suite remains green (no semantics drift).
- [ ] Existing control-plane suites remain unchanged and green.
- [ ] Phase 1 docs include fixture/replay usage and safety notes.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:
  - Added fixture set and replay script.
  - Updated smoke coverage and docs for deterministic replay path.

## Rollback anchor
- Tag: `phase1-revenue-scaffold-v0`

## Execution notes
- Local replay example:
  - `pwsh -File apps/revenue_automation/scripts/replay_fixtures.ps1 -ConfigPath apps/revenue_automation/config.example.json`
- Required validation:
  - `Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_staging_v2_3.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/run_release_candidate.Tests.ps1 -EnableExit`
  - `Invoke-Pester tests/release_gate_helpers.Tests.ps1 -EnableExit`
- Next first command:
  - `git diff --name-only --cached`
