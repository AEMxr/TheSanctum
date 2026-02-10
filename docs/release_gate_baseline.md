# Release-Gate Baseline v2.4.0

## Scope
This document freezes the release-gate baseline behavior for schema `v2.4.0`.
It is the rollback and comparison anchor for future gate work.

## Invariant Semantics
1. `strict_release_gate_ready` is true only when strict verify passed, run blockers are empty, and fallback artifacts are absent.
2. `release_decision` is a pure function of `strict_release_gate_ready` (`PASS` when true, `FAIL` when false).
3. `release_gate_reason` remains ordered and deduplicated.
4. Blocked-mode behavior remains deterministic and must not silently pass.

## Required Evidence Artifacts
1. `run_staging_summary.json`
2. `run_release_candidate_summary.json`
3. `artifacts/toolchain_manifest.txt`

## Schema Baseline
1. Default emitted schema version: `v2.4.0`
2. Compatibility window includes:
   1. `v2.4.0-draft1`
   2. `v2.4.0`
   3. `v2.4.1`
3. `v2.4.0-draft1` is accepted for compatibility validation only and emits warning signals when detected.

## CI Required Checks
1. `release-gate (windows-powershell-5_1)`
2. `release-gate (windows-pwsh-7)`
3. `negative-path-smoke (windows-powershell-5_1)`
4. `negative-path-smoke (windows-pwsh-7)`

## Non-goals
1. No schema major/minor bump in this baseline.
2. No change to gate decision semantics.
3. No removal of `v2.4.0-draft1` compatibility yet.

## Rollback Anchor
Use git tag `release-gate-baseline-v2.4.0` as the rollback checkpoint for this baseline.

## Execution OS Integration
This baseline is governed by the repo Execution OS documents:
1. `docs/mission_control.md`
2. `docs/non_negotiables.md`
3. `docs/checklists/pre_commit_drift_alarm.md`
4. `docs/checklists/zip_audit_playbook.md`
