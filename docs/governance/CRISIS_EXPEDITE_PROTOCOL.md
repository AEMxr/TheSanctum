# Crisis / Expedite Protocol v1

## Purpose
Define a bounded emergency path for high-severity conditions without silent governance bypass.

## Trigger Conditions
Crisis mode can be activated only when at least one condition is true:
1. Active security compromise or credible exploit in progress.
2. Ongoing safety-impacting failure causing material harm risk.
3. Critical control-plane outage blocking recovery and safe operations.
4. Legal/regulatory deadline requiring immediate protective action.

## Activation Authority
Activation requires one of:
1. Primarch approval, or
2. Two-advisor emergency quorum (`Safety` + `Operations`) with immediate Primarch notification.

Activation must include:
1. `crisis_id`
2. trigger condition reference
3. proposed emergency actions
4. expected end time

## Allowed Actions
Allowed actions during crisis mode:
1. Temporary deny-default controls.
2. Scoped capability disablement.
3. Emergency rollback to last known safe baseline.
4. Temporary expedited policy application with explicit expiry.

Disallowed actions:
1. Permanent policy mutation without post-hoc review.
2. Unlogged manual bypass.
3. Broad privilege escalation without scope/time bounds.

## Duration Bounds and Auto-Expiry
1. Initial crisis window: `<= 4 hours`.
2. Extension requires explicit Primarch approval.
3. Maximum cumulative duration: `24 hours`.
4. Auto-expiry reverts system to standard governance flow if extension is not approved in time.

## Rollback Requirements
1. Every emergency action must include rollback steps before execution.
2. Rollback execution must be validated and logged.
3. If rollback validation fails, system remains in deny-default posture until verified.

## Mandatory Post-Hoc Review
Post-hoc review deadlines:
1. Initial incident summary within `24 hours` of crisis closure.
2. Full remediation and root-cause review within `5 business days`.

Required evidence:
1. timeline of actions
2. approvals and identities
3. impacted systems and blast radius
4. rollback verification results
5. follow-up preventive controls

## No-Silent-Bypass Rule
No crisis action is valid unless it is:
1. explicitly approved,
2. time-bounded,
3. logged with evidence,
4. linked to a post-hoc review record.

Any action failing these conditions is treated as invalid and denied.
