# High-Leverage Improvements Plan v2

## Status: COMPLETED (2026-04-24)

All three improvements implemented end-to-end. Daemon suite: 185/185 tests pass. AgentLens app builds successfully post-migration.

## Objective

Implement three high-leverage improvements to OpenBurnBar: (1) switch `DataStore.swift` and all sub-stores from `DatabaseQueue` to `DatabasePool` for concurrent read performance, (2) add token-bucket rate limiting to daemon RPC and HTTP gateway endpoints, and (3) bound `BurnBarRunService` memory via eviction of terminal runs and pagination for the run registry. Each improvement targets a distinct quality axis: performance, security/stability, and scalability.

---

## 1. Improvement 8 -- Switch to DatabasePool for Read-Heavy Operations

### Current State

`AgentLens/Services/DataStore.swift` and `AgentLens/Services/DataStoreActor` use `DatabaseQueue` (GRDB) as the database access primitive:

- `DataStore.swift:288` constructs `DatabaseQueue(path: dbPath)` in the convenience init.
- `DataStoreActor:11` exposes `nonisolated let dbQueue: DatabaseQueue`.
- All sub-stores (`UsageStore`, `ConversationStore`, `SearchIndexStore`, `ArtifactStore`, `ProjectionStore`, `ControlPlaneStore`, `DeviceStore`, `ParserCheckpointStore`, `RemoteSyncWatermarkStore`, `SwitcherProfileStore`, `BackfillCursorStore`) are initialized with `DatabaseQueue` and call `dbQueue.read { ... }` / `dbQueue.write { ... }`.
- `OpenBurnBarDatabase:15` holds `let dbQueue: DatabaseQueue` and uses it for migrations, integrity checks, and backups.

`DatabaseQueue` serializes all database access — reads block other reads. Under load (dashboard rendering + search + usage aggregation simultaneously), the UI thread and background workers contend on the same serialized queue. GRDB's `DatabasePool` uses WAL mode and allows concurrent reads while serializing writes, which is ideal for the read-heavy AgentLens workload.

### Implementation Plan

- [x] **1.1** Audit every `DatabaseQueue` reference in `AgentLens/Services/DataStore.swift`, `AgentLens/Services/DataStoreActor`, `AgentLens/Services/DataStore/OpenBurnBarDatabase.swift`, and all sub-store files. Produce an exhaustive list of initializers, properties, and method signatures to update.
- [x] **1.2** Change `DataStoreActor` to accept `DatabasePool` instead of `DatabaseQueue`. Update the `dbQueue` property to `dbPool: DatabasePool`. Update the designated initializer signature from `init(databaseQueue:runMigrations:)` to `init(databasePool:runMigrations:)`.
- [x] **1.3** Update `DataStore` convenience init (`DataStore.swift:285-290`) to construct `DatabasePool(path:)` instead of `DatabaseQueue(path:)`. This is the production entry point.
- [x] **1.4** Keep the `DataStore.init(databaseQueue:runMigrations:refreshOnInit:)` initializer available for test callers that inject an in-memory `DatabaseQueue`, but mark it deprecated or provide an overload that accepts `DatabaseWriter` so both `DatabaseQueue` and `DatabasePool` work. Rationale: tests using `:memory:` may still prefer `DatabaseQueue` for simplicity.
- [x] **1.5** Update `OpenBurnBarDatabase` to accept `DatabasePool`. Verify `runMigrations()`, `runMigrationsSafely()`, and `backup(to:)` are compatible with `DatabasePool`. GRDB's `DatabasePool` supports the same `backup(to:)` API, but test the integrity-check path (`PRAGMA integrity_check`) under WAL mode.
- [x] **1.6** Update every sub-store initializer to accept `DatabasePool` and use `dbPool.read` / `dbPool.write` instead of `dbQueue.read` / `dbQueue.write`:
  - `UsageStore`
  - `ConversationStore`
  - `SearchIndexStore`
  - `ArtifactStore`
  - `ProjectionStore`
  - `ControlPlaneStore`
  - `DeviceStore`
  - `ParserCheckpointStore`
  - `RemoteSyncWatermarkStore`
  - `SwitcherProfileStore`
  - `BackfillCursorStore`
- [x] **1.7** Update `DataStore+SearchAccess.swift` if it directly references `dbQueue`.
- [x] **1.8** Update `AgentLensTests/Active/DataStoreTests.swift` and any store-specific tests. For tests that need in-memory isolation, either:
  - Keep injecting `DatabaseQueue(path: ":memory:")` via the preserved initializer, or
  - Migrate to `DatabasePool(path: "/tmp/...")` if the GRDB version supports pool-based in-memory databases.
