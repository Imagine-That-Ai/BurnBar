# ADR 003: Error taxonomy and failure visibility

**Status:** Accepted (Phase 6 governance, 2026-05-27)  
**Scope:** macOS app, daemon, Cloud Functions, mobile outbound writes

## Context

The codebase historically swallowed failures via empty `catch` blocks, `try?`, and `AppLogger.silently()` used as control flow. Users saw "nothing happens" during sync, parsing, or daemon RPC outages. Observability work ([OBSERVABILITY.md](../OBSERVABILITY.md)) added trace correlation but not a shared error vocabulary until Phase 1 introduced `OpenBurnBarError`.

## Decision

### Domains

All new thrown errors map to **`OpenBurnBarError`** domains (`OpenBurnBarCore/Sources/OpenBurnBarCore/Errors/OpenBurnBarError.swift`):

| Domain | Examples | User surface |
|--------|----------|--------------|
| `database` | migration failure, SQLITE_BUSY | Recovery modal; never `fatalError` in production |
| `sync` | Firestore permission, merge conflict | Settings sync banner + `lastSyncError` |
| `daemon` | socket auth, RPC timeout, stale heartbeat | Daemon settings + degraded mode chip |
| `parse` | malformed agent log line | Skip row; increment parser counter |
| `network` | quota API 429, gateway 5xx | Provider quota card + retry affordance |
| `search` | FTS/projection health failures | Session logs / privacy settings banner |
| `quota` | provider quota probe failures | Provider quota card |
| `media` | Mercury / screen-share transport | Media settings degraded chip |

Each error exposes `metricKey` as `{domain}_{code}` for [SLO counters](../runbooks/slos.md#counter-registry).

### Deferred: OpenBurnBarUI SPM split

`OpenBurnBarCore` already embeds SwiftUI views under `Sources/OpenBurnBarCore/Views/`. Extracting `OpenBurnBarUI` would require moving 200+ view files, splitting the Xcode target graph, and updating mobile/macOS import edges — high churn with no compile-time win until the core module stops mixing models and UI. Track in a follow-up once view-only dependencies are catalogued.

### Handling rules

1. **Log with domain + stable code** — `AppLogger.error("sync_upload_failed", metadata: OpenBurnBarError.sync(...).logMetadata)`. Cloud Functions use `logError` from `functions/src/logging.ts` with the same `event` naming style.
2. **No empty `catch {}`** — CI counts empty catches via `scripts/ci/update-tech-debt-metrics.sh`; new empty catches fail review.
3. **`try?` requires justification** — allowed for truly optional cosmetic paths; forbidden for Firestore writes, daemon RPC, and ledger persistence.
4. **Daemon HTTP errors** — gateway returns JSON `{"error":"..."}` with appropriate status; never leak stack traces on loopback (see `BurnBarHTTPGatewayServer`).
5. **Metrics** — counter keys `{domain}_{code}` feed `LocalMetricsCounter` and daemon `GET /metrics` stub ([slos.md](../runbooks/slos.md)).

### RPC / HTTP mapping

| Transport | Client sees | Operator sees |
|-----------|-------------|---------------|
| Daemon socket RPC | Typed `BurnBarRPCError` / `OpenBurnBarError` code | Structured log + heartbeat age |
| Gateway `/v1/*` | OpenAI-compatible error object | Gateway log + rate-limit headers |
| Cloud Functions | Callable HTTPS error / `{ success: false }` | JSON log + Cloud Monitoring policies |

## Consequences

- Refactors migrate stringly `"Failed to sync"` messages to typed codes incrementally.
- Archived sync tests revive against fake gateways with assertable error codes ([AgentLensTests/Archive/](../AgentLensTests/Archive/README.md)).
- SLO error budgets use log-based metrics keyed by stable `event` names ([slos.md](../runbooks/slos.md#cloud-functions)).

## References

- [Observability contract](../OBSERVABILITY.md)
- [Threat model](../THREAT_MODEL.md)
- [Remote MCP runbook — monitoring](../REMOTE_MCP_RUNBOOK.md#monitor)
- [001-naming-conventions.md](001-naming-conventions.md)
