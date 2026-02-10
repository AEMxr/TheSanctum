# Tool Execution Guardrails

## Purpose
Define hard stop conditions, escalation paths, and runtime controls for agentic tool execution.

## Core Guardrails
1. Deny by default when tool tier or approval state is unknown.
2. Enforce pre-execution checks for tier, approvers, budget caps, and time caps.
3. Stop execution immediately on policy violation signals.

## Deny Conditions
1. Missing required approvals for tool tier.
2. Missing or invalid rollback plan for Tier 1 and Tier 2.
3. Missing budget ceiling for spend-capable operations.
4. Tool requested outside declared task scope.

## Auto-Stop Triggers
1. Runtime exceeds approved time cap.
2. Spend exceeds approved spend cap.
3. Execution crosses declared domain boundary without approval.
4. Security anomaly or integrity check failure is detected.

## Escalation Path
1. Initial stop event:
   - Mark execution as FAILED_STOPPED.
   - Preserve logs and partial artifacts.
2. Escalate to on-duty control-plane reviewer.
3. Tier 2 events escalate to council and Primarch review queue.
4. Recovery execution requires explicit re-authorization.

## Safe Execution Requirements
1. All execution modes must support dry-run when configured.
2. Safe mode must block irreversible operations unless explicitly disabled by approved policy path.
3. Guardrail bypass attempts are logged as policy violations.

## Audit Requirements
1. Record task id, tool id, tier, approvers, start/finish times, and stop reasons.
2. Store denial and stop events with evidence pointers.
3. Publish post-run summary for governance review.

## Governance Link
These guardrails operationalize the agent tool risk matrix and are mandatory for governance-safe tool execution.
