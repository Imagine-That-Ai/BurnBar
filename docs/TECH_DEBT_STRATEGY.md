# OpenBurnBar Tech Debt Strategy

**Date:** 2026-04-22  
**Scope:** AgentLens (macOS app), OpenBurnBarDaemon, OpenBurnBarCore, VS Code/Cursor extension  
**Method:** Coordinated swarm audit across code quality, architecture, testing, reliability/ops, security, and performance dimensions  
**Lines of Swift:** ~31,000 (AgentLens: ~20K, Daemon: ~11K, Core: ~11K)  
**Test Files:** 88 active XCTest suites + 12 daemon tests + 12 core tests  

---

## 1. Executive Summary

The biggest truth about this codebase: **OpenBurnBar is a high-velocity product that has outgrown its initial architecture.** The team has shipped an impressive amount of functionality (daemon-first local runtime, hybrid search, Firestore sync, mission control, Cursor extension), but the code has accumulated structural debt at a faster rate than the foundation has been hardened. The result is a system that works well in the happy path but has brittle failure modes, oversized modules, and significant test blind spots in the most complex subsystems.

**The debt is concentrated in four areas:**
1. **Giant service monoliths** — Four files exceed 1,000 lines and violate single responsibility (CloudSyncService: 2,102; CLIBridge: 1,456; UsageAggregator: 1,250; SearchService: 1,203).
2. **Main-thread I/O** — Four major services are pinned to `@MainActor` despite doing heavy database, network, and filesystem work.
3. **Silent failure culture** — 252 empty `catch {}` blocks, pervasive `try?`, and `AppLogger.silently()` used as control flow swallow errors across sync, parsing, and IPC paths.
4. **Test parking** — The most critical daemon and sync logic is either untested or parked in `AgentLensTests/Parked/`, excluded from CI.

The good news: the architecture docs are clear, the DataStore extraction is already partially complete, logging infrastructure exists, and the team has demonstrated discipline in docs and release automation. The debt is **payable without a rewrite** if tackled in the right order.

---

## 2. Top Debt Themes

### Theme A: "Manager/Service/Store" — A Naming Convention Without Boundaries
There is no consistent rule for what a Manager vs Service vs Store does. `AccountManager` and `SettingsManager` are mutable singletons. `CloudSyncService` and `SearchService` are `@MainActor` monoliths. `DataStore` is a facade over 12 sub-stores. `CLIBridge` is a class with no suffix. This inconsistency makes it impossible for new engineers to infer lifecycle, thread-safety, or responsibility from a type name.

### Theme B: `@MainActor` as a Default, Not a Deliberate Choice
`CloudSyncService`, `SearchService`, `UsageAggregator`, `ProjectionPipelineService`, `ChatSessionController`, and 30+ other types are pinned to `@MainActor` despite doing database I/O, network calls, file parsing, and embedding pipelines. The codebase then uses `Task.detached` (17+ occurrences) to escape the main actor, which breaks structured concurrency, cancellation, and task hierarchies.

### Theme C: The `DataStore` Facade Is a Bottleneck and a Leak
`DataStore` and `DataStoreActor` expose 12 sub-stores as `nonisolated` properties, bypassing actor isolation. Views directly call `dataStore.switcherStore.fetchAllProfiles()` and `dataStore.dbQueue.read`. The main `DataStore` class still carries ~30 deprecated computed property forwards to `DashboardUsageViewModel`. Six extension files (`DataStore+ConversationAccess.swift`, etc.) contain 1,355 lines of pure pass-through wrappers that add zero behavior.

### Theme D: Silent Failures Are the Default Error Mode
252 empty `catch {}` blocks. `try?` used on Firestore writes, daemon RPC calls, URL session requests, and parser invocations. `AppLogger.silently()` returns a fallback on any error, conflating logging with control flow. When sync fails, parsing fails, or the daemon hangs, the user sees "nothing happens" with no diagnostic.

### Theme E: Cloud/Sync Logic Is the Biggest Blind Spot
`CloudSyncService` (2,102 lines) has 56 tests, but **zero** tests exercise the actual `sync()` method, Firestore upload/download, 3-way merge, or optimistic concurrency. `CollaborationSyncService` (1,189 lines) is a no-op stub. The shared-artifact sync layer — the most complex distributed-system logic in the app — is completely unverified in CI.

### Theme F: The Daemon Is a Black Box to CI
`OpenBurnBarDaemonManager` (1,771 lines) has no active tests (comprehensive tests exist in `Parked/`). The MissionControl subsystem (30 source files, ~8,000 lines) has zero dedicated tests. The daemon's core scheduling, DAG execution, state merging, and notification logic is entirely manual-QA dependent.

### Theme B: `@MainActor` as a Default, Not a Deliberate Choice
`CloudSyncService`, `SearchService`, `UsageAggregator`, and `ProjectionPipelineService` are all `@MainActor` despite doing database I/O, network calls, and file parsing. The codebase then uses `Task.detached` (17+ occurrences) to escape the main actor, which breaks structured concurrency, cancellation, and task hierarchies.

### Theme C: The `DataStore` Facade Is a Bottleneck
`DataStore` and `DataStoreActor` expose 12 sub-stores as `nonisolated` properties, bypassing actor isolation. The main `DataStore` class still carries ~30 deprecated computed property forwards to `DashboardUsageViewModel`. Six extension files (`DataStore+ConversationAccess.swift`, etc.) contain 1,355 lines of pure pass-through wrappers that add zero behavior.

