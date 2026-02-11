# TASK-CP-011 - Localization Profile Registry (Language + Market Rules)

## Objective lane
core-platform

## Goal (single measurable outcome)
Create a deterministic localization profile registry that maps language/market to tone, prohibited phrasing, CTA style, and fallback rules.

## Scope (allowed files)
- `apps/core/localization/localization_profiles.json`
- `apps/core/localization/profile_resolver.ps1`
- `apps/core/tests/localization_profiles.Tests.ps1`
- `docs/tasks/TASK-CP-011.md`

## Non-goals
- No automatic posting logic changes.
- No legal-policy engine changes.
- No edits outside scoped files.

## Acceptance checklist
- [ ] Profiles exist for at least: `en`, `es`, `pt`, `fr`, `de`.
- [ ] Resolver returns deterministic profile by `(language, region)` with fallback chain.
- [ ] Each profile contains: `tone_style`, `cta_style`, `prohibited_patterns`, `default_currency`, `reason_codes`.
- [ ] Tests verify fallback determinism (`es-MX -> es`, etc).
- [ ] Scope validator PASS.
- [ ] 4-suite gate PASS.
- [ ] Exactly one commit.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
`rollback/TASK-CP-011-pre`

## Commit message (exact)
`feat(core): add deterministic localization profile registry and resolver (TASK-CP-011)`

## Execution notes
- Keep profile keys stable.
- Add reason codes like `profile_exact_match`, `profile_language_fallback`, `profile_global_fallback`.
- Next first command: `Get-Content docs/tasks/TASK-CP-011.md -Raw`
