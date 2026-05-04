# OpenBurnBar Architecture & Systems Design Review v2

**Date:** 2026-05-02
**Reviewer:** Senior Principal Engineer (Architecture Systems Design Review)
**Branch:** `release/openburnbar-0.1.2-beta.12`
**Scope:** Full repository — macOS app, daemon, shared core, mobile, extension, cloud functions
**Previous review:** April 27, 2026 (`ARCHITECTURE_REVIEW.md`)

---

## 0. Changes Since Previous Review

The April 27 review identified several architectural concerns. Here is what changed:

| Concern (Apr 27) | Status (May 2) | Evidence |
|---|---|---|
| Empty shell modules (OpenBurnBarIndex/Parsers/Persistence) | ✅ **Resolved** — removed | Modules no longer exist in project tree |
| CloudSyncService monolithic (2,102 lines) | ✅ **Improving** — extracted domain services | `CloudSync/` directory with `UsageSyncService`, `ConversationSyncService`, `ChatThreadSyncService`, `SessionLogSyncService` |
| No circuit breaker for Firestore | ✅ **Resolved** — `CloudSyncCircuitBreaker` | Proper half-open/closed/open states with configurable thresholds |
| No retry/backoff for sync | ✅ **Resolved** — `CloudSyncRetryPolicy` | Exponential backoff with jitter, 3-attempt default |
| `SearchService` was `@unchecked Sendable` + `NSLock` | ✅ **Resolved** — now a proper `actor` | `SearchService.swift` line ~21 |
| `RefreshOrchestrator` was `@MainActor` | ✅ **Resolved** — now an `actor` | `RefreshOrchestrator.swift` |
| `@MainActor` I/O still pervasive | ⚠️ **Ongoing** — still present | `CloudSyncService`, `UsageAggregator`, `ChatSessionController` still `@MainActor` |
| Silent failure culture | ⚠️ **Ongoing** — `try?` in 100+ files | Pervasive across views and services |
| Daemon giant switch | ⚠️ **Ongoing** — 50+ case arms, 1316 lines | `OpenBurnBarDaemonServer.swift` |
| MissionControl untested | ⚠️ **Ongoing** — 0 automated tests | `MissionControl/` directory |

**Net verdict:** Active, meaningful architectural improvement. The codebase is trending in the right direction. Roughly 40% of the April concerns are resolved, 40% are in progress, and 20% remain unaddressed.

---

## 1. Architecture Score: 7.0/10

**Previous score:** 6.0/10 (startup-grade, trending toward production)

**Rationale for the increase (+1.0):**
- CloudSync refactoring into domain services with circuit breaker and retry demonstrates genuine architectural discipline
- SearchService → actor, RefreshOrchestrator → actor show the team internalizing Swift concurrency best practices
- Empty shell modules removed — the codebase now honestly reflects where code lives
- CloudSyncCircuitBreaker is state-machine-correct (closed → open → halfOpen → closed), not a naive cooldown

**Why not 8.0+ yet:**
- The daemon's RPC dispatch is still a monolithic switch statement — the largest single-file architectural risk
- `@MainActor` I/O and `try?` culture still pervasive on the app side
- OpenBurnBarCore has platform-specific imports (AppKit, SwiftUI) defeating its purpose as a cross-platform library
- MissionControl (~8K lines) has zero automated tests

---

## 2. What Works Well Architecturally

### 2.1 Multi-Module Build Architecture
The project uses **XcodeGen** (`project.yml`) to generate the Xcode project, with three layered build units:

| Layer | Type | Build System | Dependencies |
|-------|------|-------------|--------------|
| `OpenBurnBarCore` | SPM dynamic library | Package.swift | Foundation only (mostly) |
| `OpenBurnBarDaemon` | SPM executable(s) | Package.swift | OpenBurnBarCore, GRDB, Sentry |
| `AgentLens` (OpenBurnBar app) | Xcode target via XcodeGen | project.yml | OpenBurnBarCore, GRDB, Firebase, GoogleSignIn, Sentry |

