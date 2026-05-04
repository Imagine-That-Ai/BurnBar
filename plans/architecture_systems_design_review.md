# OpenBurnBar — Architecture & Systems Design Review

**Date:** 2026-04-27  
**Reviewer:** Architecture Systems Design Review (Sub-agent 1)  
**Branch:** `release/openburnbar-0.1.2-beta.12`  
**Lines of Swift (production):** ~42,000 (AgentLens: ~20K, Daemon: ~11K, Core: ~11K)  
**Lines of TypeScript (extension):** ~27 files in `extensions/openburnbar/`

---

## 0. Methodology

I inspected 30+ key files across all targets, sampled module boundaries, counted structural patterns (empty catches, `try?`, `@MainActor`, `Task.detached`, `@unchecked Sendable`), read the existing `ARCHITECTURE_REVIEW.md` and `TECH_DEBT_STRATEGY.md`, and cross-referenced their findings against the actual code. I did not read every one of the ~1,500 files — I sampled strategically at module boundaries, the 10 largest files, contract definitions, and the concurrency/state management layer.

---

## 1. Architecture Maturity: **7/10** (Startup-Grade, Trending Toward Production)

| Dimension | Score | Evidence |
|-----------|-------|---------|
| Module boundaries | 7/10 | Empty shell packages removed. Code colocated with owning modules. |
| Daemon concurrency | 8/10 | 11+ actors with clear dependency injection. State machine with validated transitions. |
| App concurrency | 4/10 | `@MainActor` default on I/O services. 17+ `Task.detached` escapes. 6 `@unchecked Sendable` in production. |
| Contract hygiene | 7/10 | Typed JSON-RPC (`BurnBarRPCContracts.swift`). 30+ method enum. But `BrowserLaunchAdapter` leaks AppKit into Core. |
| Error handling | 3/10 | 323 `try?` in `AgentLens/Services/` alone. Culture of silent degradation. |
| Test coverage (daemon) | 7/10 | 186 test functions across 14 files (~12K lines). MissionControl has 5,605-line test file. |
| Test coverage (app) | 3/10 | CloudSync sync() has zero coverage. Largest app services are untested in CI. |
| Observability | 6/10 | Structured daemon logging with categories. No distributed tracing or metrics pipeline. |
| Scalability planning | 4/10 | Risks documented but not addressed. In-memory vector index. N+1 query patterns. |

---

## 2. Key Strengths (With Specific File References)

### 2.1 Actor-Based Daemon Architecture
`BurnBarDaemonServer` (1,287 lines, `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`) wires 10+ dependencies in its `init()`, each with a category logger:
```swift
public actor BurnBarDaemonServer {
    private let configStore: BurnBarConfigStore
    private let usageRecorder: BurnBarUsageRecorder
    private let clientRegistry: BurnBarClientRegistry
    private let runService: BurnBarRunService
    private let toolingProxy: BurnBarToolingProxyService
    private let missionControlService: any BurnBarMissionControlServing
    private let indexedSearch: BurnBarIndexedSearchService?
    private let gatewayServer: BurnBarHTTPGatewayServer?
    private let rateLimiter: BurnBarRateLimiter
```
The socket accept loop runs on `Task.detached(priority: .background)` but dispatches into the actor for all mutable work. This is correct separation.

### 2.2 Run-State Machine With Validated Transitions
`BurnBarRunContracts.swift` (lines 55–110, `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/`) defines:
```swift
public static func canTransition(from: BurnBarRunPhase, to: BurnBarRunPhase) -> Bool
```
Every transition is validated. Invalid transitions throw `BurnBarRunStateMachineError.invalidTransition`. **Production-grade.**

### 2.3 HNSW Vector Index (From-Scratch Implementation)
`BurnBarHNSWVectorIndex.swift` (668 lines, `OpenBurnBarCore/Sources/OpenBurnBarCore/`) is a custom ANN index with:
- Binary format: magic header `OBHI`, version, little-endian layout
- Layered graph construction with `efConstruction`/`efSearch` beam widths
- Deterministic neighbor pruning with `mMax0 = 2*m`
- Separate readable (mmap-style) and writable index implementations
- `@unchecked Sendable` with explicit audit comments

