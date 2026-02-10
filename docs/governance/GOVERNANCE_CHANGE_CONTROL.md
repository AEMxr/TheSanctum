# Governance Change Control

## Purpose
Ensure governance changes are explicit, reviewable, reversible, and never silently bypassed.

## Standard Change Flow
1. Proposal with rationale, scope, risk, and rollback plan.
2. Advisor review and documented decision.
3. Approval by defined authority.
4. Controlled rollout with verification checkpoints.
5. Audit publication with resulting evidence.

## Required Change Metadata
Every change record must include:
1. `change_id`
2. author and approver identities
3. affected documents/systems
4. risk level
5. rollback anchor
6. verification evidence links

## Crisis/Expedite Linkage
Emergency governance changes must follow:
1. `docs/governance/CRISIS_EXPEDITE_PROTOCOL.md` activation constraints.
2. Time-bounded emergency execution only.
3. Mandatory post-hoc review and closure evidence.

Crisis path does not waive:
1. logging,
2. rollback planning,
3. post-hoc accountability.

## Invalid Change States
Changes are invalid if:
1. approval authority is missing,
2. rollback plan is missing,
3. required evidence is missing,
4. crisis-mode changes are not linked to a valid `crisis_id`.