This separation means:
- The daemon can be built and tested independently (`swift test --package-path OpenBurnBarDaemon`)
- The core library can be shared between macOS, iOS, and Widget targets
- The app target only includes what's needed for UI + persistence + sync

### 2.2 Actor-Based Concurrency in the Daemon (Excellent)
The daemon is a showcase of structured actor concurrency. Every mutable subsystem is an actor:

```
BurnBarDaemonServer (actor) — 10+ dependencies, RPC dispatch, socket accept loop
  ├── BurnBarConfigStore (actor) — provider config CRUD
  ├── BurnBarUsageRecorder (actor) — in-memory usage ledger
  ├── BurnBarClientRegistry (actor) — client attach/detach/arbitration
  ├── BurnBarRunService (actor) — run lifecycle + registry
  │     ├── BurnBarProviderRouter (struct) — 5D scoring
  │     ├── BurnBarRunJournal (actor) — JSONL checkpoint persistence
  │     ├── BurnBarConnectorPlaneService (actor)
  │     └── BurnBarBrowserToolService (actor)
  ├── BurnBarMissionControlService (actor) — controller, missions, DAG
  ├── BurnBarIndexedSearchService (@unchecked Sendable) — semantic search
  ├── BurnBarHTTPGatewayServer (actor) — Cursor BYOK routing
  ├── BurnBarRateLimiter (actor) — per-client rate limiting
  └── BurnBarToolingProxyService (struct) — facade over connector+browser planes
```

**Evidence:** `OpenBurnBarDaemonServer.swift`, lines 14–68. Every stored dependency is an actor with a dedicated category logger.

### 2.3 Explicit State Machine with Validated Transitions
`BurnBarRunStateMachine` (`Contracts/BurnBarRunContracts.swift`, lines 55–110) defines 9 phases with a complete transition matrix:

```swift
public static func canTransition(from: BurnBarRunPhase, to: BurnBarRunPhase) -> Bool {
    switch (from, to) {
    case (.idle, .planning): return true
    case (.planning, .awaitingApproval), (.planning, .executingTool), ...: return true
    case (.failed, .planning), (.failed, .cancelled): return true
    default: return false
    }
}
```

Invalid transitions throw `BurnBarRunStateMachineError.invalidTransition`. This is production-grade.

### 2.4 Provider Routing with Five-Dimensional Scoring
`BurnBarProviderRouter.swift` (733 lines) scores routes across capability (0.20), cost (0.25), latency (0.15), trust (0.25), and policyFit (0.15). All dimensions are normalized to 0.0–1.0. The full `BurnBarRouteScoreBreakdown` preserves raw values for debugging. This is not a toy load balancer — it is an intentionally designed routing layer.

### 2.5 CloudSync Refactoring (New Since April)
The monolithic `CloudSyncService` (still present but being deprecated at 787 lines) has been supplemented by a clean domain-driven architecture:

```
CloudSyncCoordinator (@MainActor, @Observable) — orchestrator
  ├── UsageSyncService       — uploads pending TokenUsage → Firestore
  ├── ConversationSyncService — uploads conversation metadata
  ├── ChatThreadSyncService   — uploads chat threads/messages
  ├── SessionLogSyncService   — uploads session log markdown
  └── QuotaSnapshotSyncService — uploads provider quota snapshots

Supporting infrastructure:
  ├── CloudSyncContext (@MainActor) — shared state (dataStore, account, settings, circuitBreaker)
  ├── CloudSyncCircuitBreaker (actor) — closed/open/halfOpen state machine
  ├── CloudSyncRetryPolicy (Sendable) — exponential backoff + jitter
  ├── CloudSyncErrorClassifier — retryable vs terminal vs permission-denied
  └── CloudSyncFirestoreGateway — protocol for injectable Firestore (live + fake)
```