### Theme D: Silent Failures Are the Default Error Mode
252 empty `catch {}` blocks. `try?` used on Firestore writes, daemon RPC calls, URL session requests, and parser invocations. `AppLogger.silently()` returns a fallback on any error, conflating logging with control flow. When sync fails, parsing fails, or the daemon hangs, the user sees "nothing happens" with no diagnostic.

### Theme E: Cloud/Sync Logic Is the Biggest Blind Spot
`CloudSyncService` (2,102 lines) has 56 tests, but **zero** tests exercise the actual `sync()` method, Firestore upload/download, 3-way merge, or optimistic concurrency. `CollaborationSyncService` (1,189 lines) is a no-op stub. The shared-artifact sync layer — the most complex distributed-system logic in the app — is completely unverified in CI.

### Theme F: The Daemon Is a Black Box to CI
`OpenBurnBarDaemonManager` (1,771 lines) has no active tests (comprehensive tests exist in `Parked/`). The MissionControl subsystem (30 source files, ~8,000 lines) has zero dedicated tests. The daemon's core scheduling, DAG execution, state merging, and notification logic is entirely manual-QA dependent.

### Theme G: Firebase/Firestore Leaked into Core Logic
Firebase is documented as "optional replication," but the app target cannot compile without `FirebaseAuth` and `FirebaseFirestore`. `CloudSyncService` constructs Firestore batches directly. `AccountManager` calls `Auth.auth()` directly. `AgentLensApp` configures `FirebaseApp` in `init()`. Core sync logic is inseparable from Firestore semantics, preventing offline-only builds and vendor migration.

### Theme H: 15+ Singletons Create a Manual Service Locator
`AccountManager.shared`, `SettingsManager.shared`, `WindowManager.shared`, `OpenBurnBarDaemonManager.shared`, `CursorConnectorManager.shared`, `DailyDigestManager.shared`, `ThemeManager.shared`, `ProviderAPIKeyStore.shared`, `ConversationIndexer.shared`, and others. There is no inversion of control. `AgentLensApp.init()` manually wires 15+ concrete dependencies. `WindowManager.openDashboard()` takes 8 parameters. Every new dependency requires updating 10+ call sites.

### Theme I: Views Know About Database Queues and Sub-Stores
`AccountSwitcherSettingsView+DataOperations.swift`, `DashboardQuickSwitchView.swift`, and `PopoverQuickSwitchView.swift` all call `dataStore.switcherStore.fetchAllProfiles()` directly. `DownloadSyncService` accesses `context.dataStore.dbQueue`. Views are not testable without a real SQLite database, and schema changes break UI code.

### Theme J: State Ownership Confusion (App / Daemon / Cloud)
There is no clear single source of truth. The daemon writes to a JSONL ledger; the aggregator reads it and writes to SQLite; the sync service uploads from SQLite to Firestore. `DataStore` caches `usages` in memory. `UsageAggregator` modifies `dataStore.usages` directly. `CloudSyncService` owns `isSyncing` and `lastSyncError` but persists to `dataStore`. `AgentLensApp` manually coordinates `aggregator.refreshAll()`, `daemonManager.refreshHealth()`, and `operatingLayer.refreshControllerRuntime()` via a periodic `Task`.

---

## 3. Ranked Debt Register

