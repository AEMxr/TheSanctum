# Phase 1 Revenue Scaffold

## Purpose
This scaffold introduces a feature-flagged revenue automation runtime contract and provider abstraction without changing release-gate control-plane behavior.

## Non-goals
1. No changes to release-gate semantics.
2. No schema default changes for release summaries.
3. No live external HTTP execution in safe scaffold mode.

## Runtime Entry
Run locally:

```powershell
pwsh -File apps/revenue_automation/src/index.ps1 -ConfigPath apps/revenue_automation/config.example.json -TaskPath <task-envelope.json>
```

## Deterministic Fixture Replay
Replay the fixture pack through the runtime contract:

```powershell
pwsh -File apps/revenue_automation/scripts/replay_fixtures.ps1 -ConfigPath apps/revenue_automation/config.example.json -FixturesDir apps/revenue_automation/fixtures
```

Fixture replay writes a summary JSON to `apps/revenue_automation/artifacts/replay/replay_summary.json` by default and exits non-zero if any fixture fails contract or expected status checks.

Fixture categories in `apps/revenue_automation/fixtures`:
1. Known success paths (`lead_enrich`, `followup_draft`, `calendar_proposal`) expected `SUCCESS`.
2. Unsupported task type expected `SKIPPED`.
3. Invalid envelope cases (for example invalid `created_at_utc`) expected `FAILED`.
4. Missing required field cases (for example missing `payload`) expected `FAILED`.

Failure semantics:
1. Replay is deterministic and evaluates each fixture against expected status and expected exit code.
2. A fixture fails replay when output contract is invalid, status mismatches, or exit code mismatches.
3. Any failing fixture makes replay exit non-zero to prevent silent drift.

## Safety Model
1. `enable_revenue_automation` is `false` by default.
2. `safe_mode=true` prevents HTTP provider execution.
3. `dry_run=true` avoids live side-effect execution paths.
4. Telemetry writing is best-effort and non-fatal.
5. Fixture replay always enforces `safe_mode=true` and `dry_run=true` at runtime.

## Input Contract
Task envelope JSON fields:
1. `task_id` (string)
2. `task_type` (string)
3. `payload` (object)
4. `created_at_utc` (ISO8601 string)

## Output Contract
Result JSON fields:
1. `task_id`
2. `status` (`SUCCESS|FAILED|SKIPPED`)
3. `provider_used`
4. `started_at_utc`
5. `finished_at_utc`
6. `duration_ms`
7. `error` (nullable)
8. `artifacts` (array of strings)

## Independence Note
This scaffold is independent from the release-gate control plane and is additive only.
