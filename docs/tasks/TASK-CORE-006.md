# TASK-CORE-006
## Title
Context-Scoped Policy Guard Engine (Hard Caps + Cooldowns + Deny Reasons)

## Objective lane
control-plane / core

## Goal (single measurable outcome)
Implement deterministic policy guardrails that cap actions by context bucket (NOT global cap), with explicit deny reason codes and cooldown windows.

## Scope (allowed files)
- `apps/revenue_automation/src/lib/task_router.ps1`
- `apps/revenue_automation/src/index.ps1`
- `apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1`
- `docs/tasks/TASK-CORE-006.md`

## Non-goals
- No release-gate runtime semantics changes.
- No schema/version changes.
- No changes outside scoped files.

## Acceptance checklist
- [ ] Add deterministic policy evaluation with context key:
  - [ ] `platform|account_id|community_id|action_type|window`
- [ ] Enforce context-scoped limits (no global cap).
- [ ] Enforce cooldown checks per context.
- [ ] Deterministic deny reasons implemented:
  - [ ] `policy_denied_context_cap`
  - [ ] `policy_denied_cooldown`
  - [ ] `policy_denied_missing_context`
- [ ] Route output includes `policy = { allowed, context_key, reason_codes[] }`.
- [ ] Preserve backward compatibility of existing output fields.
- [ ] Tests cover context cap/cooldown/independent communities/determinism.
- [ ] Scope validator PASS.
- [ ] 4-suite gate PASS.
- [ ] Exactly one commit.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
rollback/TASK-CORE-006-pre

## Execution notes
- Deterministic only; no randomness or wall-clock branching.
- Next first command: `Get-Content docs/tasks/TASK-RV-006.md -Raw`