| Rank | Title | Category | Sev | Scope | Effort | Owner | Timing |
|---|---|---|---|---|---|---|---|
| 1 | `fatalError` on DataStore init bricks app | Reliability | **Critical** | Systemic | M | Platform | **Fix immediately** |
| 2 | CloudSyncService is a 2,102-line god object | Architecture | **Critical** | Cross-cutting | XL | Backend | Scheduled soon |
| 3 | `@MainActor` on I/O-heavy services | Architecture | **Critical** | Cross-cutting | L | Platform | Scheduled soon |
| 4 | Zero sync-logic tests for CloudSyncService | Testing | **Critical** | Cross-cutting | XL | Backend | Scheduled soon |
| 5 | DaemonManager tests parked = zero CI coverage | Testing | **Critical** | Cross-cutting | M | Platform | Fix immediately |
| 6 | MissionControl subsystem entirely untested | Testing | **Critical** | Systemic | XL | Backend | Scheduled soon |
| 7 | CursorConnectorManager has no instance tests | Testing | **Critical** | Local | L | Full-stack | Scheduled soon |
| 8 | 252 empty `catch {}` blocks swallow errors | Code Quality | **High** | Systemic | L | Full-stack | Scheduled soon |
| 9 | DataStore facade + 1,355 lines of pass-throughs | Architecture | **High** | Systemic | XL | Backend | Scheduled soon |
| 10 | CLIBridge monolith (1,456 lines, 8 concerns) | Code Quality | **High** | Cross-cutting | L | Full-stack | Scheduled soon |
| 11 | UsageAggregator god object (1,250 lines, 18 deps) | Code Quality | **High** | Cross-cutting | XL | Backend | Scheduled soon |
| 12 | Parser duplication (13 parsers, ~3,000 lines) | Code Quality | **High** | Cross-cutting | L | Backend | Scheduled soon |
| 13 | `nonisolated` store exposure on `DataStoreActor` | Architecture | **High** | Cross-cutting | M | Platform | Scheduled soon |
| 14 | Socket RPC client has no timeout | Reliability | **High** | Cross-cutting | M | Platform | Scheduled soon |
| 15 | Release pipeline ships without smoke tests | Reliability | **High** | Systemic | M | Infra | Fix immediately |
| 16 | No database migration rollback path | Reliability | **High** | Cross-cutting | L | Platform | Scheduled soon |
| 17 | Pervasive `try?` abuse (1,470+ matches) | Reliability | **High** | Systemic | L | Full-stack | Scheduled soon |
| 18 | Daemon has no crash recovery / heartbeat | Reliability | **High** | Cross-cutting | L | Platform | Scheduled soon |
| 19 | SwiftUI leaked into service/database layers | Architecture | **High** | Cross-cutting | M | Frontend | Opportunistic |
| 20 | SettingsManager singleton with 80+ mutable properties | Code Quality | **High** | Cross-cutting | L | Frontend | Scheduled soon |
| 21 | `Task.detached` abuse breaks structured concurrency | Architecture | **High** | Cross-cutting | L | Platform | Scheduled soon |
| 22 | Zero weak self in CloudSyncService / SearchService | Performance | **High** | Cross-cutting | S | Platform | Scheduled soon |
| 23 | Semantic search reloads all embeddings into memory on every refresh | Performance | **Critical** | Systemic | L | Backend | Scheduled soon |
| 24 | Search hydration N+1 conversation fetches | Performance | **Critical** | Local | S | Backend | Scheduled soon |
| 25 | SettingsManager 50+ synchronous UserDefaults writes per mutation | Performance | **Critical** | Cross-cutting | M | Frontend | Scheduled soon |
| 26 | Dashboard snapshot builder ~20 queries every 8s with no caching | Performance | **High** | Local | M | Frontend | Scheduled soon |
| 27 | Cloud sync N+1 DB operations per artifact | Performance | **High** | Cross-cutting | L | Backend | Scheduled soon |
| 28 | Chat thread upload N+1 message fetch | Performance | **High** | Local | S | Backend | Scheduled soon |
| 29 | ConversationIndexer N+1 fetch per record | Performance | **High** | Local | S | Backend | Scheduled soon |
| 30 | Row-by-row FTS deletes | Performance | **High** | Local | S | Backend | Scheduled soon |
| 31 | Hardcoded timing dependencies in tests (flaky) | Testing | **High** | Cross-cutting | M | Full-stack | Scheduled soon |
| 24 | `UsageAggregatorParsers` (1,346 lines) untested | Testing | **High** | Local | M | Backend | Scheduled soon |
| 25 | ICloudSessionMirrorService completely untested | Testing | **High** | Local | L | Backend | Scheduled soon |
| 26 | Golden tests rely on exact score ordering | Testing | **Medium** | Local | S | Backend | Opportunistic |
| 27 | Vague boolean assertions (81× `XCTAssertTrue(isEmpty)`) | Testing | **Medium** | Systemic | S | Full-stack | Opportunistic |
| 28 | Database backup queue never closed | Reliability | **Medium** | Local | S | Platform | Opportunistic |
| 29 | Cloud sync lacks exponential backoff / circuit breaker | Reliability | **Medium** | Cross-cutting | M | Backend | Scheduled soon |
| 30 | Missing observability / metrics on critical paths | Reliability | **Medium** | Systemic | L | Infra | Scheduled soon |
| 31 | Force-unwrapped URLs with dynamic components | Security | **Medium** | Cross-cutting | S | Full-stack | Opportunistic |
| 32 | `@unchecked Sendable` used to silence compiler | Architecture | **Medium** | Cross-cutting | M | Platform | Scheduled soon |
| 33 | `print()` in production code (DataStore.refresh) | Reliability | **Medium** | Local | S | Full-stack | Opportunistic |
| 34 | CI test script contains flakiness workarounds | Reliability | **Medium** | Systemic | M | Infra | Scheduled soon |
| 35 | Magic numbers / string literals everywhere | Code Quality | **Medium** | Cross-cutting | S | Full-stack | Opportunistic |
| 36 | Inconsistent error handling styles | Code Quality | **Medium** | Cross-cutting | L | Full-stack | Scheduled soon |
| 37 | Views directly access DataStore sub-stores | Architecture | **Medium** | Cross-cutting | L | Frontend | Scheduled soon |
| 38 | Firebase/Firestore leaking into core logic | Architecture | **Medium** | Cross-cutting | L | Backend | Scheduled soon |
| 39 | 15+ singletons / manual service locator | Architecture | **Medium** | Cross-cutting | L | Full-stack | Scheduled soon |
| 40 | Business logic in Views, view logic in Services | Architecture | **Medium** | Cross-cutting | M | Full-stack | Scheduled soon |
| 41 | Inconsistent state management (@Observable vs ObservableObject) | Architecture | **Medium** | Cross-cutting | M | Frontend | Scheduled soon |
| 42 | Weak module boundaries (monolithic app target) | Architecture | **Medium** | Systemic | XL | Architecture | Longer-horizon |
| 43 | State ownership confusion (app/daemon/cloud) | Architecture | **Medium** | Cross-cutting | L | Architecture | Scheduled soon |
| 44 | Interface instability (volatile public APIs) | Architecture | **Medium** | Cross-cutting | M | Full-stack | Scheduled soon |
| 45 | App sandbox disabled (deliberate but documented risk) | Security | **Critical** | Systemic | XL | Architecture | **Accepted intentionally** |
| 46 | Release entitlements strip keychain/iCloud/Apple Sign-In | Security | **High** | Cross-cutting | M | Infra | Scheduled soon |
| 47 | Missing Apple Privacy Manifest | Security | **High** | Cross-cutting | M | Infra | Scheduled soon |
| 48 | SQLite database unencrypted at rest | Security | **High** | Cross-cutting | L | Platform | Scheduled soon |
| 49 | VS Code extension activates in untrusted workspaces | Security | **High** | Cross-cutting | M | Full-stack | Scheduled soon |
| 50 | BrowserToolService accepts arbitrary URL schemes | Security | **Medium** | Local | S | Backend | Scheduled soon |
| 51 | Provider executor does not validate baseURL scheme | Security | **Medium** | Local | S | Backend | Scheduled soon |
| 52 | Daemon support directory overrideable via env var | Security | **Medium** | Local | S | Platform | Scheduled soon |
| 53 | All structured logging uses `privacy: .public` | Security | **Medium** | Cross-cutting | M | Platform | Scheduled soon |
| 54 | Keychain access uses legacy macOS keychain | Security | **Medium** | Cross-cutting | S | Platform | Scheduled soon |
| 55 | Cursor connector Cloudflare tunnel exposes local router | Security | **Medium** | Local | M | Full-stack | Scheduled soon |
| 56 | Minimal third-party license attribution | Security | **Medium** | Cross-cutting | M | Infra | Scheduled soon |
| 57 | Daemon socket file permissions inherited from umask | Security | **Medium** | Local | S | Platform | Scheduled soon |
| 58 | CursorConnectorManager writes executable Python script to user dir | Security | **Medium** | Local | M | Full-stack | Scheduled soon |
| 59 | Credential scanning in conversations without user consent | Security | **Medium** | Cross-cutting | S | Full-stack | Scheduled soon |
| 60 | Placeholder client ID in shipping Info.plist | Security | **Low** | Local | S | Infra | Opportunistic |
| 61 | Test-only API keys in test source | Security | **Low** | Local | XS | Full-stack | Opportunistic |
| 46 | DataStore refresh loads 5000 rows, no delta | Performance | **Medium** | Cross-cutting | M | Backend | Scheduled soon |
| 47 | SearchService heavy scoring on MainActor | Performance | **Medium** | Local | M | Backend | Scheduled soon |
| 48 | Re-embed nested pagination per-document chunks | Performance | **Medium** | Local | M | Backend | Scheduled soon |
| 49 | UsageStore row-by-row upserts | Performance | **Medium** | Local | S | Backend | Scheduled soon |
| 50 | Unbounded in-memory vector dictionary (~600MB at 100K chunks) | Performance | **Medium** | Systemic | L | Backend | Scheduled soon |
| 51 | countOccurrences full table string scan | Performance | **Medium** | Local | M | Backend | Scheduled soon |
| 52 | Missing composite index on conversations dates | Performance | **Medium** | Local | S | Backend | Opportunistic |
| 53 | CLIBridge uncancelled detached tasks | Performance | **Medium** | Cross-cutting | M | Platform | Scheduled soon |
| 54 | DatabaseWorkspaceView 2115-line monolithic body | Performance | **Low** | Local | M | Frontend | Opportunistic |
| 55 | Lexical search SELECT * over-fetches text | Performance | **Low** | Local | S | Backend | Opportunistic |
| 46 | `OpenBurnBarDatabase` imports SwiftUI | Code Quality | **Low** | Local | XS | Backend | Opportunistic |
| 47 | Micro-files with trivial content | Code Quality | **Low** | Local | S | Full-stack | Opportunistic |
| 48 | VAL-* validation IDs in production source | Code Quality | **Low** | Cross-cutting | S | Full-stack | Opportunistic |
| 49 | Hardcoded daemon version out of sync with release | Reliability | **Low** | Local | S | Infra | Opportunistic |
| 50 | Firebase config injection can leave artifacts | Security | **Low** | Systemic | S | Infra | Opportunistic |

