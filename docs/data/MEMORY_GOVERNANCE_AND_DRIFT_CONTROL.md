# Memory Governance And Drift Control

## Purpose
Define deterministic controls for promoting, retaining, and quarantining memory artifacts so training and runtime behavior remain trustworthy.

## Memory Layers
1. Truth-layer memory:
   - Canonical facts, policies, and release-gate constraints.
   - Requires explicit evidence and lineage before promotion.
2. Style-layer memory:
   - Personalization, tone, and preference hints.
   - Must never override truth-layer constraints.

## Promotion Lifecycle
1. Hot:
   - Newly observed candidate memory.
   - Not trusted by default.
   - Requires at least one validation pass before promotion.
2. Warm:
   - Candidate passed initial validation checks.
   - Eligible for controlled use in non-critical contexts.
   - Requires contradiction scan on each update cycle.
3. Cold:
   - Stable, validated memory used as trusted baseline input.
   - Changes require governance review and new lineage record.

## Promotion Criteria
1. Hot -> Warm requires:
   - Valid source attribution.
   - No direct conflict with current cold truth-layer memory.
   - Evidence timestamp and owner attribution.
2. Warm -> Cold requires:
   - Repeated consistency across evaluation windows.
   - No unresolved contradiction flags.
   - Lineage metadata complete and review approved.

## Contradiction Detection And Quarantine
1. Contradiction states:
   - NONE: no conflict detected.
   - SUSPECTED: conflict detected pending verification.
   - CONFIRMED: conflict validated.
2. Quarantine rules:
   - CONFIRMED contradictions are immediately quarantined.
   - Quarantined items are excluded from promotion and training candidates.
   - Quarantine release requires explicit adjudication outcome and updated lineage.

## Drift Controls
1. Any memory update that changes trusted behavior must include a drift rationale.
2. Memory promotion without lineage metadata is invalid.
3. Mixed truth/style payloads are rejected and must be split before review.

## Governance Link
This document defines the memory governance gate referenced by the roadmap and must be reviewed before training lineage promotion.