This is not a wrapper. It's a custom nearest-neighbor engine in Swift. **Ambitious and competent.**

### 2.4 Provider Routing With Five-Dimensional Scorecard
`OpenBurnBarProviderRouter.swift` (733 lines, `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/`) implements:
- `capability` (0.20), `cost` (0.25), `latency` (0.15), `trust` (0.25), `policyFit` (0.15)
- Score normalization, ranking, winner selection with full breakdowns for debugging

**This is a real load-balancing layer, not prototype code.**

### 2.5 DAG Scheduler (Mission Control)
`BurnBarParallelDAGScheduler.swift` (932 lines, `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/MissionControl/`) is a parallel DAG execution engine with:
- Dependency gating (nodes start only when predecessors succeed)
- Concurrency limiting (`maxConcurrency`, default 4)
- Critical path tracking
- Terminal completion ordering with deterministic winner selection

### 2.6 Database Migration Safety
`OpenBurnBarDatabase.swift` (1,278 lines, `AgentLens/Services/DataStore/`) runs:
1. `PRAGMA integrity_check`
2. Pre-migration backup (`.backup.<timestamp>`)
3. Pruning old backups (keeps 5)
4. Then applies migrations via GRDB `DatabaseMigrator`

**Exactly the right order of operations for a shipped SQLite product.**

### 2.7 Well-Tested Daemon
`OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/` contains 186 test functions across 14 files, totaling ~12K lines of test code. `OpenBurnBarMissionControlServiceTests.swift` alone is 5,605 lines with 67 tests covering governance invariants, cross-cutting concerns, and lifecycle correctness.

### 2.8 Local-First Architecture
The docs are explicit: "Local SQLite plus daemon-owned local state are canonical. Firestore is an optional replication and collaboration plane." This is the right architectural stance for a privacy-sensitive developer tool.

---

## 3. Key Weaknesses (With Specific File References)

### ~~3.1 Module Boundaries Are a Fiction~~ (RESOLVED 2026-04-28)
The three empty shell packages (`OpenBurnBarIndex/`, `OpenBurnBarParsers/`, `OpenBurnBarPersistence/`) have been removed. Their actual code already lives in well-organized locations:
- Parsers in `AgentLens/Services/LogParser/`
- Persistence in `AgentLens/Services/DataStore/`
- Index logic in `OpenBurnBarCore/BurnBarHNSWVectorIndex.swift` and `OpenBurnBarDaemon/OpenBurnBarIndexedSearchService.swift`

### 3.2 `@unchecked Sendable` Is a Pattern, Not an Exception (HIGH)
**Evidence:** 6 occurrences in production code:
- `BurnBarHNSWWritableIndex` / `BurnBarHNSWReadableIndex` (vector index)
- `BurnBarMappedWritableIndex` / `BurnBarMappedReadableIndex` (persistent index)
- `BurnBarIndexedSearchService` (raw SQLite `OpaquePointer?` + mutable `snapshotContext`)
- `Locked<T>` (NSLock wrapper — correct but still unchecked)
- `TelemetryService`

While most have audit comments, the volume says: the team is **opting out of compiler-checked concurrency** rather than designing for it.

### 3.3 DataStore Facade Is a Bottleneck and a Leak (HIGH)
**Evidence:**
- `DataStoreActor` (`AgentLens/Services/DataStore/DataStore.swift`, lines 17–48) exposes 12 sub-stores as `nonisolated let`
- `DataStoreCoordinator` (`DataStoreCoordinator.swift`) duplicates the same 12 `nonisolated var` properties with zero added isolation
- 6 extension files (`DataStore+ConversationAccess.swift`, `+SearchAccess.swift`, etc.) contain 1,355 lines of pure pass-through wrappers
- `DataStoreCoordinator` carries ~30 deprecated computed property forwards to `DashboardUsageViewModel`
- Views call `dataStore.switcherStore.fetchAllProfiles()` directly, bypassing the actor

