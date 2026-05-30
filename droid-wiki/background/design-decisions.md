# Design decisions

Key architectural choices with rationale.

## 1. Local-first over cloud-first

Local SQLite (GRDB) is the canonical data store. Firestore is a replication layer, not the source of truth.

**Rationale:** Privacy — agent session logs contain code and prompts that should not leave the machine without explicit user action. Offline reliability — the app works fully without a network connection. No cloud availability dependency for core features.

**Implementation:** The daemon writes all events to the local database first. `CloudSyncService` replicates to Firestore asynchronously when cloud sync is enabled. ADR [005-sync-ownership.md](../../docs/architecture/005-sync-ownership.md) defines which data lives in which plane.

## 2. GRDB over Core Data

All persistence uses [GRDB](https://github.com/groue/GRDB.swift) (SQLite) rather than Core Data.

**Rationale:** Direct SQL control, no Objective-C class inheritance, better async patterns with Swift concurrency, SQLCipher encryption for sensitive data (session logs, credentials). Core Data's NSManagedObject model is incompatible with value-type Swift design.

**Implementation:** The fork `grdb-sqlcipher` (pinned to 6.29.3) adds SQLCipher. All stores are `actor` or dedicated queue to enforce serial access. See ADR [001-naming-conventions.md](../../docs/architecture/001-naming-conventions.md) for the `*Store` suffix contract.

## 3. Daemon-first architecture

Heavy logic (provider routing, mission control, search indexing, connector plane) lives in `OpenBurnBarDaemon`, a separate process from the macOS menu bar app.

**Rationale:** The daemon runs without a UI, surviving menu bar crashes. CLI and extension access the same logic through the Unix socket RPC surface. Separation of concerns: the UI is a thin observer of daemon state.

**Implementation:** The macOS app connects to `~/.burnbar.sock` (JSON-RPC 2.0). The VS Code/Cursor extension uses the same socket. The daemon registers a launchd plist so it starts on login.

## 4. @Observable over ObservableObject

The codebase migrated to the iOS 17+ / macOS 14+ `Observation` framework (`@Observable` macro) from `ObservableObject` + `@Published`.

**Rationale:** Simpler syntax — no `@Published` annotations on every property. Better performance — SwiftUI only re-renders views that access changed properties, not all observers of the object. Cleaner with `@State` and `@Environment`.

**Implementation:** `SettingsManager` and its sub-stores are all `@Observable`. See ADR [002-actor-boundaries.md](../../docs/architecture/002-actor-boundaries.md) for threading rules.

## 5. UniFFI for iroh P2P transport

The `crates/openburnbar-iroh` Rust crate uses [UniFFI](https://github.com/mozilla/uniffi-rs) (pinned 0.28.3) to generate both Swift and Kotlin bindings.

**Rationale:** One implementation of the P2P protocol instead of two. Type-safe cross-language API — UniFFI generates the glue code. The iroh library itself has no Swift or Kotlin implementation.

**Implementation:** CI compiles `OpenBurnBarIroh.xcframework` for iOS/macOS and `Vendor/openburnbar-iroh.aar` for Android. Mercury audio rides `MercuryAudioDatagramChannel` over ALPN `openburnbar/mercury/audio/1`.

## 6. XcodeGen over checked-in xcodeproj

`project.yml` (XcodeGen) is the source of truth for the Xcode project. The `.xcodeproj` is generated, not committed.

**Rationale:** Eliminates merge conflicts in Xcode's verbose XML project format. Config changes are human-readable diffs in YAML. New targets and build settings are reviewable.

**Implementation:** Run `xcodegen generate` after pulling changes that modify `project.yml`. CI runs this step automatically.

## 7. Hermes chat dual-backend

The chat panel supports two backends: CLI bridge (stateless) and Hermes webapi (multi-turn).

**Rationale:** Works without Hermes running — falls back to the existing CLI bridge seamlessly. When Hermes is available on `localhost:8642`, upgrades to multi-turn memory, server-side tool calls, and richer context injection.

**Implementation:** `CLIBridge.detect()` probes `localhost:8642/v1/models`. If Hermes responds, it becomes the preferred backend. Both backends emit the same `CLIChatStreamEvent` types (`.text`, `.toolUse`) so the UI layer is backend-agnostic. See DESIGN.md § Hermes Integration for the full technical design.

---

For the full naming and threading rules that govern these decisions, see the ADRs in `docs/architecture/`.
