# Lineage Product Isolation Policy

## Purpose
Define hard trust boundaries between lineage systems and product tenant systems to prevent cross-domain contamination and unauthorized data joins.

## Trust Boundaries
1. Lineage domain:
   - Stores training lineage metadata, governance evidence, and candidate provenance.
   - Operates under governance-signing authority only.
2. Product domain:
   - Stores tenant runtime data, product telemetry, and customer interaction records.
   - Operates under product-signing authority only.

## Non-Crossable Data Classes
1. Tenant-identifying product payloads must not be copied into lineage stores.
2. Raw lineage adjudication evidence must not be exposed to product runtime paths.
3. Signing keys, private material, and key-derivation artifacts are non-transferable across domains.

## Prohibited Joins
1. No direct database joins between lineage and product data stores.
2. No shared write paths between lineage metadata and tenant runtime records.
3. No unreviewed bridge export that mixes lineage and tenant identity payloads.

## Failure-Domain Isolation
1. A failure in lineage systems must not degrade product tenant isolation guarantees.
2. A product-tenant breach event must not grant access to lineage governance records.
3. Recovery operations must preserve domain separation and key isolation requirements.

## Access Control Requirements
1. Lineage and product domains require separate service identities.
2. Cross-domain access requires explicit reviewed export contracts.
3. Emergency access must be time-bounded, logged, and post-reviewed.

## Governance Link
This policy is a roadmap dependency and must be satisfied before any lineage-to-product bridge changes are approved.