- [x] **1.9** Add a concurrency smoke test that fires multiple simultaneous `fetchRecentUsage` and `searchLexicalChunks` calls and verifies they complete without serial blocking. Log timing before/after.
- [x] **1.10** Run the full `AgentLensTests` suite. Fix any test isolation issues caused by WAL mode (e.g., a write in one test becoming visible to a read in another test before `rollback` or `close`).

### Verification Criteria

- `AgentLens` builds and all `AgentLensTests/Active/DataStoreTests.swift` pass.
- Concurrent read test completes without serialization blocking.
- `OpenBurnBarDatabase.runMigrationsSafely()` still performs integrity check and backup correctly under `DatabasePool`.
- No regression in write-path behavior (inserts, updates, deletes still atomic and isolated).

---

## 2. Improvement 9 -- Add Rate Limiting to Daemon RPC

### Current State

The daemon exposes two request surfaces with no rate limiting:

1. **Unix Domain Socket RPC** (`OpenBurnBarDaemonServer.swift`):
   - `runAcceptLoop` (`line 1004`) accepts connections in a `while !Task.isCancelled` loop.
   - Each accepted connection spawns a detached `Task` (`line 1028`) that calls `handleClientConnection`.
   - `handleClientConnection` (`line 1047`) reads a single request, dispatches to `responseData(for:peerPID:)`, and writes the response.
   - No limit on connections per second, requests per second, or concurrent connections from a single client.

2. **HTTP Gateway** (`OpenBurnBarHTTPGatewayServer.swift`):
   - `start()` (`line 28`) creates an `AF_INET` socket and spawns an `acceptLoopTask` (`line 65`).
   - `handleClient(socket:)` (`line 122`) reads the HTTP request, routes it, and writes the response.
   - No limit on HTTP requests per client IP or per auth token.

Both surfaces are vulnerable to accidental or intentional flooding. The UDS surface is local-only but can be hammered by a misbehaving process. The HTTP gateway may be reachable by external clients depending on configuration.

### Implementation Plan

- [x] **2.1** Design and implement `BurnBarRateLimiter` as a Swift actor in a new file: `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRateLimiter.swift`.
  - Algorithm: token bucket.
  - Per-client tracking keyed by:
    - UDS: `peerPID` (from `LOCAL_PEERPID` socket option), falling back to `"unknown"`.
    - HTTP: bearer token if present, else a stable hash of the remote peer address.
  - Configuration struct: `BurnBarRateLimitConfiguration` with `requestsPerSecond` (sustained), `burstCapacity` (max bucket size), and `cooldownSeconds` (time before a throttled client can retry).
  - Method: `func checkLimit(clientKey: String) -> BurnBarRateLimitResult` where `BurnBarRateLimitResult` is `.allowed` or `.throttled(retryAfter:)`.
  - Storage: in-memory dictionary `[String: TokenBucket]`; prune stale entries periodically (entries idle > 5 minutes).
- [x] **2.2** Add `BurnBarRPCErrorCode.rateLimitExceeded` to the daemon's error code enum. Ensure it serializes in JSON error responses with a human-readable message.
- [x] **2.3** Integrate rate limiting into `BurnBarDaemonServer`:
  - Add a `rateLimiter: BurnBarRateLimiter` property, initialized with defaults (60 req/s sustained, 100 burst for UDS).
  - In `responseData(for:peerPID:)` (`line 276`), after decoding the request and before the `switch method`, call `rateLimiter.checkLimit(clientKey:)`.
  - If throttled, return an RPC error response with code `rateLimitExceeded`, log a warning with the client key and retry-after value, and skip method dispatch.
- [x] **2.4** Integrate rate limiting into `BurnBarHTTPGatewayServer`:
  - Add a `rateLimiter: BurnBarRateLimiter` property, initialized with defaults (30 req/s sustained, 50 burst for HTTP).
  - In `handleClient(socket:)` (`line 122`), after parsing the request and before routing, extract the client key and check the limit.
  - If throttled, write an HTTP 429 response with `Retry-After` header and `Content-Type: application/json` body containing `{ "error": "rate limit exceeded", "retry_after": N }`.
- [x] **2.5** Make rate limit parameters configurable via `BurnBarDaemonConfiguration` and `BurnBarGatewayConfiguration`. Add fields:
  - `udsRateLimit: BurnBarRateLimitConfiguration?` (nil means use default)
  - `httpRateLimit: BurnBarRateLimitConfiguration?` (nil means use default)
