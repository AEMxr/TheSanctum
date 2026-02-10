# Training Lineage Standard

## Purpose
Define required lineage metadata for any memory artifact considered as a training candidate.

## Required Metadata
Each candidate must include:
1. candidate_id
2. source_system
3. source_reference
4. collected_at_utc
5. owner
6. review_status
7. validation_evidence
8. contradiction_state
9. promotion_state (hot|warm|cold)
10. supersedes_candidate_id (optional)

## Validation Requirements
1. Metadata completeness is mandatory.
2. Timestamps must be ISO8601 UTC.
3. review_status must be one of:
   - PENDING
   - APPROVED
   - REJECTED
4. contradiction_state must be one of:
   - NONE
   - SUSPECTED
   - CONFIRMED

## Candidate Eligibility Rules
1. A candidate is training-eligible only when:
   - review_status = APPROVED
   - contradiction_state = NONE
   - promotion_state in (warm, cold)
2. Any candidate lacking required metadata is invalid and must be rejected.
3. Quarantined candidates are never eligible.

## Audit Requirements
1. Every training export must include the full lineage manifest.
2. Manifest must be reproducible from repository evidence and logs.
3. Any missing lineage link is a hard stop for training promotion.

## Governance Link
This standard is required by memory governance controls and roadmap memory-gate milestones.
