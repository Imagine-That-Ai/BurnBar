# SLO runbook — app, daemon, Cloud Functions

Operator runbook for **latency**, **availability**, and **error budgets** across OpenBurnBar surfaces. Plan of record for observability Phase 5–6 remediation; pairs with [OBSERVABILITY.md](../OBSERVABILITY.md) and [ARCHITECTURE/error-taxonomy.md](../ARCHITECTURE/error-taxonomy.md).

## Unified metrics approach

OpenBurnBar uses **three complementary layers** (no single Prometheus cluster on the Mac):

| Layer | Surface | Format | Primary use |
|-------|---------|--------|-------------|
| **Structured logs** | macOS `AppLogger`, daemon `BurnBarDaemonLogger`, Functions `logging.ts` | JSON lines with `trace_id`, `event`, domain metadata | Incident correlation |
| **Local aggregates** | `LocalMetricsAggregator` + `retrieval_health` table | In-memory snapshot + SQLite health rows | Search/sync/parser SLOs on device |
| **Scrape / export stubs** | Daemon gateway `GET /metrics`, future `metrics.jsonl` | JSON document (Prometheus text optional later) | Loopback automation, CI smoke |

**Correlation contract** (all surfaces):

| Field | Purpose |
|-------|---------|
| `trace_id` | End-to-end request |
| `session_id` | Chat / CU subtree |
| `user_id_hash` | Tenant (Functions only; hashed uid prefix) |
| `event` | Stable metric name for log-based SLOs |

When adding a new critical path, ship **one structured log event** and **one counter** in the local or daemon metrics stub before tuning SLO thresholds.

---

## macOS app

### Availability

| SLI | Target (30-day) | Measurement |
|-----|------------------|-------------|
| App launch without DB fatal exit | **99.9%** | No production `fatalError` on `DataStore` init; recovery modal instead |
| Daemon reachable when gateway enabled | **99.5%** | `OpenBurnBarDaemonManager` health + heartbeat age `< 20s` |
| Background cadence ticks | **99%** | `background_cadence_tick_failed` log rate |

**Signals:**

- `AppLogger.metrics` — search compute, cadence failures (`BackgroundCadenceCoordinator`)
- `LocalMetricsAggregator` — `searchP50Ms`, `searchP95Ms`, `syncSuccessRate`, `parserEventsPerMinute` (1 h window default)
- User-visible: sync banner (`lastSyncError`), daemon chip in Settings

**Error budget policy:** If sync success rate `< 95%` over 7 days for opted-in users, freeze new Firestore write paths until [DownloadSyncService](../../AgentLens/Services/CloudSync/DownloadSyncService.swift) integration tests land.

### Latency

| Path | p50 target | p95 target | Notes |
|------|------------|------------|-------|
| Hybrid search (local) | `< 120 ms` | `< 350 ms` | From `retrieval_health.totalQueryLatencyMs`; see `LocalMetricsAggregator` |
| Dashboard refresh | `< 2 s` | `< 5 s` | Versioned caches on `DataStoreCoordinator.usagesVersion` |
| Cloud sync upload batch | `< 30 s` | `< 120 s` | Excludes user offline; backoff per [error-taxonomy](../ARCHITECTURE/error-taxonomy.md) |

**Playbook:**

1. Filter Console for subsystem `metrics` and `trace_id` from user report.
2. Query `retrieval_health` for semantic vs lexical latency split.
3. If p95 search regression: check embedding reload and N+1 hydration (see [TECH_DEBT_STRATEGY.md](../TECH_DEBT_STRATEGY.md) performance themes).

---

## Daemon (OpenBurnBarDaemon)

### Availability

| SLI | Target | Measurement |
|-----|--------|-------------|
| Gateway `/health` | **99.9%** when enabled | Loopback GET returns `{ "ok": true }` |
| Heartbeat freshness | **99.5%** | `BurnBarDaemonHeartbeat` file age `< 20s` |
| Socket RPC success | **99%** | RPC error rate excluding client cancel |

