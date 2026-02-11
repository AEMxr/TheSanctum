# TASK-API-006 - Deterministic Language Detection Contract

## Objective lane
api

## Goal (single measurable outcome)
Add a deterministic language-detection API contract so each inbound context (post/thread/message) resolves to a stable `detected_language` and confidence band.

## Scope (allowed files)
- `apps/api/src/contracts/language_detection.contract.json`
- `apps/api/src/index.ps1`
- `apps/api/tests/api.contract.Tests.ps1`
- `docs/tasks/TASK-API-006.md`

## Non-goals
- No external paid translation services.
- No changes outside scoped files.
- No schema version bump outside this contract.
- No release-gate semantic changes.

## Acceptance checklist
- [ ] Contract defines: `input_text`, `source_channel`, `detected_language`, `confidence_band`, `reason_codes`.
- [ ] Confidence band deterministic enum: `low|medium|high`.
- [ ] Unknown/ambiguous language falls back to `und` with stable reason code.
- [ ] API tests validate deterministic output for repeated same input.
- [ ] Scope validator PASS.
- [ ] 4-suite gate PASS.
- [ ] Exactly one commit.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
`rollback/TASK-API-006-pre`

## Commit message (exact)
`feat(api): add deterministic language detection contract (TASK-API-006)`

## Execution notes
- No randomness/time-based branching.
- Stable reason codes, e.g., `lang_detect_high_conf`, `lang_detect_ambiguous`, `lang_detect_unknown`.
- Next first command: `Get-Content docs/tasks/TASK-API-006.md -Raw`
