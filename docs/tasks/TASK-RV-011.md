# TASK-RV-011 - Language-Aware Offer Variant Selection

## Objective lane
revenue

## Goal (single measurable outcome)
Select offer/ad variant deterministically by language-market performance bands, not one-size-fits-all copy.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/variant_selector.ps1`
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-RV-011.md`

## Non-goals
- No ML model training in this task.
- No live posting.
- No edits outside scoped files.

## Acceptance checklist
- [ ] Selector input includes language/region + trend summary.
- [ ] Output includes `selected_variant_id`, `selection_reason_codes`, `confidence_band`.
- [ ] Deterministic tie-break rules documented and tested.
- [ ] Tests verify different language segments can choose different variants.
- [ ] Scope validator PASS.
- [ ] 4-suite gate PASS.
- [ ] Exactly one commit.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
`rollback/TASK-RV-011-pre`

## Commit message (exact)
`feat(revenue): add language-aware deterministic offer variant selection (TASK-RV-011)`

## Execution notes
- Stable tie-break key order required.
- Reason codes: `variant_lang_perf_win`, `variant_lang_tiebreak`.
- Next first command: `Get-Content docs/tasks/TASK-RV-011.md -Raw`