**Signals:**

- `GET http://127.0.0.1:{port}/health` — version + ok ([OpenBurnBarHTTPGatewayServer](../../OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarHTTPGatewayServer.swift))
- `GET http://127.0.0.1:{port}/metrics` — JSON snapshot (uptime, heartbeat, gateway counters stub)
- On-disk heartbeat: `BurnBarDaemonPaths.defaultHeartbeatURL`
- Structured logs: `gateway_*`, `daemon_*` events

**Playbook:**

1. `openburnbar health` (CLI) or app Daemon settings → verify heartbeat PID matches running process.
2. If heartbeat stale but process alive: check disk permissions on support directory.
3. If gateway 5xx spike: inspect rate limit + provider executor logs; rotate auth token if compromised.

### Latency

| Path | p95 target |
|------|------------|
| `/v1/models` | `< 500 ms` (cached catalog) |
| `/v1/chat/completions` (TTFB) | Provider-bound; track gateway overhead `< 50 ms` |
| Socket RPC (local) | `< 200 ms` excluding provider calls |

---

## Cloud Functions

### Availability

| SLI | Target | Measurement |
|-----|--------|-------------|
| Callable success rate (hosted quota, rollups) | **99.5%** | Error ratio on structured `severity: ERROR` logs |
| Firestore rules denials | **< 0.1%** of authenticated writes | Rules emulator + production deny metrics |
| Computer Use budget evaluator | **100%** hourly runs | `evaluateComputerUseBudget` schedule + kill-switch RC publish |

**Signals:**

- `functions/src/logging.ts` — `logInfo` / `logError` with `event` keys
- Log-based metrics (example hosted MCP — extend pattern for new surfaces):

  - `logging.googleapis.com/user/openburnbar_hosted_mcp_5xx`
  - `logging.googleapis.com/user/openburnbar_hosted_mcp_429`
  - `logging.googleapis.com/user/openburnbar_hosted_mcp_auth_denial`

- Cloud Monitoring dashboards — see [REMOTE_MCP_RUNBOOK.md](../REMOTE_MCP_RUNBOOK.md#monitor)

### Latency

| Function class | p95 target |
|----------------|------------|
| Usage rollup triggers | `< 3 s` |
| Hosted MCP search | `< 500 ms` (see MCP runbook proof harness) |
| Media quota recompute | `< 60 s` batch |

**Error budget:** Monthly Firestore read budget for hosted MCP — alert on dashboard tile before hard cap; see [media-budget.md](media-budget.md).

---

## Error budgets and escalation

| Tier | Burn rate | Action |
|------|-----------|--------|
| **Warning** | > 25% monthly budget in 7 days | Triage in `#ops`; defer feature flags |
| **Critical** | > 50% monthly budget in 7 days | Freeze deploys; Remote Config kill-switch review |
| **Page** | SLO < target for 1 h (gateway 5xx, app launch crash loop) | Follow [RUNBOOK.md](../RUNBOOK.md) + release rollback [RELEASE_ROLLBACK.md](../RELEASE_ROLLBACK.md) |

---

## Local verification

```bash
# Daemon gateway (default loopback port from daemon config)
curl -sS "http://127.0.0.1:8317/health" | jq .
curl -sS "http://127.0.0.1:8317/metrics" | jq .

# Tech debt / remediation trend snapshot
./scripts/ci/update-tech-debt-metrics.sh
cat docs/TECH_DEBT_METRICS.md
```

---

## Related docs

- [Observability contract](../OBSERVABILITY.md)
- [Tech debt metrics](../TECH_DEBT_METRICS.md)
- [Architecture ADRs](../ARCHITECTURE/README.md)
- [Computer Use budget runbook](computer-use-budget.md)
- [Media quota runbook](media-quota.md)
