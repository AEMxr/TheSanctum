# Roadmap

## Purpose
Track lane-specific delivery while preserving release-gate and execution-governance invariants.

## Active Control-Plane Priorities
1. Maintain release-gate immutability and schema stability.
2. Enforce deterministic scope validation before tests.
3. Keep task execution/reporting contract normalized and auditable.

## Active Revenue Priorities
1. Keep revenue automation default-off and safe by default.
2. Expand deterministic fixture coverage for contract reliability.
3. Preserve non-gating posture for scaffold checks.

## Release and Ops Interface Dependencies
1. `docs/tasks/TASK_EXECUTION_STANDARD.md` is the canonical execution contract.
2. `docs/release_promotion_checklist.md` must stay aligned with:
   - mandatory scope validation
   - required 4-suite Pester gate
   - drift and rollback-anchor reporting

## Current Sequence Anchor
`TASK-RLS-002` establishes normalized execution and reporting semantics before subsequent governance, ops, and revenue card execution.
