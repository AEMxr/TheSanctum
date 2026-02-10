# Revenue Automation Phase 1 Scaffold

This directory contains a feature-flagged scaffold for Phase 1 revenue automation work.

## Safety defaults
1. `enable_revenue_automation` defaults to `false`.
2. `safe_mode` defaults to `true`.
3. `dry_run` defaults to `true`.

## Runtime entrypoint
Use:

```powershell
pwsh -File apps/revenue_automation/src/index.ps1 -ConfigPath apps/revenue_automation/config.example.json -TaskPath <task-json-path>
```

When automation is disabled, the script exits `0` with no side effects.
