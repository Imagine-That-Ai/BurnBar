# SLO runbook — app, daemon, Cloud Functions

Operator runbook for **latency**, **availability**, and **error budgets** across OpenBurnBar surfaces. Plan of record for observability Phase 5–6 remediation; pairs with [OBSERVABILITY.md](../OBSERVABILITY.md) and [ARCHITECTURE/error-taxonomy.md](../ARCHITECTURE/error-taxonomy.md).

## Unified metrics approach

OpenBurnBar uses **three complementary layers** (no single Prometheus cluster on the Mac):

| Layer | Surface | Format | Primary use |
|-------|---------|--------|-------------|
| **Structured logs** | macOS `AppLogger`, daemon `BurnBarDaemonLogger`, Functions `logging.ts` | JSON lines with `trace_id`, `event`, domain metadata | Incident correlation |
| **Local aggregates** | `LocalMetricsAggregator` + `retrieval_health` table | In-memory snapshot + SQLite health rows | Search/sync/parser SLOs on device |
| **Scrape / export stubs** | Daemon gateway `GET /metrics`; Mac app `metrics.jsonl` rotation | JSON document (Prometheus text optional later) | Loopback automation, CI smoke |

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

- `GET http://127.0.0.1:{port}/health` — `{ "ok": true, "version": "<daemonVersion>" }` ([OpenBurnBarHTTPGatewayServer](../../OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarHTTPGatewayServer.swift))
- `GET http://127.0.0.1:{port}/metrics` — JSON snapshot from [`BurnBarGatewayMetricsSnapshot`](../../OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarGatewayMetrics.swift) (fields below)
- On-disk heartbeat: `~/Library/Application Support/OpenBurnBar/daemon/openburnbar-daemon.heartbeat.json` (override dir via `OPENBURNBAR_DAEMON_SUPPORT_DIR`)
- Unix socket RPC: `swift run --package-path OpenBurnBarDaemon OpenBurnBarCLI health` (or installed `openburnbar health`)
- Structured logs: `gateway_*`, `daemon_*` events

**`GET /metrics` JSON fields** (camelCase keys):

| Field | SLO use |
|-------|---------|
| `gatewayEnabled` | Gateway configured on |
| `heartbeatStale` | Must be `false` when daemon is healthy |
| `uptimeSeconds` | Process uptime |
| `counters.gateway_enabled` | `1` when gateway enabled |
| `counters.daemon_heartbeat_present` | `1` when heartbeat file decodes |
| `counters.heartbeat_stale` | `0` when heartbeat age `< 20s` |
| `counters.rpc_requests_total` | Monotonic RPC request count (socket + gateway) |
| `counters.rpc_errors_total` | RPC responses with error codes (auth, rate limit, decode) |
| `counters.rpc_latency_ms_p95` | Rolling p95 of local socket/gateway RPC latency (ms); omitted until samples exist |
| `heartbeat.updatedAt` | ISO8601 last write (when present) |

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

- `functions/src/logging.ts` — `logInfo` / `logError` / `logWarn` emit JSON with `event`, `trace_id`, `severity`
- **Stable `event` keys** (log-based SLO filters):

  | Event | Surface |
  |-------|---------|
  | `computer_use_budget_evaluated` | Hourly `evaluateComputerUseBudget` success |
  | `computer_use_budget_evaluate_failed` | Budget evaluator failure |
  | `callable_info` / `callable_error` / `callable_warn` | HTTPS callables (e.g. `rebuild_usage_rollups_*`) |
  | `rollup.rebuild_failed` | Scheduled rollup rebuild |
  | `router_rundown.latest_failed` | Router rundown fetch |

- Log-based metrics (example hosted MCP — extend pattern for new surfaces):

  - `logging.googleapis.com/user/openburnbar_hosted_mcp_5xx`
  - `logging.googleapis.com/user/openburnbar_hosted_mcp_429`
  - `logging.googleapis.com/user/openburnbar_hosted_mcp_auth_denial`

- Firestore budget state: `ops/computer_use_budget_status/state/current` (`level`, `monthToDateUSD`, `projectedMonthEndUSD`)
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

Default gateway port is **8317** (`BurnBarGatewayConfiguration.port`, overridable via `OPENBURNBAR_GATEWAY_PORT` or `--gateway-port`).

```bash
# --- Daemon gateway (loopback; gateway must be enabled in daemon config) ---
PORT="${OPENBURNBAR_GATEWAY_PORT:-8317}"

# Availability: /health must return ok:true
curl -fsS "http://127.0.0.1:${PORT}/health" | jq -e '.ok == true'

# Metrics snapshot + SLO counters (exit 1 if heartbeat stale or missing)
curl -fsS "http://127.0.0.1:${PORT}/metrics" | jq -e '
  .gatewayEnabled == true
  and .heartbeatStale == false
  and .counters["heartbeat_stale"] == 0
  and .counters["daemon_heartbeat_present"] == 1
'

# Human-readable metrics dump
curl -sS "http://127.0.0.1:${PORT}/metrics" | jq '{gatewayEnabled, heartbeatStale, uptimeSeconds, counters, heartbeat: .heartbeat.updatedAt}'

# --- On-disk heartbeat (works even when HTTP gateway is disabled) ---
HB="$HOME/Library/Application Support/OpenBurnBar/daemon/openburnbar-daemon.heartbeat.json"
test -f "$HB" && jq -e '.updatedAt' "$HB"
# Staleness: updatedAt within 20s (BurnBarDaemonHeartbeat.defaultStaleThreshold)
python3 - <<'PY'
import json, os, sys
from datetime import datetime, timezone
path = os.path.expanduser("~/Library/Application Support/OpenBurnBar/daemon/openburnbar-daemon.heartbeat.json")
with open(path) as f:
    snap = json.load(f)
updated = datetime.fromisoformat(snap["updatedAt"].replace("Z", "+00:00"))
age = (datetime.now(timezone.utc) - updated).total_seconds()
sys.exit(0 if age <= 20 else 1)
PY

# --- Unix socket RPC health (daemon process must be running) ---
swift run --package-path OpenBurnBarDaemon OpenBurnBarCLI health 2>/dev/null | head -5

# --- Cloud Functions structured logs (emulator or deployed; grep local emulator output) ---
# Budget evaluator success/failure events:
#   event=computer_use_budget_evaluated | computer_use_budget_evaluate_failed
# Callable rollup rebuild:
#   message=rebuild_usage_rollups_succeeded | rebuild_usage_rollups_failed

# --- Tech debt / remediation trend snapshot ---
./scripts/ci/update-tech-debt-metrics.sh
cat docs/TECH_DEBT_METRICS.md
```

**Bearer auth:** When the gateway binds outside loopback, pass `Authorization: Bearer <OPENBURNBAR_GATEWAY_TOKEN>` on `/health` and `/metrics`.

---

## Related docs

- [Observability contract](../OBSERVABILITY.md)
- [Tech debt metrics](../TECH_DEBT_METRICS.md)
- [Architecture ADRs](../ARCHITECTURE/README.md)
- [Computer Use budget runbook](computer-use-budget.md)
- [Media quota runbook](media-quota.md)
