# Agent Tool Risk Matrix

## Purpose
Define deterministic risk tiers for agentic tool execution and map each tier to approval requirements and execution constraints.

## Risk Tier Definitions
1. Tier 0 - Read-only:
   - Data retrieval and static analysis.
   - No write side effects.
2. Tier 1 - Transactional reversible:
   - Writes that can be safely rolled back with a deterministic procedure.
   - Limited operational impact when reverted quickly.
3. Tier 2 - Transactional irreversible:
   - Writes or actions that cannot be fully reversed.
   - High operational, financial, or compliance impact.

## Tier Mapping Rules
1. Unknown tools default to Tier 2 until explicitly classified.
2. A tool with mixed behavior is classified at its highest-risk behavior.
3. Cross-domain tools inherit the stricter tier among all touched domains.

## Approval Requirements
1. Tier 0:
   - Single operator approval.
   - No council quorum required.
2. Tier 1:
   - Two-party approval (operator plus reviewer).
   - Execution window and rollback plan must be recorded.
3. Tier 2:
   - Council quorum approval required.
   - Primarch acknowledgement required for production execution.
   - Explicit deny conditions reviewed before execution.

## Execution Caps By Tier
1. Tier 0:
   - Time cap: 15 minutes.
   - Spend cap: 0 external spend.
2. Tier 1:
   - Time cap: 30 minutes.
   - Spend cap: bounded per task card budget.
3. Tier 2:
   - Time cap: task-specific and pre-approved.
   - Spend cap: pre-approved hard ceiling with auto-stop trigger.

## Escalation And Audit
1. Any cap breach escalates immediately to stop state.
2. Any approval mismatch results in deny state.
3. Every execution must emit an audit entry with tool, tier, approvers, and outcome.

## Governance Link
This matrix is required input for tool execution guardrails and roadmap governance dependency checks.