**Impact:** The facade adds boilerplate but no isolation. Schema changes require touching 6+ files.

### 3.4 Main-Thread I/O in the App (HIGH)
**Evidence:**
- `CLIBridge` (1,455 lines) is `@MainActor` despite spawning subprocesses and streaming SSE
- `CloudSyncService` (2,102 lines — from `TECH_DEBT_STRATEGY.md`) is `@MainActor` despite Firestore batch writes, SQLite reads, and file I/O
- `UsageAggregator` (501 lines) is `@MainActor @Observable` despite parsing JSONL and writing to GRDB
- `SearchService` (1,248 lines) is an `actor` (good!) but uses a `@MainActor` closure to snapshot context
- 17+ `Task.detached` calls across `AgentLens/Services/` to escape MainActor

### 3.5 Silent Failure Culture (HIGH)
**Evidence:**
- **323 `try?` occurrences in `AgentLens/Services/`** — on Firestore writes, daemon RPC calls, URL requests, parser invocations
- `BurnBarIndexedSearchService` silently degrades to lexical-only search if vector index fails to load
- `BurnBarRunService+Lifecycle.swift` (line ~127) silently skips checkpoint restore on route failure
- `BurnBarProviderExecutor` falls back to `inputHint = max(1, prompt.count / 4)` when usage is missing
- `AppLogger.silently()` used as control flow — conflates logging with error handling

### 3.6 Daemon Server Is a Monolithic Switch Statement (MEDIUM)
**Evidence:** `BurnBarDaemonServer.swift` (1,287 lines) contains a single `switch method` with 30+ cases (lines 275–700+), each decoding its own envelope, calling its service, encoding the response. There is no protocol-based dispatch, no middleware chain, no interceptors.

### 3.7 `OpenBurnBarCore` Has Platform Leakage (MEDIUM)
**Evidence:** `BrowserLaunchAdapter.swift` (590 lines, `OpenBurnBarCore/Sources/OpenBurnBarCore/`) imports `AppKit`:
```swift
#if canImport(AppKit)
import AppKit
#endif
```
The "shared core" dynamic library has an `#if canImport(AppKit)` guard. On macOS, it imports AppKit — a UI framework — into a supposedly contract-only shared library. This is **not** a clean dependency-free core.

### 3.8 Hand-Rolled HTTP/1.1 Gateway (MEDIUM)
**Evidence:** `OpenBurnBarHTTPGatewayServer.swift` (586 lines) implements a partial HTTP/1.1 parser on `Network.framework`:
```swift
private func parseRequestHead(_ data: Data) -> (method: String, path: String, contentLength: Int, headers: [String: String]?)?
```
It parses headers by scanning for `\r\n\r\n`, manually extracts `Content-Length`, and handles chunked reading. No Vapor, Hummingbird, SwiftNIO, or even `HTTPURLResponse`. Fragile to pipelined requests and chunked transfer encoding.

### 3.9 Run Service Extensions Break Cohesion (MEDIUM)
**Evidence:** `BurnBarRunService` is split across 4 files:
- `BurnBarRunService.swift` (630 lines) — actor definition, public API, registry
- `BurnBarRunService+Lifecycle.swift` (332 lines)
- `BurnBarRunService+Execution.swift` (453 lines) → `+ToolDispatch.swift` (was 279 lines, now in execution file)

Despite extensions, it has 25+ stored properties and 50+ methods. **God actor.**

### 3.10 Socket Auth Is Optional (HIGH)
**Evidence:** `BurnBarDaemonServer` checks `configuration.socketAuthToken` but the default `BurnBarDaemonConfiguration()` has `socketAuthToken: nil`. Any process on the Mac can connect to `/tmp/openburnbar.sock` and invoke RPC methods.

---

## 4. Circular Dependencies & Coupling Concerns

