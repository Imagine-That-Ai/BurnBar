# OpenBurnBar event catalog (ops)

Stable `event` field names for log-based SLOs, alerts, and incident correlation. See [OBSERVABILITY.md](../OBSERVABILITY.md) and [runbooks/slos.md](../runbooks/slos.md).

| Event | Severity | Alert policy | Runbook |
|-------|----------|--------------|---------|
| `callable_start` | INFO | — | — |
| `callable_success` | INFO | — | — |
| `callable_error` | ERROR | OpenBurnBar Callable error spike | [RUNBOOK.md](../RUNBOOK.md) |
| `circuit_breaker_tripped` | ERROR | OpenBurnBar Circuit breaker open | [oncall.md](../runbooks/oncall.md) |
| `resilience_failure` | ERROR | OpenBurnBar Circuit breaker open | [oncall.md](../runbooks/oncall.md) |
| `health_ready_ok` | INFO | — | — |
| `health_ready_failed` | ERROR | OpenBurnBar healthReady degraded | [rollback-automation.md](../runbooks/rollback-automation.md) |
| `scheduled_job_start` | INFO | — | — |
| `scheduled_job_failed` | ERROR | Callable error spike (aggregate) | [oncall.md](../runbooks/oncall.md) |
| `computer_use_budget_evaluated` | INFO | — | [computer-use-budget.md](../runbooks/computer-use-budget.md) |
| `computer_use_budget_evaluate_failed` | ERROR | — | [computer-use-budget.md](../runbooks/computer-use-budget.md) |
| `rollup.rebuild_failed` | ERROR | Firestore read spike | [RUNBOOK.md](../RUNBOOK.md) |

Hosted MCP and billing events: [REMOTE_MCP_RUNBOOK.md](../REMOTE_MCP_RUNBOOK.md), [functions/scripts/ops-alert-policy-definitions.mjs](../../functions/scripts/ops-alert-policy-definitions.mjs).

**Outbound HTTP:** Provider adapters use `providerFetch` (`functions/src/providers/httpClient.ts`). Stripe **webhook** signature verification intentionally uses raw request body handling (not `resilientFetch`) — do not wrap the webhook HTTP handler with outbound fetch resilience.
