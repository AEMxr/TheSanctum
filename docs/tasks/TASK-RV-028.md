# TASK-RV-028 - Usage ledger export and shipping runbook

## Objective lane
revenue

## Goal (single measurable outcome)
Provide exportable usage metering outputs and shipping-grade runbook/config documentation for immediate deployment and review.

## Scope (allowed files)
- `scripts/dev/export_usage_ledger.ps1`
- `.env.example`
- `apps/api/config.example.json`
- `apps/revenue_automation/config.example.json`
- `docs/runbooks/api_deploy_runbook.md`
- `apps/api/README.md`
- `apps/revenue_automation/README.md`
- `docs/tasks/TASK-RV-028.md`

## Non-goals
- No release-gate semantic changes.
- No edits outside scoped files.

## Acceptance checklist
- [ ] Usage ledger export script supports JSON and CSV output.
- [ ] .env example includes local/staging/prod-ready API variables.
- [ ] API config examples include auth/rate-limit/idempotency/request-limit defaults.
- [ ] Deploy runbook documents local run, Windows service option, reverse proxy, hardening checklist, and marketplace readiness checklist.
- [ ] API READMEs document one-command startup and smoke commands.

## Deliverables (SHA, diff summary)
- Commit SHA(s):
- Diff summary:

## Rollback anchor
`rollback/TASK-RV-028-pre`

## Commit message (exact)
`TASK-RV-028 docs(ops): add usage export, env templates, and shipping runbook`

## Execution notes
- Next first command: `pwsh -NoProfile -File scripts/dev/start_both_apis.ps1`
