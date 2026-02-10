# Key Domain Separation

## Purpose
Define cryptographic domain separation for lineage and product systems so trust boundaries are technically enforceable.

## Domain Model
1. Lineage key domain:
   - Used for governance evidence signing and lineage manifest attestations.
2. Product key domain:
   - Used for runtime service authentication, tenant data protection, and product integrations.

## Separation Requirements
1. Lineage and product keys must be generated under separate key namespaces.
2. Private keys must never be reused across domains.
3. Key rotation schedules must be independent per domain.
4. Domain tags must be embedded in key metadata and signature envelopes.

## Signing Authority Rules
1. Lineage authority cannot sign product runtime assertions.
2. Product authority cannot sign lineage governance attestations.
3. Any signature with mismatched domain tag is invalid.

## Failure Handling
1. Compromise of one domain triggers immediate trust review in both domains.
2. Cross-domain trust is denied by default until explicit revalidation is complete.
3. Recovery must issue fresh keys for affected domain and re-attest dependencies.

## Audit Requirements
1. Key provenance records must include domain tag, owner, issuance timestamp, and rotation state.
2. Audit logs must show denied cross-domain signing attempts.
3. Missing domain metadata is a hard failure for key acceptance.

## Governance Link
This document operationalizes trust-boundary enforcement required by lineage/product isolation policy.