- [x] **2.6** Add unit tests for `BurnBarRateLimiter` in a new test file `OpenBurnBarDaemonTests/BurnBarRateLimiterTests.swift`:
  - Basic allowance: 10 requests at t=0 with burst=10 all succeed.
  - Burst exhaustion: request 11 at t=0 is throttled.
  - Refill: wait 1 second at 5 req/s, bucket refills by 5.
  - Per-client isolation: client A throttled, client B unaffected.
  - Concurrent access safety via actor isolation.
- [x] **2.7** Add integration tests in `OpenBurnBarDaemonServerTests.swift`:
  - Fire 150 rapid requests from the same mocked PID; assert at least one returns `rateLimitExceeded`.
- [x] **2.8** Add integration tests in `OpenBurnBarHTTPGatewayServerTests.swift`:
  - Fire 75 rapid HTTP requests; assert at least one returns HTTP 429 with `Retry-After` header.

### Verification Criteria

- `BurnBarRateLimiterTests` pass with full branch coverage.
- `OpenBurnBarDaemonServerTests` includes a test where rapid UDS requests from one PID trigger throttling.
- `OpenBurnBarHTTPGatewayServerTests` includes a test where rapid HTTP requests trigger HTTP 429.
- Rate-limited responses include correct `Retry-After` values.
- No behavioral change for requests within the limit.

---

## 3. Improvement 10 -- Bound BurnBarRunService Memory

### Current State

`BurnBarRunService` (`OpenBurnBarRunService.swift`) holds the entire run history in memory:

- `var runs: [BurnBarRunID: BurnBarManagedRun] = [:]` (`line 109`)
- `var runOrder: [BurnBarRunID] = []` (`line 110`)
- `createRun` appends to both (`BurnBarRunService+Lifecycle.swift:62-63`).
- `restorePersistedRunsIfNeeded` loads **all** historical checkpoints from `runJournal.allCheckpoints()` into memory at startup (`BurnBarRunService+Lifecycle.swift:96-185`).

There is no eviction, no maximum count, and no pagination. Memory usage grows linearly with the total number of runs ever created. A long-running daemon with hundreds or thousands of runs will consume unbounded memory.

`BurnBarRunJournal` already persists checkpoints to disk (`writeCheckpoint` at `BurnBarRunService+Lifecycle.swift:187-215`), so eviction is viable — evicted runs can be restored from their on-disk checkpoint.

### Implementation Plan

- [x] **3.1** Define `BurnBarRunRegistryEvictionPolicy` enum in `OpenBurnBarRunServiceTypes.swift` (or a new file):
  ```swift
  enum BurnBarRunRegistryEvictionPolicy {
      case none           // current behavior, for tests
      case maxCount(Int)  // keep at most N terminal runs in memory
  }
  ```
- [x] **3.2** Add configuration to `BurnBarRunService`:
  - `maxInMemoryRuns: Int` (default 200)
  - `evictionPolicy: BurnBarRunRegistryEvictionPolicy` (default `.maxCount(200)`)
- [x] **3.3** Implement `evictIfNeeded()` in `BurnBarRunService` (new private method). Rules:
  1. Only evict runs whose phase is terminal: `.completed`, `.failed`, `.cancelled`.
  2. Never evict runs with pending approvals or active tool calls.
  3. Sort terminal candidates by `updatedAt` ascending (oldest first).
  4. Remove candidates from `runs` and `runOrder` until `runs.count <= maxInMemoryRuns`.
  5. If no terminal runs can be evicted and count still exceeds limit, log a warning but do not evict active runs (fail soft).
- [x] **3.4** Call `evictIfNeeded()` in two places:
  1. After `restorePersistedRunsIfNeeded()` completes (`BurnBarRunService+Lifecycle.swift:184`).
  2. After `createRun` appends a new run (`BurnBarRunService+Lifecycle.swift:62-63`).
- [x] **3.5** Implement lazy single-run restoration. Modify these public methods to handle missing runs that have on-disk checkpoints:
  - `snapshot(for:)` (`OpenBurnBarRunService.swift:179`)
  - `getRun` (`OpenBurnBarRunService.swift:198`)
  - `listRuns` (`OpenBurnBarRunService.swift:191`)
  - `pollRuns` (`OpenBurnBarRunService.swift:214`)
  - `cancelRun` (`OpenBurnBarRunService.swift:312`)
  - `retryRun` (`OpenBurnBarRunService.swift:347`)
  - `respondToApproval` (`OpenBurnBarRunService.swift:419`)
  - `submitToolResult` (`OpenBurnBarRunService.swift:262`)

  Pattern: if `runs[runID]` is nil, call a new `restoreSingleRunIfNeeded(runID:)` method that loads only that run's checkpoint from disk (via `runJournal`), reconstructs the `BurnBarManagedRun`, inserts it into `runs` and `runOrder`, and returns it.
