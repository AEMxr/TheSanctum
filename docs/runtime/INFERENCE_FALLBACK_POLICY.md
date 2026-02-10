# Inference Fallback Policy

## Purpose
Define local-first fallback behavior when runtime budgets are exceeded or local inference health degrades.

## Local-First Principle
1. Local inference is the default execution path.
2. Cloud fallback is allowed only under approved conditions.
3. Sensitive or restricted workloads remain local-only unless explicitly approved.

## Fallback Triggers
1. Runtime budget hard-limit breach from `RUNTIME_BUDGETS_GTX1660.md`.
2. Sustained degraded mode beyond approved time window.
3. Local dependency failure preventing safe execution.

## Approved Fallback Conditions
1. Task is explicitly marked fallback-eligible.
2. Safe mode policy allows remote execution for the task class.
3. Required approvals for tool/task risk tier are present.
4. Budget and cost ceilings for fallback path are defined.

## Deny Conditions
1. Missing fallback eligibility metadata.
2. Missing approval or policy mismatch.
3. Workload classified local-only by governance rule.
4. Missing encryption or transport integrity guarantees.

## Reversion Rules
1. Re-check local health at fixed intervals while on fallback path.
2. Revert to local execution only after:
   - budget compliance is restored,
   - local health checks pass,
   - no active deny condition exists.
3. Record fallback start, stop, and reversion reason in audit logs.

## Failure Handling
1. If both local and fallback paths are unavailable, fail closed with explicit error state.
2. Do not silently bypass guardrails to force completion.

## Governance Link
This policy is required by roadmap ops dependencies and must align with control-plane safety constraints.