---

## 4. What Is Hurting Velocity Most

1. **Giant files create merge conflicts and review fatigue.** CloudSyncService, CLIBridge, UsageAggregator, SearchService, and ChatSessionController are where most feature work lands. A single PR touching any of these requires reviewers to reason about 1,000+ lines of mixed concerns.
2. **The DataStore facade forces every database change through a bottleneck.** Adding a new query requires updating the actor, the main class, the extension file, and sometimes the deprecated forwards. This is pure friction.
3. **Parked tests are rotting.** `OpenBurnBarDaemonManagerTests` (769 lines), `ProviderQuotaServiceTests` (1,041 lines), and `PerformanceTests` (608 lines) are excluded from CI. Every API drift makes revival harder.
4. **Inconsistent concurrency patterns mean every async change is risky.** Engineers cannot assume `@MainActor` means "UI only" because it is also used for I/O. `Task.detached` is used as an escape hatch, making cancellation and memory management unpredictable.
5. **Silent failures create "works on my machine" debugging loops.** When a parser, sync, or RPC call fails, there is no error surface. Developers must add logging ad hoc to diagnose issues that should have been visible from the start.
6. **N+1 queries are pervasive and will compound with growth.** Search hydration, conversation indexing, cloud sync, chat thread upload, and usage upserts all do row-by-row or per-entity database operations instead of batching. As user data scales, these will dominate latency.
7. **The semantic search pipeline reloads the entire embedding corpus into memory on every refresh.** For 100K chunks this is ~600MB. This is a scalability wall that will cause OOM crashes.