### 4.1 No True Circular Dependencies Found
I searched specifically for the app or daemon importing each other's modules. Result: **none found.** `OpenBurnBarCore` is imported by both `AgentLens` and `OpenBurnBarDaemon`, but the reverse is not true. The dependency graph is a clean tree:
```
OpenBurnBarCore (no external Swift deps)
    ↑                    ↑
AgentLens          OpenBurnBarDaemon
(Firebase, GRDB,    (GRDB, Sentry)
 GoogleSignIn,
 Sentry, ViewInspector)
```

### 4.2 However: Logical Coupling Is High
- Both app and daemon link GRDB independently — no single persistence module
- Both link Sentry independently
- Both import `OpenBurnBarCore` for contracts but also duplicate SQLite concerns
- `DataStore.swift` explicitly says: "Kept in this file (rather than DataStore/) because DataStoreCoordinator imports this module and moving it would require updating all import sites." This is a **self-acknowledged coupling anchor.**

### 4.3 Firebase Is Compile-Time Coupled
The app target cannot compile without Firebase, even for users who want offline-only mode. `AgentLensApp.init()` configures `FirebaseApp` unconditionally.

---

## 5. Will the Architecture Accelerate or Slow the Team Over 12–24 Months?

**Verdict: It will slow the team.** Here's why:

**Accelerators (working for you):**
- The daemon's actor-based architecture is solid and will scale with effort
- Typed RPC contracts make integration predictable
- Structured logging makes debugging fast
- Test infrastructure exists and is well-organized

**Decelerators (working against you):**
- `@MainActor`-heavy app layer means every new feature fights concurrency
- Silent failure culture means bugs are invisible, debugging is archaeology
- N+1 query patterns mean performance degrades linearly with data
- ~~Module boundary fiction confuses new engineers~~ (resolved 2026-04-28)
- Singleton service locator (15+ `.shared`) makes testing and refactoring expensive
- The vector index memory wall will force a rewrite before 1.0

**Prediction:** The next 6–12 months will feel productive as features land on the daemon's solid foundation. Months 12–24 will become grinding as the app layer's structural debt compounds — every new sync feature, every new dashboard card, every new search capability will require touching brittle, oversized files.

---

## 6. Hidden Rewrite Risks

### 6.1 Vector Index Memory Wall (WILL force rewrite)
At 100K chunks × 768 dimensions × 4 bytes = ~307MB for vectors alone, plus graph structure (~2×). The index is reloaded on every refresh. At 500K chunks, this will OOM on consumer Macs. The current design cannot scale to production data volumes.

### 6.2 HTTP Gateway (SHOULD be replaced)
The hand-rolled HTTP/1.1 parser will break on the first pipelined request, chunked transfer, or non-standard header. Replace with Vapor, Hummingbird, or SwiftNIO before exposing to external clients.

### 6.3 CloudSyncService (already flagged as in-progress rewrite)
At 2,102 lines with 0% sync coverage, this is the #1 candidate for a targeted rewrite. The `TECH_DEBT_STRATEGY.md` already acknowledges this.

### 6.4 Empty Module Packages (cleanup needed)
~~6.4 Empty Module Packages~~ (RESOLVED 2026-04-28): The empty shell packages have been removed.

---

## 7. Architectural Shortcuts Found

