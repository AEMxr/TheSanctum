## Summary

Describe the hardening change and why it is required.

## Release Contract

- Baseline remains `main@6bc1a0a` (`pilot-ready`).
- Rollout boundary remains enforced:
  - `delivery_mode=tenant_only`
  - `cross_sell_allowed=false`
- No rollout expansion in this PR.

## Classification

- [ ] Branch name uses `hardening/*`
- [ ] Labels are hardening-only (no feature-expansion labels)

## Boundary Proof (Required)

Provide concrete evidence that rollout boundary is unchanged.

- Config proof paths:
  - `...`
- E2E proof paths:
  - `...`

- [ ] `delivery_mode=tenant_only` verified
- [ ] `cross_sell_allowed=false` verified

## Required Test Gates

- [ ] `tests/integration/language_api.http.Tests.ps1`
- [ ] `tests/integration/revenue_api.http.Tests.ps1`
- [ ] `tests/both_apis.smoke.Tests.ps1`

Paste pass/fail counts:

- language_api.http: `...`
- revenue_api.http: `...`
- both_apis.smoke: `...`

## Evidence Artifacts (Attach Paths)

- [ ] Ready payload (language): `artifacts/runtime/language_ready.pilot.json`
- [ ] Ready payload (revenue): `artifacts/runtime/revenue_ready.pilot.json`
- [ ] Smoke summary: `artifacts/runtime/both_apis_smoke.summary.postmerge.json`
- [ ] Commit fingerprint: `artifacts/runtime/pilot_commit_6bc1a0a.txt` (or equivalent for current PR commit)

## Rollback Plan (Required)

Provide exact commands for rollback.

### Revert merge commit

```bash
git checkout main
git pull --ff-only origin main
git revert -m 1 <merge_commit_sha>
git push origin main
```

### Cherry-pick rollback (if needed)

```bash
git checkout -b rollback/<id> origin/main
git cherry-pick -x <commit_sha_to_revert_or_reapply>
```

## Risk Notes

- Describe operational risk and mitigation.
- Include any follow-up hardening issue links.

## Reviewer Checklist

- [ ] Scope is hardening-only
- [ ] Boundary proof is complete
- [ ] Required gates are green
- [ ] Evidence artifacts are present and accessible
- [ ] Rollback instructions are executable

## Exception Justification (required for non-hardening PRs into main)

Exception-ID: EXC-YYYYMMDD-<slug>

- [ ] Rollback commands included
- [ ] Pilot boundary unchanged (`delivery_mode=tenant_only`, `cross_sell_allowed=false`)

Reason:
- ...

Risk:
- ...

Compensating controls:
- ...