---

## 5. What Is Riskiest for Production

1. **`fatalError` on DataStore init** — Any disk pressure, permission issue, or SQLite corruption bricks the app. Users cannot export data or even see an error message.
2. **Daemon has no crash recovery or heartbeat** — If the daemon OOMs or panics, `launchd` restarts it blindly. Repeated crashes throttle restarts, leaving the app permanently degraded with no diagnostic.
3. **Socket RPC client has no timeout** — A stale socket or deadlocked daemon causes `refreshHealth()` to hang forever. The UI freezes and macOS marks the app as "Not Responding."
4. **Release pipeline ships without smoke tests** — The `release.yml` workflow builds, signs, notarizes, and uploads without ever launching the `.app`. A broken daemon binary or missing resource bundle ships directly to users.
5. **Cloud sync lacks backoff / circuit breaker** — Transient Firestore outages trigger immediate retry on the next periodic tick. This can exhaust API quotas and drain battery.
6. **No database migration rollback** — If a migration fails halfway, the user is left with a partially migrated schema and no recovery path. Downgrading the app is unsupported.
7. **SQLite database is unencrypted at rest** — The database at `~/Library/Application Support/OpenBurnBar/openburnbar.sqlite` contains conversation transcripts, token usage, and project names. Physical access = full data access.
8. **Release entitlements strip security capabilities** — The release build removes keychain access groups, iCloud, and Apple Sign-In entitlements. Firebase tokens may fall back to less secure storage.
9. **VS Code extension activates in untrusted workspaces** — The extension declares `untrustedWorkspaces.supported: true` and still connects to the daemon socket, exposing local state to untrusted workspace code.

---

## 6. What Could Force a Rewrite Later

1. **DataStore monolith** — If the search, sync, and usage stores continue to share a single `DatabaseQueue` with no isolation boundaries, a schema change in one domain will require reasoning about all others. At some point, splitting this will require a migration more complex than the current system can support.
2. **CloudSyncService monolith** — Firestore logic, conflict resolution, watermarking, Markdown chunking, and collaboration audit logging are all entangled. A change to one sync domain (e.g., chat threads) can corrupt another (e.g., shared artifacts). This will eventually require a full redesign of the sync layer.
3. **UsageAggregator as imperative orchestrator** — The 212-line `refreshAll()` method triggers parsing, persistence, indexing, projection, artifact discovery, summaries, backfills, and API fetching in one imperative block. As more providers and pipelines are added, this method will become unmaintainable and will need to be replaced with an event-driven job queue.
4. **MissionControl without tests** — The daemon's "brain" (DAG scheduling, state merging, notification evaluation) has no test coverage. As mission complexity grows, the team will lack confidence to refactor, leading to either a rewrite or feature stagnation.
5. **SwiftUI in service layers** — `import SwiftUI` in database and service files means these layers cannot be tested headlessly. As the test matrix grows, this will force either a massive decoupling effort or acceptance of low coverage.
6. **Semantic search memory wall** — The unbounded in-memory vector dictionary (`vectorsByChunkID`) reloads the entire corpus on every refresh. At ~600MB for 100K chunks, this is an OOM time bomb. Fixing it later requires redesigning the vector index to use mmap or on-demand loading.
7. **N+1 query culture** — Search hydration, cloud sync, conversation indexing, and usage upserts all use row-by-row patterns. As data grows, these linear scalers will dominate latency and make the app feel sluggish. Retrofitting batching across 10+ subsystems is harder than doing it incrementally now.

---

## 7. Debt Reduction Strategy

**Core philosophy:** Harden the foundation before refactoring the facade. The system has good bones (actor-based DataStore, structured logging, GRDB migrations, release automation) but brittle edges. The plan prioritizes:

1. **Safety first** — Eliminate `fatalError`, add timeouts, fix silent failures, and add smoke tests to the release pipeline.
2. **Test the untested** — Revive parked tests and write integration tests for the sync and daemon boundaries before refactoring them.
3. **Decouple incrementally** — Split giant files behind stable interfaces. Use the existing protocol boundaries (e.g., `LogParser`) as migration seams.
4. **Move I/O off main thread** — Remove `@MainActor` from services that do database, network, or filesystem work. Replace `Task.detached` with structured concurrency.
5. **Standardize** — Adopt a single error handling style (`throws` + typed errors), a single naming convention, and a single concurrency model.

**What we will NOT do:**
- Rewrite the sync layer from scratch before it has tests.
- Split DataStore into separate databases (keep one `DatabaseQueue`, but isolate stores logically).
- Adopt a new architecture pattern (TCA, MVVM-C, etc.) — the current SwiftUI + actor model is fine once the actor boundaries are correct.