| Shortcut | File | Why It Matters |
|----------|------|----------------|
| Hand-rolled HTTP parser | `OpenBurnBarHTTPGatewayServer.swift` (586 lines) | Will break on edge cases. No framework-level safety. |
| Silent index degradation | `OpenBurnBarIndexedSearchService.swift` | Vector search silently becomes lexical-only. User has no signal. |
| Run checkpoint skip on route failure | `BurnBarRunService+Lifecycle.swift` (~line 127) | Runs disappear from registry with no user-facing signal. |
| `try?` on Firestore writes | `CloudSyncService.swift`, etc. (323 occurrences total) | Sync failures are data loss, not warnings. |
| Optional socket auth | `BurnBarDaemonServer.swift` | Local privilege escalation vector. |
| `@MainActor` on I/O services | `CLIBridge.swift`, `CloudSyncService.swift`, `UsageAggregator.swift` | Forces `Task.detached` escapes. Breaks structured concurrency. |
| `nonisolated` sub-store exposure | `DataStoreActor` (DataStore.swift) | Bypasses actor isolation. Views access database directly. |
| `AppKit` in Core library | `BrowserLaunchAdapter.swift` (line 3) | Shared core has platform dependency. Not a clean contract layer. |
| No approval timeout | `BurnBarRunService` | Stuck approvals block runs and DAG scheduling forever. |
| UsageRecorder in-memory only | `OpenBurnBarUsageRecorder.swift` | Recent usage events lost on daemon restart. |

---

## 8. Summary Table: Risk vs. Effort

| Risk | Severity | Effort | File(s) |
|------|----------|--------|---------|
| ~~Module boundary fiction~~ (resolved) | ~~Critical~~ | ~~L~~ | ~~`OpenBurnBarIndex/`, `Parsers/`, `Persistence/`~~ Removed 2026-04-28 |
| Vector index OOM at scale | **Critical** | M | `BurnBarHNSWVectorIndex.swift` |
| 323 `try?` in app services | **High** | M | 50+ files in `AgentLens/Services/` |
| `@MainActor` on I/O services | **High** | L | `CLIBridge.swift`, `CloudSyncService.swift`, `UsageAggregator.swift` |
| Daemon socket unauthenticated | **High** | S | `BurnBarDaemonServer.swift` |
| DataStore facade boilerplate | **High** | M | 8 files in `DataStore/` |
| AppKit in OpenBurnBarCore | **Medium** | S | `BrowserLaunchAdapter.swift` |
| Hand-rolled HTTP gateway | **Medium** | M | `OpenBurnBarHTTPGatewayServer.swift` |
| Monolithic daemon server switch | **Medium** | M | `BurnBarDaemonServer.swift` |
| God actor (RunService) | **Medium** | L | 4 `BurnBarRunService*` files |
| Approval hang forever | **Medium** | S | `BurnBarRunService+Execution.swift` |
| CloudSyncService zero coverage | **High** | XL | `CloudSyncService.swift` (2,102 lines) |
| N+1 query patterns | **Medium** | M | `SearchService.swift`, `UsageStore.swift` |

---

## 9. Bottom Line

OpenBurnBar is a **6/10 architecture** — startup-grade, trending toward production-grade, with evidence of real engineering ambition and talent. The daemon layer is genuinely well-structured with actors, state machines, a multi-factor router, a DAG scheduler, and a custom ANN index. These are real engineering artifacts, not prototype throwaways.

However, the codebase is carrying significant structural debt that will compound:
1. **The app layer has not kept up with the daemon's discipline.** `@MainActor` defaults, `Task.detached` escapes, and silent failure culture dominate.
2. ~~The module boundary fiction (three empty packages) undermines the architecture's credibility.~~ (Resolved 2026-04-28: empty packages removed.)
3. **Scalability walls are visible** at current data volumes — the vector index memory model, N+1 queries, and single-writer SQLite are all known problems without solutions in flight.
4. **The largest subsystems are the least tested** — `CloudSyncService` (2,102 lines, 0% sync coverage) and the app's I/O services are manual-QA-only.

**The system works today** for its beta audience. It will not scale gracefully without deliberate architectural hardening. The good news: the foundation (actors, GRDB, structured logging, typed contracts) is solid enough to support incremental hardening without a rewrite.

**Recommendation:** ~~Fix the module boundary fiction first (populate or delete the empty packages).~~ (Resolved 2026-04-28.) Move I/O off `@MainActor`. Add retry/timeout to the approval system. Address the vector index memory constraint before 1.0. Then prioritize CloudSync and MissionControl test coverage. This is a 3–6 month roadmap to production-grade architecture.
