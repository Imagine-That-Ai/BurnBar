# Design decisions

This page summarizes the Architecture Decision Records (ADRs) stored in [`docs/ARCHITECTURE/`](../../docs/ARCHITECTURE/). For the full text of each ADR, follow the links below.

## ADR-001: Naming conventions (`docs/ARCHITECTURE/001-naming-conventions.md`)

**Status:** Accepted (2026-05-27)
**Scope:** `AgentLens/`, `OpenBurnBarDaemon/`, `OpenBurnBarCore/`

The codebase grew with overlapping suffixes (`Manager`, `Service`, `Store`, bare types). Reviewers could not infer thread safety, persistence boundaries, or lifecycle from a type name alone. The decision adopted a strict **suffix contract**:

| Suffix | Responsibility | Threading |
|--------|----------------|-----------|
| `*Store` | SQLite / GRDB persistence for one domain table or query surface | `actor` or dedicated queue; never `@MainActor` for I/O |
| `*Service` | Business orchestration across stores, network, or daemon RPC | Prefer `actor`; `@MainActor` only for UI-bound facades |
| `*Actor` | Concurrency boundary wrapping a shared resource | Swift `actor` |
| `*Client` | Outbound network or IPC to one remote system | `Sendable`; no UI imports |
| `*Coordinator` | Thin wiring of multiple services with no domain logic | Match slowest dependency |
| `*Manager` | **Deprecated for new code** — legacy singletons only until migrated | Document isolation in header comment |

One primary suffix per public type. Views and ViewModels talk to **services or coordinators**, not `DatabaseQueue` or sub-stores directly.

## ADR-002: Actor boundaries (`docs/ARCHITECTURE/002-actor-boundaries.md`)

**Status:** Accepted (2026-05-27)

Early services defaulted to `@MainActor`, then escaped with `Task.detached` for database, network, and filesystem work. That broke structured concurrency, made cancellation unreliable, and hid latency on the main thread. The decision introduced **layer rules**:

- SwiftUI views / `@Observable` view models → `@MainActor`
- Persistence (`*Store`) → `actor` or `DatabaseQueue`
- Retrieval / projection / parsing pipelines → `actor` or detached `Task` owned by an actor
- Cloud sync upload/download → Background `Task` inside dedicated sync services; coordinator on `@MainActor` for UI state only

Key patterns: **snapshot at the boundary** (`@MainActor` code reads immutable snapshots produced by background actors), and **no naked `Task.detached`** in new code.

## ADR-003: Error taxonomy (`docs/ARCHITECTURE/003-error-handling.md`)

**Status:** Accepted (2026-05-27)

The codebase historically swallowed failures via empty `catch` blocks, `try?`, and `AppLogger.silently()`. The decision adopted **`OpenBurnBarError`** with stable domains (`database`, `sync`, `daemon`, `parse`, `network`, `search`, `quota`, `media`). Every error exposes a `metricKey` (`{domain}_{code}`) for SLO counters. Rules:

- Log with domain + stable code.
- No empty `catch {}` in new code.
- `try?` requires justification.
- Daemon HTTP errors return JSON `{"error":"..."}` without leaking stack traces.

## ADR-004: Schema canon and drift control (`docs/ARCHITECTURE/004-schema-canon.md`)

**Status:** Accepted (2026-05-27)

Firestore document shapes were originally hand-maintained in `functions/src/types.ts` while clients duplicated models in Swift and Kotlin. Drift caused silent decode failures. The decision adopted a **canon chain** driven by TypeSpec:

```text
tools/schema-sync/typespec/*.tsp
        │ emit
        ├── functions/src/types.ts
        ├── OpenBurnBarCore/Sources/OpenBurnBarFirestoreModels/*.swift
        └── android/.../generated/*Models.kt
```

Rules: never edit generated files by hand; legacy `types.ts` interfaces remain until their TypeSpec module ships; breaking changes require a version bump and coordinated mobile minimum version.

## ADR-005: Sync ownership (local-first) (`docs/ARCHITECTURE/005-sync-ownership.md`)

**Status:** Accepted (2026-05-27)

Multiple planes (local SQLite, daemon JSONL, Firestore, iCloud) can hold overlapping data. Without explicit ownership, merge bugs and double-writes appear. The decision declares the **local SQLite store** as the canonical owner for token usage, conversations, quota snapshots, and shared artifacts. Firestore and iCloud are replication / backup only.

The `CloudSyncCoordinator` owns `@MainActor` UI state (`isSyncing`, errors) and schedules work. Domain-specific services (`DownloadSyncService`, `ConversationSyncService`) perform pull + merge. Conflict resolution uses optimistic concurrency on Firestore docs with device-prefixed IDs.

## ADR-006: Budget envelope visibility (`docs/ARCHITECTURE/006-budget-envelope-visibility.md`)

**Status:** Accepted (2026-05-27)

Defines how budget governance surfaces in the UI: soft cap at projected $1,500/mo, hard cap at $2,500/mo, per-user daily ceiling ($5/$2.50/$0). The `evaluateComputerUseBudget` Cloud Function evaluates hourly. Remote Config kill-switches (`computer_use_kill_switch`, `media_kill_switch`) provide an emergency override.

## ADR-007: Ops notification plane (`docs/ARCHITECTURE/007-ops-notification-plane.md`)

**Status:** Accepted (2026-05-31)

Introduced a repo-owned policy manifest (`functions/scripts/ops-alert-policy-definitions.mjs`) that merges SLO + billing policies. GCP Monitoring is primary; Sentry is secondary. Deploy gates run blocking post-deploy health checks. CI enforces ops readiness via `verify-ops-readiness.sh`.

## ADR-008: Remote control engine (Iroh-first) (`docs/ARCHITECTURE/008-remote-control-engine.md`)

**Status:** Accepted (2026-06-01)

Feasibility assessment for a Parsec/Splashtop-class remote-control substrate built on Iroh. The decision creates a nested Rust workspace at `crates/burnbar-remote/` with Iroh isolated in the network crate. Core crates: `burnbar-remote-core`, `burnbar-remote-protocol`, `burnbar-remote-observability`, `burnbar-remote-security`, `burnbar-remote-media`, `burnbar-remote-network`, `burnbar-remote-host`, `burnbar-remote-client`, `burnbar-remote-bench`.

Key paths: capture → hardware encoder → datagram packetizer → Iroh `send_datagram` (never `send_datagram_wait`); client receive → depacketizer → hardware decoder → renderer; input over reliable bi-stream with session grant / anti-replay / kill-switch verification.
