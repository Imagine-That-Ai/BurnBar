# Design decisions

Cross-cutting architectural decisions recorded as ADRs in `docs/ARCHITECTURE/`.

## ADR-001: Naming conventions

**Decision:** Use `*Service` for long-lived singletons, `*Store` for observable screen models, `*Actor` for state-isolated units, and `*Client` for network callers.

**Rationale:** Creates a consistent vocabulary that makes file roles obvious at a glance.

## ADR-002: Actor boundaries

**Decision:** `@MainActor` for SwiftUI views and view-model state. Background actors (`DatabaseActor`, `SyncActor`) for I/O and concurrent work.

**Rationale:** Prevents data races without scattering `DispatchQueue` calls.

## ADR-003: Error handling

**Decision:** Typed errors with structured logging. Callable errors auto-capture via `wrapCallableHandler` → `withCallableLogging` → `captureException()` in `functions/src/logging.ts`.

**Rationale:** Failures are traceable and user-visible messages are decoupled from internal logs.

## ADR-004: Schema canon

**Decision:** Migrate to TypeSpec in `tools/schema-sync/` as the single source of truth for Firestore types, generating TypeScript, Swift, and Kotlin emitters.

**Rationale:** Prevents drift between platforms when the schema changes.

## ADR-005: Sync ownership

**Decision:** Local SQLite is canonical. Firestore is an optional replication and collaboration plane. iCloud mirroring is an optional file-copy plane. Neither replaces local state.

**Rationale:** Zero network dependency for core token tracking; cloud is additive.

## ADR-007: Ops notification plane

**Decision:** GCP Monitoring + Sentry + deploy gates for production observability.

**Rationale:** Structured alerting with clear escalation paths.

## ADR-008: Remote control engine

**Decision:** iroh-first P2P transport for remote desktop, media, and remote control.

**Rationale:** Single Rust crate compiles to all platforms via UniFFI, sharing wire format and Ed25519 pairing.

## Related pages

- [Architecture](../overview/architecture.md)
- [Iroh transport](../systems/iroh-transport.md)
- [Cloud sync](../features/cloud-sync.md)
