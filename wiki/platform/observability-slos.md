# Reliability, Metrics Stubs, and Operator SLOs

This document serves as the operator runbook for monitoring **latency**, **availability**, **error budgets**, and incident response pipelines across the **OpenBurnBar** app, daemon, and Cloud Functions.

---

## 1. Unified Telemetry Architecture

OpenBurnBar does not require a complex Prometheus cluster or metrics collector running on the developer's local machine. Instead, it relies on a local-first, highly efficient **three-layer telemetry model**:

| Observability Layer | Source / Component | Output Format | Purpose |
|:---|:---|:---|:---|
| **Structured Logs** | macOS `AppLogger`, daemon `BurnBarDaemonLogger`, Functions `logging.ts` | JSON lines with trace tags | Correlation of end-to-end user actions and debugging |
| **Local Aggregates** | macOS `LocalMetricsAggregator` + SQLite `retrieval_health` table | SQLite health tables & in-memory metrics | Performance analytics, search latency, and parser counters on-device |
| **Scrape/Export Stubs** | Daemon gateway `GET /metrics` | JSON metrics snapshot | Loopback health automated scripts and CI smoke tests |

### The Correlation Contract
Every logging layer on every surface must append the following correlation fields to ensure seamless cross-process request tracing:

* `trace_id`: End-to-end request identifier, instantiated by `TraceContext` or Cloud Functions middleware.
* `session_id`: Unique ID representing a multi-turn chat sequence or active Computer Use runtime session.
* `user_id_hash`: SHA-256 hashed representation of the user's Auth UID (used strictly on Cloud Functions to maintain tenant context without storing raw PII).
* `event`: A stable string literal mapping to a specific operational name (e.g., `hybrid_search_executed`, `computer_use_budget_evaluated`).

---

## 2. macOS Application SLOs

### Availability Targets (30-day Rolling)
* **App Launch Stability (Target: 99.9%):** No fatal exits on database init. If SQLite fails to open, the application must display an interactive database recovery modal instead of invoking `fatalError`.
* **Daemon Connectivity (Target: 99.5%):** Local daemon must be reachable via UNIX socket, with a heartbeat file age under 20 seconds.
* **Background Cadence Success (Target: 99.0%):** Background sync, cleanup, and aggregation ticks (`BackgroundCadenceCoordinator`) must run without failing.

### Latency Targets
* **Hybrid Search (Local):** `p50 < 120ms` | `p95 < 350ms` (measured via `retrieval_health.totalQueryLatencyMs`).
* **Dashboard Refresh:** `p50 < 2.0s` | `p95 < 5.0s`.
* **Cloud Sync Upload Batch:** `p50 < 30.0s` | `p95 < 120.0s` (excludes offline states).

---

## 3. Daemon SLOs & `/metrics` Schema

### Availability Targets
* **Local Gateway `/health` Endpoint:** **99.9%** availability (returns `{ "ok": true }`).
* **Heartbeat Freshness:** **99.5%** availability (heartbeat age `< 20s`).
* **Unix Socket RPC Success:** **99.0%** success rate on valid JSON-RPC commands.

### Latency Targets
* `/v1/models` Cached Catalog Retrieval: `p95 < 500ms`.
* Gateway Overhead (Transit & Route processing): `p95 < 50ms` (excluding upstream LLM call).
* Native Socket RPC: `p95 < 200ms` (excluding upstream actions).

### Gateway `/metrics` JSON Schema
When configured, the daemon gateway exposes an unauthenticated loopback metrics payload at `GET http://127.0.0.1:{port}/metrics`. Key JSON fields include:

* `gatewayEnabled` (boolean): Flag showing if the loopback gateway server is active.
* `heartbeatStale` (boolean): `true` if the local on-disk heartbeat has surpassed its stale threshold (20 seconds).
* `uptimeSeconds` (number): Monotonic uptime of the daemon process.
* `counters.gateway_enabled` (number): `1` if active, `0` otherwise.
* `counters.daemon_heartbeat_present` (number): `1` if heartbeat exists on disk.
* `counters.heartbeat_stale` (number): `1` if stale, `0` if fresh.
* `counters.rpc_requests_total` (number): Total requests received by the daemon since start.
* `counters.rpc_errors_total` (number): Total RPC requests returning error codes.

---

## 4. Cloud Functions SLOs

### Availability Targets
* **HTTPS Callable Success (Target: 99.5%):** Successful execution rate of schema-sync, rollups, or hosted-mcp callable endpoints.
* **Firestore Permission Gating (Target: < 0.1% Denials):** Clean schema synchronization and writes. No structural drift should trigger security rule rejections.
* **Budget Evaluator Precision (Target: 100%):** The hourly scheduled budget evaluator (`evaluateComputerUseBudget`) must run and publish kill-switch updates.

### Latency Targets
* **Usage Rollup DB Triggers:** `p95 < 3.0s`.
* **Hosted MCP Search Resolution:** `p95 < 500ms`.
* **Mercury Media Quota Recomputation:** `p95 < 60.0s`.

---

## 5. Operator Local Verification Playbook

Operators can verify local observability, daemon health, and telemetry systems directly from a macOS terminal:

### 1. Query Gateway Health & SLO State
```bash
# Check JSON-RPC Loopback Endpoint
curl -fsS "http://127.0.0.1:8317/health" | jq -e '.ok == true'

# Check SLO Metric Snapshot
curl -fsS "http://127.0.0.1:8317/metrics" | jq -e '
  .gatewayEnabled == true
  and .heartbeatStale == false
  and .counters["heartbeat_stale"] == 0
  and .counters["daemon_heartbeat_present"] == 1
'
```

### 2. Verify Daemon On-Disk Heartbeat File Freshness
```bash
python3 - <<'PY'
import json, os, sys
from datetime import datetime, timezone

hb_path = os.path.expanduser("~/Library/Application Support/OpenBurnBar/daemon/openburnbar-daemon.heartbeat.json")
try:
    with open(hb_path) as f:
        hb_data = json.load(f)
    updated = datetime.fromisoformat(hb_data["updatedAt"].replace("Z", "+00:00"))
    age_seconds = (datetime.now(timezone.utc) - updated).total_seconds()
    print(f"Daemon Heartbeat Age: {age_seconds:.2f}s")
    sys.exit(0 if age_seconds <= 20 else 1)
except Exception as e:
    print(f"Heartbeat validation failed: {e}")
    sys.exit(1)
PY
```

### 3. Verify Unix Socket RPC Health via CLI
```bash
# Query CLI-Daemon connection
swift run --package-path OpenBurnBarDaemon OpenBurnBarCLI health
```
