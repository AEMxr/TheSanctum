# TASK-AUD-001 - Post-sequence audit seal

## Objective lane
release-audit

## Goal (single measurable outcome)
Produce a single audit-seal document that verifies the full chain from TASK-RLS-002 through TASK-RV-001 with immutable references.

## Scope (allowed files)
- `docs/audit/AUDIT_CHAIN_SEAL_RLS002_to_RV001.md`
- `docs/tasks/TASK-AUD-001.md`
- `docs/roadmap/ROADMAP.md`

## Non-goals
- No edits outside the three scoped files.
- No code/test changes.
- No tag moves or branch surgery.
- No rewriting prior task docs.

## Acceptance checklist
- [x] `docs/audit/AUDIT_CHAIN_SEAL_RLS002_to_RV001.md` created with required seal content.
- [x] `docs/roadmap/ROADMAP.md` updated with a single Release/Ops dependency line referencing the audit seal doc.
- [x] `docs/tasks/TASK-AUD-001.md` updated/closed in task-card format.
- [x] Scope validator PASS for staged files vs TASK-AUD-001 card.
- [x] 4-suite gate all green:
  - [x] `tests/run_staging_v2_3.Tests.ps1`
  - [x] `tests/run_release_candidate.Tests.ps1`
  - [x] `tests/release_gate_helpers.Tests.ps1`
  - [x] `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- [x] One commit only.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
- `rollback/TASK-AUD-001-pre`

## Execution notes
- Keep wording factual and non-interpretive.
- Copy SHAs/messages exactly from established ledger entries.
- Reference prior artifacts only; do not modify them.
- Next first command: `Get-Content docs/tasks/TASK-AUD-001.md -Raw`
