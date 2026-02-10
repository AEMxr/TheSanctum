# Runtime Budgets GTX1660

## Purpose
Define enforceable runtime budgets for local execution on GTX 1660 class hardware so behavior is predictable under load.

## Budget Table
| Dimension | Target | Hard Limit | Notes |
|---|---:|---:|---|
| VRAM utilization | <= 4.5 GB | 5.5 GB | Leave headroom for OS/driver overhead. |
| P95 latency per request | <= 1800 ms | 3000 ms | Measured at steady-state local inference. |
| Max context window used | <= 6k tokens | 8k tokens | Requests above limit must be reduced or rejected. |
| Throughput | >= 8 req/min | >= 4 req/min | Below hard limit enters degraded mode. |

## Saturation Signals
1. VRAM at or above hard limit.
2. P95 latency above hard limit across rolling window.
3. Throughput below hard floor across rolling window.
4. Context requests exceeding hard limit.

## Graceful Degradation Rules
1. Clamp context to target window before hard rejection.
2. Reduce concurrency to stabilize latency when saturation is detected.
3. Prioritize control-plane and safety-critical tasks over non-critical workloads.
4. Return explicit degraded-state metadata in runtime output when limits are approached.

## Enforcement Notes
1. Budgets are operational guardrails, not optimization targets.
2. Any hard-limit breach must trigger fallback policy evaluation.
3. Repeated hard-limit breaches require runtime tuning review.

## Governance Link
This document is a roadmap dependency for runtime-safe operation and fallback control.
