# Roadmap

## Purpose
Track lane-specific delivery while preserving release-gate and execution-governance invariants.

## Active Control-Plane Priorities
1. Maintain release-gate immutability and schema stability.
2. Enforce deterministic scope validation before tests.
3. Keep task execution/reporting contract normalized and auditable.

## Governance Dependencies
1. `docs/governance/COUNCIL_ARBITRATION_SPEC.md` defines deterministic council conflict resolution, deadlock handling, and Primarch override semantics.
2. Governance tasks must preserve deterministic deny/invalid states and explicit escalation paths.
3. `docs/governance/CRISIS_EXPEDITE_PROTOCOL.md` and `docs/governance/GOVERNANCE_CHANGE_CONTROL.md` define bounded emergency flow, no-silent-bypass rules, and mandatory post-hoc review obligations.
4. `docs/data/MEMORY_GOVERNANCE_AND_DRIFT_CONTROL.md` and `docs/data/TRAINING_LINEAGE_STANDARD.md` define memory promotion, contradiction quarantine, and lineage gates required before training-candidate promotion.
5. `docs/security/LINEAGE_PRODUCT_ISOLATION_POLICY.md` and `docs/security/KEY_DOMAIN_SEPARATION.md` enforce lineage/product trust boundaries and key-domain separation requirements for governance-safe evolution.
6. `docs/governance/AGENT_TOOL_RISK_MATRIX.md` and `docs/governance/TOOL_EXECUTION_GUARDRAILS.md` define tool-tier approvals, deny conditions, and auto-stop escalation controls.
7. `docs/governance/POLICY_LIFECYCLE_AND_MUTATION_CONTROLS.md` defines signed lifecycle hard gates for policy mutation and release eligibility.

## Active Revenue Priorities
1. Keep revenue automation default-off and safe by default.
2. Expand deterministic fixture coverage for contract reliability.
3. Preserve non-gating posture for scaffold checks.
4. Apply weekly API factory monetization using:
   - `docs/revenue/API_REVENUE_PLAYBOOK_v1.md`
   - `docs/revenue/PRICING_GUARDRAILS.md`

## Release and Ops Interface Dependencies
1. `docs/tasks/TASK_EXECUTION_STANDARD.md` is the canonical execution contract.
2. `docs/release_promotion_checklist.md` must stay aligned with:
   - mandatory scope validation
   - required 4-suite Pester gate
   - drift and rollback-anchor reporting
3. `docs/runtime/RUNTIME_BUDGETS_GTX1660.md` and `docs/runtime/INFERENCE_FALLBACK_POLICY.md` define enforceable local runtime limits and approved fallback/reversion controls.
4. `docs/security/SECURITY_DRILL_CALENDAR.md` and `docs/security/INCIDENT_RESPONSE_RUNBOOK.md` define recurring resilience drills, recovery targets, and incident-response execution standards.
5. Policy mutation lifecycle verification is a release hard gate for governance-affecting changes.
6. `docs/audit/AUDIT_CHAIN_SEAL_RLS002_to_RV001.md` seals deterministic chain evidence for TASK-RLS-002 through TASK-RV-001.

## Current Sequence Anchor
`TASK-RLS-002` establishes normalized execution and reporting semantics before subsequent governance, ops, and revenue card execution.
