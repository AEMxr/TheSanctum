# Council Arbitration Specification v1

## Purpose
Define deterministic conflict resolution when council advisors return divergent recommendations.

## Roles
1. Advisory council roles:
   - Strategy advisor
   - Safety advisor
   - Operations advisor
2. Final authority:
   - Primarch

Advisory roles can recommend and score. Advisory roles cannot finalize execution decisions.

## Decision Inputs
Each advisor output must include:
1. `proposal_id` (stable identifier)
2. `decision` (`APPROVE`, `DENY`, `REVISE`)
3. `confidence` (`0.0` to `1.0`)
4. `risk_level` (`LOW`, `MEDIUM`, `HIGH`, `CRITICAL`)
5. `rationale` (non-empty text)
6. `constraints` (array; may be empty)

Invalid advisor outputs are excluded from scoring and recorded as `INVALID_INPUT`.

## Weighted Scoring Rubric
Aggregate score is computed per proposal:
1. Strategy advisor weight: `0.35`
2. Safety advisor weight: `0.40`
3. Operations advisor weight: `0.25`

Normalization:
1. `APPROVE` contributes `+1`
2. `REVISE` contributes `0`
3. `DENY` contributes `-1`
4. Contribution is multiplied by advisor weight and confidence.

Result:
1. `score >= 0.30` and no `CRITICAL` risk -> `APPROVE`
2. `-0.30 < score < 0.30` -> `REVISE`
3. `score <= -0.30` -> `DENY`

## Deterministic Tie-Break Rules
If score is exactly on boundary or outcomes conflict:
1. Safety-first rule:
   - Any valid `DENY` with `CRITICAL` risk forces `DENY`.
2. If no safety-forced deny, highest-confidence advisor among non-invalid inputs wins.
3. If confidence tie remains, advisor precedence applies:
   - Safety > Operations > Strategy.
4. If still tied, default to `REVISE`.

## Deadlock Timeout and Escalation
Deadlock is defined as unresolved outcome after scoring + tie-break.

Timeout:
1. Arbitration timeout: `300` seconds from arbitration start.

Escalation chain:
1. Escalate to Primarch with full advisor evidence bundle.
2. Primarch must choose one of:
   - `APPROVE_WITH_CONSTRAINTS`
   - `REVISE`
   - `DENY`
3. If Primarch decision is not issued within timeout extension (`120` seconds), force `DENY`.

## Primarch Override Semantics
Primarch override is final for the arbitration event and must include:
1. `override_reason` (required)
2. `applied_constraints` (required; may be empty only for `DENY`)
3. `audit_trace_id` (required)

Override does not bypass logging, evidence generation, or post-hoc review obligations.

## Deny and Invalid States
Terminal deny states:
1. `DENY_BY_SCORE`
2. `DENY_BY_CRITICAL_RISK`
3. `DENY_BY_TIMEOUT`
4. `DENY_BY_OVERRIDE`

Invalid states:
1. `INVALID_INPUT` (advisor payload missing required fields)
2. `INVALID_DECISION_VALUE` (decision outside `APPROVE|DENY|REVISE`)
3. `INVALID_CONFIDENCE` (outside `0..1`)
4. `INVALID_RISK_LEVEL` (outside defined enum)

Invalid states must not silently coerce to valid decisions.

## Audit Requirements
Every arbitration event must record:
1. Advisor raw inputs
2. Normalized scoring components
3. Tie-break path taken
4. Deadlock/escalation timing
5. Final decision source (`COUNCIL` or `PRIMARCH`)
6. Any override metadata
