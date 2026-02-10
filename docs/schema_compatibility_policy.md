# Schema Compatibility Policy

## Current Default
The current default emitted `summary_schema_version` is:
- `v2.4.0`

## Supported Compatibility Versions
The release-gate contract tests currently support:
- `v2.4.0-draft1`
- `v2.4.0`
- `v2.4.1`

## Emission and Verification Rules
1. Emit the latest stable schema version by default.
2. Accept prior supported versions during an explicit verification window.
3. Require compatibility-map updates in tests before changing emitted schema.

## Evolution Rules
1. Additive fields are allowed in minor/patch schema updates when checks remain backward compatible.
2. Breaking changes require a new major/minor schema version and migration notes.
3. Breaking changes must not silently alter PASS/FAIL release semantics.

## Deprecation Policy
1. `v2.4.0-draft1` is accepted temporarily for compatibility validation only.
2. Removal criteria:
   - no active producers emit `v2.4.0-draft1`
   - all gated lanes pass against stable schema outputs
   - compatibility-map update approved in review
3. Review checkpoint date:
   - `<YYYY-MM-DD placeholder>`

## Evidence Contract
At minimum, the following artifacts must exist for schema-aware release evidence:
1. `run_staging_summary.json`
2. `run_release_candidate_summary.json`
3. `artifacts/toolchain_manifest.txt`
