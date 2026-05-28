# ADR 001: Service / Store / Actor / Client naming conventions

**Status:** Accepted (Phase 6 governance, 2026-05-27)  
**Scope:** AgentLens, OpenBurnBarDaemon, OpenBurnBarCore  
**Supersedes:** informal `*Manager` sprawl; aligns with [OPENBURNBAR_RELEASE_ARCHITECTURE.md](../OPENBURNBAR_RELEASE_ARCHITECTURE.md) state-ownership table

## Context

OpenBurnBar grew quickly with overlapping suffixes (`Manager`, `Service`, `Store`, bare types). Reviewers could not infer thread safety, persistence boundaries, or lifecycle from a type name alone. The tech-debt audit flagged this as a velocity tax on every feature PR touching sync, search, or usage pipelines.

## Decision

Adopt a **suffix contract** for new and refactored types:

| Suffix | Responsibility | Threading | Examples |
|--------|------------------|-----------|----------|
| `*Store` | SQLite / GRDB persistence for one domain table or query surface | `actor` or dedicated queue; never `@MainActor` for I/O | `ConversationStore`, `UsageStore`, `SearchIndexStore` |
| `*Service` | Business orchestration across stores, network, or daemon RPC | Prefer `actor` for mutable state; `@MainActor` only for UI-bound facades | `DownloadSyncService`, `SearchService` (actor), `CloudSyncService` (UI facade, shrinking) |
| `*Actor` | Concurrency boundary wrapping a shared resource | Swift `actor` | `DataStoreActor` |
| `*Client` | Outbound network or IPC to one remote system | `Sendable`; no UI imports | `OpenBurnBarDaemonSocketClient`, `OpenAICompatibleChatGatewayClient` |
| `*Coordinator` | Thin wiring of multiple services with no domain logic | Match slowest dependency; document why | `CloudSyncCoordinator`, `BackgroundCadenceCoordinator` |
| `*Manager` | **Deprecated for new code** — legacy singletons only until migrated | Document isolation in header comment | `SettingsManager`, `OpenBurnBarDaemonManager` |

**Rules:**

1. One primary suffix per public type; do not stack (`UsageStoreService` is invalid).
2. Views and ViewModels talk to **services or coordinators**, not `DatabaseQueue` or sub-stores directly (see [005-sync-ownership.md](005-sync-ownership.md)).
3. Daemon HTTP/RPC handlers stay thin: validate auth → delegate to executor/store → map errors (see [003-error-handling.md](003-error-handling.md)).
4. Generated Firestore models keep `*Models.swift` / `*Models.kt` emit names from TypeSpec; do not hand-rename generated types (see [004-schema-canon.md](004-schema-canon.md)).

## Consequences

- PR reviewers can reject new `*Manager` types without an explicit migration note.
- Renames happen opportunistically during god-file splits (`CloudSyncService`, `UsageAggregator`), not as a standalone rename sprint.
- [AGENTS.md](../../AGENTS.md) Android section references the same schema canon; Kotlin stores follow the same suffix intent (`*Store` ViewModels).

## References

- [Tech debt strategy — Theme A](../TECH_DEBT_STRATEGY.md#theme-a-managerservice-store--a-naming-convention-without-boundaries)
- [IOS app architecture](../IOS_APP_ARCHITECTURE.md)
- [Release architecture — state ownership](../OPENBURNBAR_RELEASE_ARCHITECTURE.md#state-ownership)
