# Non-Negotiables

## Immutable Rules
1. Do not alter release-gate semantics unless the task is explicitly a control-plane change.
2. New capabilities must be feature-flagged and default OFF.
3. Every change requires test updates, or an explicit test N/A justification.
4. Every change requires docs updates.
5. Every merge must have a rollback anchor (tag or commit SHA).
6. No direct quick-fix commits to main for feature work.
7. End each session with a logged handoff and next first command.

## Drift Stop Condition
If scope is touched outside declared files, stop and re-scope before continuing.
