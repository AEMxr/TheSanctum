# TASK-CP-012 - Cross-Language Trend Telemetry

## Objective lane
core-platform

## Goal (single measurable outcome)
Extend trend telemetry to segment performance by language and region so optimization can be done per-market.

## Scope (allowed files)
- `apps/core/telemetry/event_schema.json`
- `apps/core/telemetry/trend_aggregator.ps1`
- `apps/core/tests/trend_aggregator.Tests.ps1`
- `docs/tasks/TASK-CP-012.md`

## Non-goals
- No PII expansion.
- No geo precision below city/region/country.
- No edits outside scoped files.

## Acceptance checklist
- [ ] Event schema includes `language_code`, `region_code`, `geo_coarse`.
- [ ] Aggregator outputs conversion metrics by `(language_code, offer_tier, channel)`.
- [ ] Deterministic aggregation for repeated same dataset.
- [ ] Tests validate language-split metrics correctness.
- [ ] Scope validator PASS.
- [ ] 4-suite gate PASS.
- [ ] Exactly one commit.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
`rollback/TASK-CP-012-pre`

## Commit message (exact)
`feat(core): add cross-language trend telemetry segmentation (TASK-CP-012)`

## Execution notes
- Keep storage anonymized and consent-first.
- Reason codes example: `trend_lang_segmented`.
- Next first command: `Get-Content docs/tasks/TASK-CP-012.md -Raw`