---

## 8. Phased Roadmap

### Phase 0: Immediate Blockers and Dangerous Debt (Week 1–2)
**Goal:** Prevent incidents and user-facing failures.

| Workstream | Specific Work | Why Now |
|---|---|---|
| **P0-1: Kill the fatalError** | Replace `fatalError` in `AgentLensApp.swift` with a graceful degradation modal (reset DB, open support dir, or contact support). | Bricks the app for any DB issue. |
| **P0-2: Add release smoke test** | Insert `test-openburnbar-release-smoke.sh` into `release.yml` before upload. Gate publish on app launch + daemon health. | Prevents shipping broken notarized binaries. |
| **P0-3: Socket RPC timeout** | Add `poll`/`select` with 5s timeout to `OpenBurnBarDaemonSocketClient`. Surface "Daemon not responding" alert on timeout. | Stops UI hangs. |
| **P0-4: Revive DaemonManager tests** | Move `OpenBurnBarDaemonManagerTests.swift` from `Parked/` → `Active/`. Fix API drift. | Closes the largest daemon coverage gap. |
| **P0-5: Ban empty catch blocks** | Audit and replace 252 `catch {}` with `AppLogger.error` or propagation. Add SwiftLint rule. | Stops silent data loss. |

**Success criteria:**
- App never calls `fatalError` in production.
- Release workflow fails if smoke test fails.
- Daemon RPC calls timeout and surface degraded state.
- `OpenBurnBarDaemonManagerTests` passes in CI.
- Zero new empty `catch {}` blocks merged.

---

### Phase 1: Foundations (Week 3–6)
**Goal:** Establish safe refactoring boundaries and harden error handling.

| Workstream | Specific Work | Why Now |
|---|---|---|
| **P1-1: Typed error enum** | Introduce `OpenBurnBarError` with domains (sync, database, daemon, parse, network). Migrate all string-based errors. | Required before refactoring services. |
| **P1-2: Remove `@MainActor` from I/O services** | Remove `@MainActor` from `CloudSyncService`, `SearchService`, `UsageAggregator`, `ProjectionPipelineService`. Move UI updates to `@MainActor` closures at the boundary. | Unblocks safe background I/O. |
| **P1-3: Replace `Task.detached`** | Replace all 17+ `Task.detached` calls with `TaskGroup`, `async let`, or dedicated `Task` properties with cancellation. | Fixes memory leaks and priority inversion. |
| **P1-4: Database migration safety** | Wrap each migration in a transaction. On failure, restore from pre-migration backup and surface error. Add schema version metadata table. | Protects user data during schema evolution. |
| **P1-5: Add daemon heartbeat** | Emit periodic heartbeat file. In `DaemonManager`, detect crash loops (>3 failures in 60s) and surface diagnostics. | Enables proactive failure detection. |
| **P1-6: Cloud sync backoff + circuit breaker** | Implement exponential backoff with jitter. Add circuit breaker: after N failures, stop retrying until manual retry. | Prevents quota exhaustion. |

**Success criteria:**
- All services that do I/O are no longer `@MainActor`.
- `Task.detached` count is zero in `AgentLens/Services/`.
- Migrations are atomic and recoverable.
- Cloud sync has measurable backoff intervals.

---

### Phase 2: Cross-Cutting Cleanup (Week 7–10)
**Goal:** Pay down the debt that slows every feature PR.

| Workstream | Specific Work | Why Now |
|---|---|---|
| **P2-1: Extract parser base class** | Create `LogParserProtocol` with default implementations. Migrate 13 parsers to use shared JSONL iteration and `TokenUsage` builder. | Eliminates ~2,200 lines of duplication. |
| **P2-2: Delete DataStore pass-throughs** | Delete `DataStore+ConversationAccess.swift`, `+SearchAccess.swift`, etc. (1,355 lines). Inject sub-stores directly into consumers. | Removes god-object symptom. |
| **P2-3: Split SettingsManager** | Split into `AppearanceSettings`, `ControllerSettings`, `SyncSettings`, `SearchSettings`. Use batched persistence. | Reduces singleton mutation surface. |
| **P2-4: Remove SwiftUI from services** | Remove `import SwiftUI` from `DataStore.swift`, `OpenBurnBarDatabase.swift`, `SettingsManager.swift`, etc. Move `Color`/`ColorScheme` to `Theme/`. | Enables headless testing. |
| **P2-5: Standardize naming** | Adopt convention: `*Service` = business logic, `*Store` = DB access, `*Actor` = concurrency boundary, `*Client` = network I/O. Rename outliers. | Reduces onboarding friction. |
| **P2-6: Constants extraction** | Create `OpenBurnBarConstants.swift` with `SyncLimits`, `TruncationLimits`, `TokenEstimation`. Replace magic numbers. | Makes product tuning explicit. |

**Success criteria:**
- Parser duplication reduced by >50%.
- DataStore extensions deleted; no pure pass-throughs remain.
- Zero `import SwiftUI` in `Services/` or `DataStore/`.
- Naming convention documented and enforced in PR template.

---

### Phase 3: Architecture Strengthening (Week 11–16)
**Goal:** Refactor the largest monoliths with test coverage as guardrails.