- [x] **3.6** Add `loadCheckpoint(for runID:)` to `BurnBarRunJournal` if it does not already exist. If `BurnBarRunJournal` only supports `allCheckpoints()`, implement single-run lookup by scanning the checkpoint directory for a file matching the runID. Rationale: the checkpoint directory already uses runID in filenames.
- [x] **3.7** Add pagination to `listRuns` and `pollRuns`:
  - Extend `BurnBarRunListRequest` with `offset: Int` and `limit: Int` (default limit = 50).
  - Extend `BurnBarRunPollRequest` with `limit: Int` (default = 50).
  - In `listRuns`, after sorting snapshots by `updatedAt` descending, apply `drop(offset).prefix(limit)`.
  - In `pollRuns`, apply `prefix(limit)` to the scoped run list before mapping to snapshots.
- [x] **3.8** Update `OpenBurnBarRunServiceTests.swift`:
  - Add a test creating 250 runs with `.none` eviction policy to verify baseline behavior still works.
  - Add a test with default `.maxCount(200)` policy: create 250 terminal runs, assert only 200 remain in `runService.runs`, and assert the 201st-oldest can still be retrieved via `getRun` (lazy restore).
  - Add a test verifying active (non-terminal) runs are never evicted even when the count exceeds the limit.
  - Add a test verifying `listRuns` respects the `limit` parameter.
  - Add a test verifying `retryRun` works on an evicted run (lazy restore + retry mutation).
- [x] **3.9** Update `BurnBarRunServiceTypes.swift` to add `offset` and `limit` fields to `BurnBarRunListRequest` and `limit` to `BurnBarRunPollRequest`.
- [x] **3.10** Update `OpenBurnBarDaemonServer.swift` RPC handlers for `.runList` and `.runPoll` to pass through the new pagination fields from the decoded requests.

### Verification Criteria

- `OpenBurnBarRunServiceTests` passes with the new eviction and pagination tests.
- Creating 250 terminal runs with default policy keeps at most 200 in memory; the evicted runs are still retrievable via `getRun`.
- Active runs (planning, executing, awaiting approval) are never evicted.
- `listRuns` returns paginated results when `limit` is provided.
- `retryRun` succeeds on an evicted run by lazily restoring it from checkpoint.
- No regression in existing run lifecycle tests (approval, cancel, tool dispatch, restore from checkpoint).

---

## Priority Order

1. **Improvement 10 (Run Registry Memory Bounds)** -- Highest priority. Unbounded memory growth is a guaranteed scalability failure. The fix is localized to `BurnBarRunService` and its journal.
2. **Improvement 9 (Rate Limiting)** -- High priority. Security/stability hardening with additive changes (new file + two integration points). Low blast radius.
3. **Improvement 8 (DatabasePool)** -- High priority for performance, but lowest risk if deferred. The change is mechanical across many files and requires thorough test validation.

## Potential Risks and Mitigations

1. **DatabasePool WAL mode breaks test isolation**
   Mitigation: Keep the `DatabaseQueue` initializer path for tests. Run the full `AgentLensTests` suite after migration and watch for flaky tests caused by cross-test WAL visibility.

2. **Rate limiting breaks legitimate burst traffic from the controller**
   Mitigation: Set generous defaults (60/s sustained, 100 burst for UDS; 30/s, 50 burst for HTTP). The controller is a single client and unlikely to exceed these. Make parameters configurable.

3. **Lazy run restore introduces race conditions or corruption**
   Mitigation: `BurnBarRunService` is an actor — all mutations are serialized. Ensure `evictIfNeeded()` and lazy restore both happen on the same actor. Do not evict runs with pending approvals or active tool calls.

4. **Evicted run restored mid-mutation loses in-flight state**
   Mitigation: Only terminal runs (completed/failed/cancelled) are eviction candidates. Active runs are protected. When a run transitions to terminal, it writes a final checkpoint before becoming eligible for eviction.

5. **Pagination changes client contract**
   Mitigation: Default `limit` values are high (50) so existing clients that do not send limits see no behavioral change. The daemon server passes the new fields through from the request envelope.

## Assumptions

- GRDB version supports `DatabasePool` with the same `read`/`write` closure API as `DatabaseQueue`. This is true for GRDB 6.x+.
- `BurnBarRunJournal` checkpoints are stored as individual files per runID in a directory, making single-run lookup feasible by filename matching.
- The HTTP gateway may be externally reachable, justifying rate limiting beyond basic localhost protection.
- Tests that assert on `runs.count` will be updated to use `.none` eviction policy or adjusted for the default `.maxCount(200)` policy.