**Evidence:** `CloudSync/` directory. Each domain service is single-responsibility, has its own `isSyncing`/`lastSyncDate`/`lastSyncError` state, and uses shared infrastructure (circuit breaker, retry policy).

### 2.6 HNSW Vector Index (Custom Implementation)
`BurnBarHNSWVectorIndex.swift` (668 lines) is a from-scratch Hierarchical Navigable Small World ANN index with:
- Custom binary format (`OBHI` magic, v2 now supports scalar quantization)
- Layered graph construction with beam search
- Configurable `efConstruction`/`efSearch` parameters
- Scalar quantization (Float32 → UInt8, ~4× memory reduction)
- Memory budget cap via `BurnBarSemanticSearchConfig`

This is ambitious and competently implemented.

### 2.7 Database Integrity
`OpenBurnBarDatabase.swift` runs `PRAGMA integrity_check` before migrations, creates a backup (`.backup.<timestamp>`), prunes to keep 5 backups, then applies migrations. This is the correct order of operations for a shipped product.

### 2.8 RPC Protocol Contracts Are Clean
`BurnBarRPCContracts.swift` defines a clean request/response envelope system:

```swift
BurnBarRPCRequestEnvelope<Params>     → { id, method, authToken?, params }
BurnBarRPCResponseEnvelope<Result>     → { id, protocolVersion, result?, error? }
```

All 50+ RPC methods are enumerated in `BurnBarRPCMethod` with namespaced keys (`daemon.health`, `run.create`, `daemon.mission.approve`). The wire format is well-defined.

### 2.9 Extension Architecture (TypeScript)
The VS Code/Cursor extension (`extensions/openburnbar/`) is well-structured:
- `src/extension.ts` — activation, deactivation, dependency injection
- `src/daemon/` — daemon client + repair service
- `src/state/` — controller state machine
- `src/views/` — tree views (health, runs, run detail)
- `src/webview/` — webview panels
- `src/workspace/` — workspace companion + RPC bridge
- `test/` — 15+ test files covering controller, projections, repair, webview, workspace