| Workstream | Specific Work | Why Now |
|---|---|---|
| **P3-1: Split CloudSyncService** | Extract `UsageSyncService`, `ArtifactCollaborationService`, `SessionLogCloudService`, `ChatThreadCloudService`. Keep `CloudSyncService` as a thin coordinator. | The largest god object; blocks every sync feature. |
| **P3-2: Split CLIBridge** | Extract `CLIDetectionService`, `SSEStreamParser`, `ProcessSpawner`, `ToolCallDecoder`. Move I/O off main thread. | Unblocks CLI provider additions. |
| **P3-3: Event-driven UsageAggregator** | Convert `refreshAll()` to a pipeline: `ParserStage → PersistStage → IndexStage → ProjectionStage → SummaryStage`. Use a local job queue. | Prevents the 212-line method from growing further. |
| **P3-4: MissionControl tests** | Add contract tests for `MissionControlStore` (in-memory SQLite), `BurnBarParallelDAGScheduler`, and `MissionControlMissionStateMerger`. | Enables confident refactoring of the daemon brain. |
| **P3-5: Cloud sync integration tests** | Build fake `CloudSyncContext` with in-memory Firestore emulator. Test `sync()`, 3-way merge, optimistic concurrency, and error backoff. | Required before adding shared-artifact features. |
| **P3-6: Store-level unit tests** | Add dedicated tests for `SearchIndexStore`, `ConversationStore`, `ArtifactStore`, `ProjectionStore`, `UsageStore` using in-memory `DatabaseQueue`. | Catches SQL regressions early. |

**Success criteria:**
- CloudSyncService < 800 lines.
- CLIBridge < 800 lines.
- UsageAggregator `refreshAll()` < 100 lines (delegates to pipeline stages).
- MissionControl has >50% line coverage.
- All DataStore sub-stores have dedicated unit tests.

---

### Phase 4: Polish and Long-Tail Cleanup (Week 17–24)
**Goal:** Improve developer experience, observability, and test quality.

| Workstream | Specific Work | Why Now |
|---|---|---|
| **P4-1: Observability** | Add `metrics.jsonl` with counters for `datastore_init_failures`, `daemon_crash_count`, `sync_error_count_by_code`, `rpc_latency_ms`. Expose `/metrics` on gateway. | Enables data-driven incident response. |
| **P4-2: Fix flaky tests** | Replace `Task.sleep` timing in `ChatSessionControllerSearchStateTests` with deterministic test doubles. Remove CI retry loop in `test-openburnbar-app.sh`. | Restores CI trust. |
| **P4-3: Golden test tolerance** | Separate structural golden tests from score golden tests. Allow score tolerances in assertions. | Reduces noise from algorithm tweaks. |
| **P4-4: Vague assertions** | Replace 81× `XCTAssertTrue(isEmpty)` with `XCTAssertEqual(array, [])`. | Improves debuggability. |
| **P4-5: Reduce ViewInspector fragility** | Move view-model testing to direct state-machine tests. Reserve ViewInspector for critical user flows only. | Reduces Xcode upgrade breakage. |
| **P4-6: Log rotation** | Split daemon stdout/stderr. Add 10MB log rotation. | Prevents disk fill. |

**Success criteria:**
- Metric counters visible in local dev.
- Zero flaky tests in CI.
- Golden tests pass with intentional algorithm changes (within tolerance).
- ViewInspector test count reduced by 50%.

---

## 9. Quick Wins

These are high-leverage improvements that can be done in 1–2 days each and should happen early:

1. **Fix `fatalError` in `AgentLensApp.swift`** — M effort, prevents app bricking.
2. **Add smoke test to `release.yml`** — M effort, prevents shipping broken releases.
3. **Add socket RPC timeout** — M effort, prevents UI hangs.
4. **Batch search hydration conversation fetches** — S effort, fixes N+1 query in `SearchService`.
5. **Batch ConversationIndexer fetches** — S effort, fixes N+1 query in indexing.
6. **Batch FTS deletes in `SearchIndexStore`** — S effort, replaces row-by-row deletes.
7. **Batch UsageStore upserts** — S effort, replaces row-by-row inserts.
8. **Add composite index on conversations dates** — S effort, fixes date-range scan.
9. **Remove `import SwiftUI` from service files** — M effort, enables headless testing.
10. **Delete DataStore pass-through extensions** — M effort, removes 1,355 lines of boilerplate.
11. **Extract constants (`SyncLimits`, `TruncationLimits`)** — S effort, makes tuning explicit.
12. **Replace `print()` in `DataStore.refresh()` with `AppLogger`** — XS effort, uses existing infrastructure.
13. **Close database backup queue in `OpenBurnBarDatabase`** — XS effort, fixes resource leak.
14. **Fix hardcoded daemon version string** — S effort, removes protocol mismatch noise.
15. **Strip VAL-* validation IDs from source** — S effort, reduces noise.

---

## 10. Longer-Horizon Refactors

1. **Strangler-fig migration of CloudSyncService** — Extract domain sync services one at a time over 3–4 sprints. Keep the old surface as a façade until each extraction is tested.
2. **Event-driven pipeline for UsageAggregator** — Replace imperative `refreshAll()` with a durable local job queue. This is a significant redesign but prevents the method from becoming unmaintainable.
3. **Full MissionControl test harness** — Build an in-process daemon test harness that exercises end-to-end flows (create run → approve → record usage → sync to app). This is XL effort but essential for reliability.
4. **App-daemon integration test suite** — Test IPC boundary, protocol version negotiation, and socket reconnection. Requires a lightweight daemon subprocess harness.
5. **Database store isolation** — Evaluate whether `DatabaseQueue` per store domain would improve resilience without sacrificing consistency.

