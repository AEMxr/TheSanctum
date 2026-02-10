# Security Drill Calendar

## Purpose
Define recurring adversarial drill cadence, ownership, and evidence outputs to maintain measurable security readiness.

## Monthly Drill Cadence
1. Week 1 - Access abuse scenario:
   - Simulate unauthorized privilege escalation attempt.
   - Validate detection and containment path.
2. Week 2 - Data exfiltration scenario:
   - Simulate staged export from restricted domain.
   - Validate isolation boundaries and alerting response.
3. Week 3 - Service disruption scenario:
   - Simulate denial-of-service pressure on critical path.
   - Validate degradation and recovery procedures.
4. Week 4 - Supply-chain integrity scenario:
   - Simulate dependency tamper signal.
   - Validate quarantine and rollback readiness.

## Owners And Evidence
1. Drill owner must be assigned before execution.
2. Required evidence per drill:
   - drill id and timestamp
   - scenario and expected controls
   - observed outcomes
   - containment and recovery durations
   - remediation actions and due dates

## Recovery Targets
1. RTO target: <= 60 minutes for critical services.
2. RPO target: <= 15 minutes for critical operational data.
3. Any target breach requires formal remediation tracking.

## Validation Steps
1. Confirm scenario injection details are recorded.
2. Confirm containment actions were executed and timed.
3. Confirm recovery verification checks passed.
4. Confirm communication timeline was completed.

## Remediation Loop
1. Every drill produces remediation items with owners and deadlines.
2. Open remediation items are reviewed in the next drill cycle.
3. Repeated unresolved items escalate to governance review.

## Governance Link
This calendar provides resilience milestones referenced by roadmap operations dependencies.