The extension has **real test coverage** (unlike the daemon's MissionControl), which is a credit to the team.

---

## 3. What Is Architecturally Concerning

### 3.1 Daemon RPC Dispatch Is a 50-Case Switch Statement (Critical)
**File:** `OpenBurnBarDaemonServer.swift`, 1,316 lines
**Pattern:** 50+ `case .xxx:` arms, each with the same boilerplate:

```swift
case .health:
    _ = BurnBarHealthRequest()
    logger.debug("rpc_request_received", metadata: ["request_id": request.id, "method": method.rawValue])
    let response = BurnBarRPCResponseEnvelope(id: request.id, protocolVersion: ..., result: healthResponse())
    return encode(response)
case .catalog:
    _ = BurnBarCatalogRequest()
    // repeated boilerplate...
    return encode(response)
// ... 48 more identical patterns
```

**Why this is a problem:**
- Adding an RPC method requires editing this file — a single point of merge contention
- No middleware chain (auth, logging, rate-limiting are ad-hoc inside each arm)
- No protocol-based dispatch (every handler is a function, not a conforming type)
- The file has grown from structural debt into architectural debt

**What should exist:** A protocol `BurnBarRPCHandler` with `func handle(_ request: Data) async -> Data`, registered in a dictionary keyed by method. The switch would become a simple lookup.

### 3.2 OpenBurnBarCore Has Platform-Specific Dependencies (High)
**Evidence:**
- `SharedModels/AgentProvider.swift` imports `SwiftUI` (for `Color`/`Image` extensions)
- `BrowserLaunchAdapter.swift`, `SwitcherBrowserLaunchService.swift`, `SwitcherCLILAunchService.swift`, `ChromeProfileDiscovery.swift` all import `AppKit`

**Why this is a problem:**
- `OpenBurnBarCore` is advertised as a cross-platform shared library (`platforms: [.macOS(.v14), .iOS(.v17)]`)
- iOS targets import this module — SwiftUI is fine for iOS, but AppKit imports will fail
- The AppKit files are macOS-only concerns that belong in AgentLens, not in Core
- This creates a stealth platform dependency that will cause build failures if an iOS engineer adds code

**What should exist:** Split platform-specific code into `OpenBurnBarCoreMac` (AppKit) and keep `OpenBurnBarCore` purely Foundation-based. Or move the AppKit files into AgentLens.

### 3.3 BurnBarRunService Is a God Actor (High)
**File:** `OpenBurnBarRunService.swift` (630 lines) + 3 extension files (2,700 lines total)
**Stored properties:** 16 dependencies + 7 mutable state fields
**Public API:** 15 methods (createRun, listRuns, getRun, pollRuns, cancelRun, retryRun, executeTool, submitToolResult, approveRun, claimControl...)

The type is split across extension files to keep individual files under 1,000 lines, but they are all `extension BurnBarRunService`. The type still has:
- 23 total stored properties
- 50+ methods
- Responsibilities spanning: run lifecycle, tool dispatch, workspace bridging, agent loop orchestration, recovery, policy enforcement, journal persistence

**Why this is a problem:** Every extension file can access every stored property. The separation is cosmetic, not architectural. A bug in `+ToolDispatch.swift` can corrupt state managed in `+Lifecycle.swift`.

### 3.4 `@MainActor` I/O + `Task.detached` Escapes (High)
**Evidence:** Across AgentLens:
- `CloudSyncService` — `@MainActor`, does Firestore batch writes
- `UsageAggregator` — `@MainActor`, parses JSONL files, writes to GRDB
- `ChatSessionController` — `@MainActor`, streams SSE from CLI subprocesses
- `CloudSyncCoordinator` — `@MainActor`, orchestrates all sync domains

These escape via `Task.detached` (17+ occurrences across the app), breaking structured concurrency.

**Why this is a problem:**
- `Task.detached` has no parent-child cancellation — tasks outlive their initiating context
- Cannot use `task.cancel()` or `withTaskCancellationHandler` reliably
- Makes memory management unpredictable
- Prevents Swift concurrency diagnostics from catching real races

### 3.5 Silent Failure Culture Persists (Medium-High)
**Evidence:**
- `try?` present in **100+ files** across AgentLens
- `AppLogger.silently()` / `AppLogger.silentFailure()` used as control flow
- In views: `if let x = try? ...` used as a conditional — failure is indistinguishable from nil
- In services: `try? dbQueue.write { ... }` silently drops write errors

**Why this is a problem:**
- A write failure in UsageAggregator silently loses cost data
- A parse failure in a LogParser silently skips an entire session
- A read failure in a view silently shows empty state (indistinguishable from "no data")
- The user has zero signal that something went wrong, and the developer has zero telemetry

### 3.6 Mobile App Is Cloud-First, Breaking the Local-First Stance (Medium)
**Evidence:**
- `OpenBurnBarMobile/` has no local SQLite — all data flows through `FirestoreRepository`
- The macOS architecture doc states: "Local SQLite plus daemon-owned local state are canonical"
- The mobile app cannot function without Firebase Auth + Firestore connectivity
- iOS Widget (`OpenBurnBarWidget/`) depends on `FirestoreRepository` for data

**Why this is a problem:**
- The mobile experience degrades to "nothing works" without internet
- The architecture promises local-first but the mobile app delivers cloud-first
- Widget refresh is gated on Firestore latency, not local cache
- This is a legitimate architectural drift from the stated north star

**Mitigation:** `LiveCloudReader.swift` (21,605 bytes) suggests cloud-reading infrastructure. An offline-first architecture would need a local SQLite mirror (possibly the `OpenBurnBarCore` database, shared via iCloud or direct device sync).

### 3.7 MissionControl Has Zero Automated Tests (Medium)
**Evidence:** `MissionControl/` directory:
- `BurnBarParallelDAGScheduler.swift` — 933 lines, zero tests
- `MissionControlService.swift` — 59,677 bytes (one of the largest files in the project), zero tests
- `MissionControlStore.swift` — 53,411 bytes, zero tests
- `MissionControlSummaryEnricher.swift` — 14,779 bytes, zero tests

**Why this is a problem:**
- MissionControl is the mission-critical orchestration layer for controller runtime
- The DAG scheduler handles dependency ordering, concurrency limits, and critical path tracking
- A bug here could silently stall missions, double-execute work, or lose results
- The extension has test coverage; the daemon's most complex subsystem doesn't

### 3.8 Hand-Rolled HTTP/1.1 Parser in Gateway (Medium)
**Evidence:** `OpenBurnBarHTTPGatewayServer.swift` (586 lines) implements HTTP/1.1 parsing on raw `Network.framework` connections:
```swift
private func parseRequestHead(_ data: Data) -> (...) {
    // scans for \r\n\r\n, extracts Content-Length
}
private func readLoop(on connection: NWConnection, buffer: Data, ...)
```

**Why this is a problem:**
- No support for chunked transfer encoding
- No support for HTTP/2 or keep-alive
- A malformed header, pipelined request, or oversized body will break parsing
- Reimplementing HTTP when SwiftNIO, Vapor, or Hummingbird exist is a "not invented here" risk
- Production HTTP servers have decades of edge-case hardening that this parser lacks

### 3.9 Vector Index Corruption = Silent Degradation (Medium)
**Evidence:** `BurnBarHNSWIndexFormat.parseHeader` throws for any corruption (wrong magic, wrong version, short data). The caller catches and sets `indexedSearch = nil`:
```swift
do {
    self.indexedSearch = try BurnBarIndexedSearchService(...)
} catch {
    logger.warning("indexed_search_init_failed", ...)
    self.indexedSearch = nil
}
```

**Why this is a problem:** A disk-full condition, partial write, or crash during index save silently disables semantic search. The user gets lexical-only search with no explanation. There is no automatic repair attempt, no degraded-mode indicator in the UI, and no index corruption alert.

### 3.10 DataStoreActor Leaks Through `nonisolated let` (Low-Medium)
**Evidence:** `DataStore.swift`, lines 17–28:
```swift
actor DataStoreActor {
    nonisolated let usageStore: UsageStore
    nonisolated let conversationStore: ConversationStore
    nonisolated let searchIndexStore: SearchIndexStore
    // ... 9 more stores
}
```

Combined with `DataStoreCoordinator` exposing these as:
```swift
nonisolated var usageStore: UsageStore { actor.usageStore }
```

**Why this is a problem:** Any view can call `dataStore.usageStore.fetchAllUsage()` directly, bypassing the actor entirely. The `DataStoreCoordinator` facade adds boilerplate (6 extension files, 1,355 lines of pass-through wrappers) but provides no isolation benefit. Schema changes require touching 6+ files.

---

## 4. Will This Architecture Accelerate or Slow the Team Over 12–24 Months?

**Verdict: Accelerate, with caveats.**

**Reasons it will accelerate:**
1. **The daemon's actor model is correct.** Isolated mutable state per actor means new subsystems can be added as actors with clear ownership boundaries. The pattern is established and consistently applied.
2. **CloudSync refactoring shows the team can extract domain services.** The pattern is proven — if the daemon server needs to be refactored, the team has demonstrated the skill.
3. **The RPC protocol is well-defined.** Adding a new endpoint requires: (a) add a case to `BurnBarRPCMethod`, (b) add a handler on `missionControlService`/`runService`, (c) add a case arm in the switch. This is tedious but mechanically simple.
4. **OpenBurnBarCore is genuinely reusable.** The mobile app and widget already share contracts through it. Adding another surface (e.g., a web dashboard) would reuse the same types.
5. **GRDB is a fast, well-maintained SQLite wrapper.** It will not become a bottleneck at current scale.

**Reasons it will slow the team:**
1. **The daemon switch statement is brittle.** Every merge touching `OpenBurnBarDaemonServer.swift` will conflict. The file cannot scale to 100+ methods.
2. **`try?` culture makes bugs invisible.** When a feature "sometimes doesn't work," the root cause is buried in a silent error path. Debugging time increases linearly with codebase size.
3. **MissionControl complexity with zero tests.** Any change to mission scheduling, DAG execution, or controller state needs manual testing that will slow velocity.
4. **`@MainActor` + `Task.detached` is a footgun.** New engineers will cargo-cult the pattern without understanding structured concurrency, creating invisible task leaks.

---

## 5. Hidden Rewrite Risks

### 5.1 If the Daemon Server Grows to 100+ Methods
The switch statement pattern will collapse. Each case arm is 15–25 lines. At 100 methods, that's 2,000+ lines of repetitive dispatch. The risk is not gradual — it's a **step function**: once the file hits unmanageable size, the refactor becomes urgent and expensive.

**Mitigation:** Implement protocol-based handler dispatch now, while the refactor is mechanical.

### 5.2 If Semantic Search Data Exceeds Memory Budget
The vector index already has configurable caps, but the caps are a **stopgap**, not a solution. A 256MB budget at 768-dim UInt8 vectors ≈ 340K vectors. At current indexing rates, this will be hit within months. The fallback path (streaming exact search) is O(n) per query.

**Mitigation:** True mmap support (not `Data(contentsOf:)`), on-disk graph traversal, or embedding dimension reduction.

### 5.3 If Firestore Costs Scale Non-Linearly
The mobile app is entirely cloud-dependent. If daily active users (DAU) scales, Firestore reads/writes per user per day will scale linearly. At 10K DAU with 100 reads/day each, that's 1M reads/day, which can cost $300+/month on Firestore alone.

**Mitigation:** Local SQLite on iOS with periodic sync, rather than live Firestore queries for every view.

### 5.4 If Provider API Keys Need Rotation
The daemon stores provider API keys in Keychain (`BurnBarConfigStore` + `OpenBurnBarConnectorSecretStore`). If a provider requires key rotation (e.g., OpenAI deprecating an API key format), there's no key rotation workflow. The daemon needs to support multiple active keys per slot with a transition period.

### 5.5 If iOS Sandbox Restrictions Tighten
The mobile app's `LiveCloudReader` does network calls through Firebase. If Apple tightens its networking privacy requirements (App Tracking Transparency, Private Relay), the mobile app's cloud-first architecture may need fundamental changes that a local-first architecture would have avoided.

---

## 6. Concrete Examples of Architectural Patterns

### Pattern A: Clean Domain Extraction (CloudSync)
```
Before: CloudSyncService (787 lines, MainActor, does everything)
After:
  CloudSyncContext (shared state)
    ├── UsageSyncService (~100 lines)
    ├── ConversationSyncService (~110 lines)
    ├── ChatThreadSyncService (~110 lines)
    ├── SessionLogSyncService (~330 lines)
    └── QuotaSnapshotSyncService (~100 lines)
  + CloudSyncCircuitBreaker (actor)
  + CloudSyncRetryPolicy (struct, Sendable)
```

**Why this pattern works:** Each service has one responsibility, its own error state, and uses shared infrastructure (circuit breaker, retry). The coordinator (`CloudSyncCoordinator`) composes them.

### Pattern B: Actor Dependency Injection (Daemon Server)
```swift
public init(
    configuration: BurnBarDaemonConfiguration = BurnBarDaemonConfiguration(),
    configStore: BurnBarConfigStore? = nil,
    usageRecorder: BurnBarUsageRecorder? = nil,
    clientRegistry: BurnBarClientRegistry? = nil,
    runService: BurnBarRunService? = nil,
    missionControlService: (any BurnBarMissionControlServing)? = nil,
    rateLimiter: BurnBarRateLimiter? = nil
)
```

**Why this pattern works:** Every dependency is injectable. Tests can provide mocks. Defaults are constructed lazily with correct wiring. The protocol `BurnBarMissionControlServing` enables test doubles.

### Pattern C: Explicit State Machine (Run Contracts)
```swift
BurnBarRunStateMachine.canTransition(from: .planning, to: .awaitingApproval) // true
BurnBarRunStateMachine.canTransition(from: .idle, to: .executingTool)        // false
BurnBarRunStateMachine.validatedTransition(from: .idle, to: .executingTool)  // throws
```

**Why this pattern works:** The transition matrix is a single source of truth. Invalid transitions are programmer errors caught at runtime with clear error messages. Adding a new phase requires editing exactly one switch statement.

### Pattern D: Facade Leak (DataStoreActor + DataStoreCoordinator)
```swift
// DataStoreActor (actor) — correct isolation
actor DataStoreActor {
    nonisolated let usageStore: UsageStore  // LEAK: accessible without await
}

// DataStoreCoordinator (MainActor facade) — duplicates the leak
@MainActor
final class DataStoreCoordinator {
    nonisolated var usageStore: UsageStore { actor.usageStore }  // LEAK again
}

// View code — bypasses both
dataStore.usageStore.fetchAllUsage()  // No await, no actor, no MainActor
```

**Why this pattern is broken:** The `nonisolated let` defeats actor isolation. Six extension files of pass-through methods add boilerplate without benefit. Views can directly access stores.

### Pattern E: Anti-Pattern — Task.detached Escape Hatch
```swift
// In @MainActor CloudSyncService:
func uploadPending() async {
    Task.detached(priority: .utility) { [weak self] in
        guard let self else { return }
        // Database I/O here, running on an untracked task
    }
}
```

**Why this pattern is broken:** The task is fire-and-forget. No parent-child relationship. No structured cancellation. `[weak self]` prevents retain cycles but doesn't prevent the task from running after the view is gone.

---

## 7. Architecture Debt Prioritization

| # | Debt Item | Impact | Effort | When to Fix |
|---|-----------|--------|--------|------------|
| 1 | Daemon server switch → protocol dispatch | Merge conflicts, scaling ceiling | M (2–3 days) | Before 50+ methods |
| 2 | MissionControl test coverage | Risk of silent mission failures | XL (1–2 weeks) | Before 1.0 |
| 3 | `try?` culture → typed error handling | Debugging cost, user trust | L (ongoing) | Gradual, per-service |
| 4 | `@MainActor` I/O → actors | Structured concurrency integrity | L (per-service) | Alongside #3 |
| 5 | OpenBurnBarCore platform deps | iOS build risk | S (1 day) | Before iOS release |
| 6 | Mobile local-first gap | Offline UX, cost scaling | XL (weeks) | Post-1.0 |
| 7 | HTTP gateway → framework | Security, protocol compliance | M (3–5 days) | When gateway usage grows |
| 8 | DataStoreActor facade leak | Boilerplate reduction | M (2–3 days) | Opportunistic |

---

## 8. Bottom Line

OpenBurnBar is a **7.0/10** — a high-velocity, high-ambition project with genuine technical depth in its daemon layer, actively paying down architectural debt demonstrated in the CloudSync refactoring.

**The architecture is good enough to ship beta.12 and accelerate toward 1.0.** The foundation (actors, GRDB, explicit state machines, well-defined RPC contracts) is solid. The team has shown it can refactor monoliths into domain services.

**The three things that would take this to 8.0+:**
1. Protocol-based RPC handler dispatch in the daemon server
2. Test coverage for MissionControl (at minimum, the DAG scheduler)
3. Move `@MainActor` I/O services to actors with proper isolation

**The architecture will not require a rewrite.** It will require continued incremental hardening — the same pattern the team is already executing.

**Comparative grade:** This is better architecture than 90% of indie macOS apps and on par with well-funded seed-stage startups. It is not yet Linear or Notion grade, but it is trending there faster than most projects at this stage.