---

## 11. Metrics and Governance

### Progress Metrics

| Metric | Baseline | 30-Day Target | 90-Day Target |
|---|---|---|---|
| Lines in top 4 service files | 6,011 | 5,000 | 3,500 |
| Empty `catch {}` blocks | 252 | 150 | 0 |
| `Task.detached` occurrences | 17+ | 10 | 0 |
| `@MainActor` on I/O services | 4 | 2 | 0 |
| Parked test lines in CI | 5,982 | 3,000 | 0 |
| CloudSyncService test coverage | 0% sync logic | 30% | 60% |
| DaemonManager test coverage | 0% | 50% | 80% |
| MissionControl test coverage | 0% | 20% | 50% |
| `try?` in `AgentLens/Services/` | ~180 | 120 | 50 |
| SwiftUI imports in Services/ | 6+ | 3 | 0 |
| Release smoke test pass rate | N/A | 100% | 100% |
| CI flaky test rate | Unknown | <5% | <1% |

### Governance

1. **Tech Debt Review** — Dedicate 20% of each sprint to debt reduction. Track debt items in the sprint board with the `tech-debt` label.
2. **PR Gates** — Add SwiftLint rules for:
   - Empty `catch {}` blocks (error)
   - `try?` in non-test code (warning, require justification)
   - `Task.detached` (warning)
   - `import SwiftUI` in `Services/` or `DataStore/` (error)
3. **Test Coverage Policy** — Any new service >200 lines requires tests before merge. Any refactor of a service >500 lines requires tests of the behavior being changed.
4. **Architecture Decision Records (ADRs)** — Document naming conventions, actor boundaries, and error handling patterns in `docs/ARCHITECTURE/`.
5. **Monthly Debt Audit** — Re-run complexity metrics and test coverage reports. Track trends in a `TECH_DEBT_METRICS.md` file.

---

## 12. Final Recommendation

### Do First (This Week)
1. **Fix the `fatalError` in `AgentLensApp.swift`** — This is a single point of failure that can brick user installations.
2. **Add a smoke-test gate to `release.yml`** — Do not ship another notarized release without verifying the app launches.
3. **Revive `OpenBurnBarDaemonManagerTests` from Parked** — Move it to Active and fix compilation. This is the fastest way to close the largest test gap.
4. **Validate URLs in BrowserToolService and provider executor** — Reject `file://`, `javascript:`, and arbitrary schemes. Prevents local file access and token leakage.
5. **Restrict daemon socket file permissions** — `chmod(socketPath, 0o600)` after bind. Prevents other local users from connecting.
6. **Add `kSecUseDataProtectionKeychain` to custom keychain stores** — Align with Firebase Auth's keychain model. Prevents secret loss on OS upgrades.

### Do Soon (Next 4–6 Weeks)
1. Remove `@MainActor` from I/O services and replace `Task.detached` with structured concurrency.
2. Ban empty `catch {}` blocks and audit `try?` usage in service code.
3. Add socket RPC timeout and daemon heartbeat.
4. Split `CloudSyncService` into domain sync services.
5. Add CloudSyncService integration tests with a fake `CloudSyncContext`.
6. **Add Apple Privacy Manifest** — Create `PrivacyInfo.xcprivacy` with data usage declarations. Required for App Store and notarization compliance.
7. **Fix release entitlements or gate cloud features** — Either embed a Developer ID provisioning profile with keychain/iCloud entitlements, or explicitly disable Firebase/iCloud in release builds.
8. **Restrict VS Code extension in untrusted workspaces** — Change `untrustedWorkspaces.supported` to `limited` and suppress daemon connectivity until workspace is trusted.
9. **Audit logging privacy levels** — Switch from `privacy: .public` to `.private` or `.auto` for all interpolated values.

### Can Wait (After Foundation Is Solid)
1. Full MissionControl test harness.
2. Event-driven pipeline for `UsageAggregator`.
3. Database store isolation evaluation.
4. Golden test tolerance and ViewInspector reduction.
5. **Evaluate SQLite encryption at rest** — SQLCipher or similar. Significant effort; requires migration and key management design.
6. **Generate comprehensive third-party license attribution** — Required for OSS compliance but not blocking product work.

### Accept Intentionally
1. **App Sandbox disabled** — This is a deliberate product requirement (filesystem access to agent logs). The risk is mitigated by Developer ID signing, Gatekeeper, and notarization. Document this decision and revisit only if App Store distribution becomes a goal.
2. **Firebase as optional replication** — The local-first architecture is correct. Firestore is not on the critical path for core functionality.
3. **Swift 5.10 / Xcode 16 lock** — The project uses modern Swift features (`@Observable`, actors, strict concurrency). Staying current is fine; do not backport to older macOS versions.

---

*This strategy was produced by a coordinated swarm audit of the OpenBurnBar codebase. The findings are evidence-based and prioritized by production risk, velocity impact, and safe execution order.*
