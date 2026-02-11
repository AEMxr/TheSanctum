# TASK-RV-010 - Multilingual Ad/Reply Template Engine

## Objective lane
revenue

## Goal (single measurable outcome)
Generate deterministic multilingual ad and reply templates per offer tier using localization profiles and language detection output.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/multilingual_templates.ps1`
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-010.md`

## Non-goals
- No live posting/integration changes.
- No external translation API dependency.
- No edits outside scoped files.

## Acceptance checklist
- [ ] For successful campaign/proposal paths, output includes localized:
  - [ ] `ad_copy`
  - [ ] `short_reply_templates[]`
  - [ ] `cta_buy_text`
  - [ ] `cta_subscribe_text`
- [ ] Determinism: same input language/profile => byte-equivalent template payload.
- [ ] Fallback to English profile when language unsupported, with reason code.
- [ ] Tests cover at least one non-English path (`es`) and one fallback path.
- [ ] Scope validator PASS.
- [ ] 4-suite gate PASS.
- [ ] Exactly one commit.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
`rollback/TASK-RV-010-pre`

## Commit message (exact)
`feat(revenue): add deterministic multilingual ad and reply templating (TASK-RV-010)`

## Execution notes
- Stable reason codes: `template_lang_native`, `template_lang_fallback_en`.
- Localization profile resolution reason codes are preserved in proposal/template lineage.
- Keep existing route/offer/proposal fields backward-compatible.
- Next first command: `Get-Content docs/tasks/TASK-RV-010.md -Raw`
