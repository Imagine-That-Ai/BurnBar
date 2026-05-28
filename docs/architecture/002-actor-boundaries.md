# ADR 002: Actor isolation and MainActor boundaries

**Status:** Accepted (Phase 6 governance, 2026-05-27)  
**Scope:** macOS app (`AgentLens/`), daemon, mobile read paths

## Context

Early services defaulted to `@MainActor`, then escaped with `Task.detached` for database, network, and filesystem work. That broke structured concurrency, made cancellation unreliable, and hid latency on the main thread. `SearchService` and `ProjectionPipelineService` migrated to Swift `actor`; `CloudSyncService` and `UsageAggregator` remain `@MainActor` facades with background work delegated outward.

## Decision

### Layer rules

| Layer | Isolation | Rationale |
|-------|-----------|-----------|
| SwiftUI views / `@Observable` view models | `@MainActor` | UI mutations only |
| Persistence (`*Store`) | `actor` or `DatabaseQueue` | SQLite is off-main by design |
| Retrieval / projection / parsing pipelines | `actor` or detached `Task` owned by an actor | CPU + I/O heavy; publish snapshots to UI |
| Cloud sync upload/download | Background `Task` inside dedicated sync services; coordinator on `@MainActor` for UI state only | Firestore batches must not block menu bar |
| Daemon gateway / socket RPC | `actor` servers (`BurnBarHTTPGatewayServer`, daemon socket handler) | Serialize listener state safely |

### Patterns

1. **Snapshot at the boundary** — `@MainActor` code reads immutable snapshots (`SharedArtifactAccessContext`, `LocalMetricsSnapshot`) produced by background actors.
2. **No naked `Task.detached`** in new code — prefer `Task { await actor.method() }` with explicit cancellation handles stored on the owning type. Legacy `Task.detached` in `CLIBridge` and quota adapters is tracked in [TECH_DEBT_METRICS.md](../TECH_DEBT_METRICS.md).
3. **`nonisolated` store properties on `DataStoreActor` are legacy** — new stores inject through initializers; do not add new `nonisolated` escape hatches.
4. **Daemon heartbeat** — `BurnBarDaemonHeartbeat` writes off-main; the app reads the file from `OpenBurnBarDaemonHeartbeatReader` without blocking UI.

### Current `@MainActor` I/O facades (remediation targets)

These types historically carried class-scoped `@MainActor` while touching network or Firestore. CI counts **class-level** `@MainActor` only (see `scripts/ci/update-tech-debt-metrics.sh`); `@MainActor static shared` accessors on daemon/CLI mirror types are excluded.

- `CloudSyncService` — **cleared** (delegates to off-main domain services + `syncGate()`)
- `UsageAggregator` — **retained** `@Observable` orchestrator; heavy work via `RefreshBackgroundWork` / `Task.detached`
- `DownloadSyncService`, `ConversationSyncService`, `CLIAgentSessionMirror` — **cleared**
- `OpenBurnBarDaemonManager` — **retained** `@Observable` supervisor (class-scoped `@MainActor`); RPC via `daemonRPC` off-main

**Not** counted as violations: `SearchService` (actor), `ProjectionPipelineService` (actor).

## Consequences

- New `@MainActor` services require an ADR comment in the PR if they perform I/O.
- SwiftLint / review checklist references this ADR (see [TECH_DEBT_STRATEGY.md](../TECH_DEBT_STRATEGY.md) governance).
- Performance work uses `BackgroundCadenceCoordinator` instead of ad-hoc sleep loops ([background-cadence.md](../architecture/background-cadence.md)).
- Monthly reviews run `./scripts/ci/update-tech-debt-metrics.sh` per [AGENTS.md](../../AGENTS.md).

## References

- [Background cadence coordinator](../architecture/background-cadence.md)
- [macOS performance notes](../architecture/macos-performance.md)
- [SLO runbook — app latency](../runbooks/slos.md#macos-app)
- [001-naming-conventions.md](001-naming-conventions.md)
