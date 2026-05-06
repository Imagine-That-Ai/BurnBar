# OpenBurnBar — Performance & Scalability Review

**Branch:** `release/openburnbar-0.1.2-beta.12`  
**Date:** 2026-04-27  
**Scope:** AgentLens, OpenBurnBarCore, OpenBurnBarDaemon

---

## 2026-05-06 Implementation Note

This review's view-model caching concern has been addressed for the active
dashboard usage path. `DashboardUsageViewModel` now caches daily rollups and
date-window summaries, and dashboard computed properties reuse the cached
window summary instead of recomputing filtered usage, totals, provider
summaries, model summaries, and cache efficiency on every SwiftUI body pass.

The responsiveness pass also removed several repeated refresh costs: usage
refresh no longer reloads all usage twice after persistence, quota refresh
fan-out is capped at four concurrent provider/account fetches, quota surfaces
use `refreshIfNeeded` on appearance, routing event persistence is batched once
per routing refresh, and `DatabaseWorkspaceView` rebuilds snapshots on a
debounced change task instead of polling every eight seconds. Startup now
defers the initial full refresh briefly and uses a longer periodic minimum
interval so first paint has less competition from background parsing.

Mobile received matching low-risk wins: quota and provider stores maintain
cached derived collections, Hermes runtime refreshes coalesce behind a single
in-flight task, pull-to-refresh awaits its real work directly, and idle
navigation/sign-in animations run at lower frame cadences while still honoring
Reduce Motion.

Database migration `v37_token_usage_performance_indexes` adds composite indexes
for sync backlog scans and provider/model/provider-id time-window queries. The
safe migration path now skips file backups when a file database is already at
the latest migration, while still backing up older file databases before
pending migrations.

Verification run on 2026-05-06:
- `xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -skip-testing:OpenBurnBarDaemonTests -only-testing:OpenBurnBarTests/DashboardUsageViewModelTests -only-testing:OpenBurnBarTests/OpenBurnBarDatabaseMigrationTests`
- `xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`

---

## 1. Performance Profile Overview

OpenBurnBar is a native macOS menu-bar app that parses token-usage logs from 12+ AI agents, indexes conversations into an embedded GRDB/SQLite database, runs an HNSW vector index for semantic search, and coordinates with a local Unix-domain-socket daemon. The heavy workloads (parsing, DB persistence, projection, embedding) are intentionally pushed off `@MainActor`, which is good. However, the system exhibits **significant serialization bottlenecks**, **unbounded memory pressure during vector indexing**, **N+1 query patterns in several hot paths**, and **lack of query-result or view-model caching** that will degrade as conversation volume grows beyond a few thousand sessions.

**Bottom line:** The system works well for the current beta scale (~hundreds of sessions), but several architectural patterns will require rework before it can scale to tens of thousands of conversations without noticeable UI stutter, refresh latency, or memory pressure.

---

## 2. Database Query Efficiency Assessment

### 2.1 GRDB is used correctly at the low level, but N+1 patterns exist at the service layer

**Evidence:**
- `SearchService.retrieveInGate()` (`AgentLens/Services/SearchService.swift`, ~line 335–530) performs **three sequential round-trips per retrieval query**:
  1. `searchLexicalChunks()` → returns chunk IDs.
  2. `fetchSearchChunks(ids: missingChunkIDs)` → hydration pass 1.
  3. `fetchSearchDocuments(ids: missingDocumentIDs)` → hydration pass 2.
  4. `fetchConversations(ids: conversationSourceIDs)` → batch conversation preload (good), but only after the first two hydration passes.

While the conversation preload was explicitly added to eliminate N+1 scoring (see comment at line 357), the **document hydration is still N+1 in spirit**: every semantic candidate whose chunk was not in the initial lexical map triggers a second DB round-trip.

**Verdict:** Acceptable for `rerankLimit ≤ 200`, but as `semanticCandidateLimit` grows (e.g., 1,000+), the second and third round-trips become measurable latency. A single `JOIN` between `search_chunks`, `search_documents`, and `conversations` in the lexical query would collapse this to one trip.

### 2.2 `COUNT(*)` with complex `COALESCE` predicates on every occurrence query

**Evidence:**
- `DataStore+SearchAccess.countOccurrencesInConversationFullText()` (line 50–95) builds a `UNION ALL` query with `LENGTH(...REPLACE(LOWER(...)))` arithmetic **per pattern**. For 10 aggregate patterns, this becomes 10 `UNION ALL` branches over the full `conversations` table, each scanning `fullText` (a potentially multi-MB column).
- The same file contains `scanConversationFullTextForCredentialExposure()` (line 275+), which **paginates 100 rows at a time** and runs up to 4 `NSRegularExpression` matches **in Swift** against each `fullText` string. For 10,000 conversations this is 100 round-trips plus full-text materialization into `NSString` on every page.

**Verdict:** These are full-table scans with expensive string operations. SQLite cannot use an index on `LOWER(fullText)` (no functional index is created). At scale this will dominate refresh latency. A dedicated `conversation_text_fts` virtual table, or at least a `LOWER(fullText)` covering index, would help.

### 2.3 `conversations_fts` and `search_chunks_fts` are separate virtual tables

**Evidence:**
- `ConversationStore.searchConversationsFTS()` (line 530+) queries `conversations_fts`.
- `SearchIndexStore.searchLexicalChunks()` (line 440+) queries `search_chunks_fts`.

Both use `bm25(...)` and `snippet(...)`, which are fine, but the **dual FTS tables mean maintenance overhead** (two tokenizers, two docid spaces) and the possibility of drift. More importantly, `search_chunks_fts` is joined back to `search_documents` and then `conversations` at retrieval time, adding latency.

**Verdict:** Not a bottleneck today, but a maintenance liability. No evidence of `FTS5` `contentless` or `content=` optimization.

### 2.4 `INSERT OR REPLACE` (upsert) on `conversations` is heavy

**Evidence:**
- `ConversationStore.upsertConversation()` (line 25–110) runs a read-modify-write inside `dbQueue.write`. It fetches the existing row, runs `shouldPreserveConversationSyncedAt` (11 field comparisons), then writes back 26 columns. For 1,000 conversations this is 1,000 separate write transactions unless batched externally.

**Verdict:** RefreshBackgroundWork batches usages (`usageStore.insert(allUsages)`), but **conversations are indexed one-by-one** via `ConversationIndexer.shared.index()` inside `Task { @MainActor ... }` (see `RefreshOrchestrator.indexConversationsOffMain`, line 35). This is a major scalability ceiling.

---

## 3. Concurrency and Threading Analysis

### 3.1 `SearchRetrievalGate` serializes all hybrid retrieval

**Evidence:**
- `SearchService` declares `private let retrievalGate = SearchRetrievalGate()` (line 54). Every `search()` and `runBurnBarQuery()` call is funneled through this actor, meaning **all retrieval queries run sequentially**, even when they hit different databases (FTS vs. vector index vs. cross-encoder API).

**Verdict:** This is overly conservative. Lexical search is read-only on GRDB; it could run concurrently with the network-bound cross-encoder reranker. The gate exists to protect `VectorSemanticCandidateProvider`'s mutable snapshot state, but that could be isolated instead. This gate will become a bottleneck if multiple UI surfaces (chat, dashboard, popover) issue queries simultaneously.

### 3.2 `@MainActor` pollution in data-layer types

**Evidence:**
- `UsageAggregator` is `@MainActor @Observable` (line 14). It launches `Task.detached(priority: .utility)` for refresh, which is correct, but then **applies results back on MainActor**.
- `ProjectionPipelineService` is `@MainActor` (line 20), yet its only observable state is `isSweeping`. The actual DB work (`runSweep`) runs on that same actor because the type is `@MainActor`. It does not hop off.
- `ChatSessionController` is `@MainActor @Observable` (line 15) and holds a `DataStore` reference. Because `DataStore` (typealias to `DataStoreCoordinator`) exposes `nonisolated` methods, some DB calls escape MainActor, but others (e.g., `DataStoreActor.fetchAllUsage`) are `async` and must be awaited—potentially stalling the main thread if the GRDB queue is busy.

**Verdict:** `@MainActor` on `ProjectionPipelineService` is a mistake; it forces projection work onto the main thread. `ChatSessionController` is large enough that its `@MainActor` status risks main-thread stalls during heavy retrieval.

### 3.3 Daemon accept loop: one `Task.detached` per connection, but no back-pressure

**Evidence:**
- `BurnBarDaemonServer.runAcceptLoop()` (`OpenBurnBarDaemonServer.swift`, line 480+) calls `accept()` in a loop and spawns `Task.detached(priority: .utility)` for every client connection. There is **no limit on the number of concurrent connections**.
- `maxRequestBytes = 64 * 1024` (line 14). The request reader (`readRequest`) allocates a 1,024-byte chunk buffer and appends in a `while true` loop until `0x0A`.

**Verdict:** A malicious or buggy client could open thousands of connections and exhaust file descriptors or memory. A connection pool / semaphore is needed.

### 3.4 `DataStoreActor` owns the `dbQueue`, but sub-stores are `nonisolated`

**Evidence:**
- `DataStoreActor` is an `actor`, but all sub-stores (`usageStore`, `conversationStore`, etc.) are exposed as `nonisolated let` (line 16–28). Their methods are `nonisolated` and synchronously acquire `dbQueue.read/write` blocks. This means **GRDB's own writer serialization protects against corruption, but the actor boundary does not serialize callers**.

**Verdict:** This is actually fine for GRDB (it handles its own serialization), but it means `DataStoreActor` is not truly protecting the stores from concurrent high-level operations. Multiple tasks can interleave reads and writes, leading to logical races (e.g., gap-repair enqueues a job while a sweep is deleting the same document).

---

## 4. Memory Management Assessment

### 4.1 HNSW vector index: unbounded `Data` on read path

**Evidence:**
- `BurnBarHNSWReadableIndex.load(from:)` (`BurnBarHNSWVectorIndex.swift`, line 280) loads the **entire index file into memory**: `loadedData = try Data(contentsOf: url)`.
- `view(from:)` uses `.mappedIfSafe`, which is better, but `search()` then parses the entire graph on every call: `data.withUnsafeBytes { ... }` + allocates `nodeMetas` array (line 315) sized to `header.count`.

**Verdict:** For 100k embeddings × 768 dims (~300 MB), this means **300 MB+ heap per search** if `load()` is used, or 300 MB mapped address space if `view()` is used. There is **no paging, no LRU, no shard boundary**. The vector index cannot scale past low hundreds of thousands of chunks on a consumer Mac without swapping.

### 4.2 Parsers materialize entire JSONL files into memory

**Evidence:**
- `ClaudeCodeParser.parseClaudeSession()` (line 195+) opens a `FileHandle`, then iterates `handle.readAllUTF8Lines()`. That helper (not shown in detail) likely reads line-by-line, which is fine, but **the accumulator (`ClaudeSessionAccumulator`) grows unbounded** for long sessions.
- `FactoryDroidParser` does the same (line 120+), and additionally loads `settings.json` and `metadata.json` into `Data` in full.

**Verdict:** For a 100k-line Claude session (~50 MB JSONL), the parser holds the entire file's parsed objects in memory. A streaming JSON parser (e.g., `JSONDecoder` with incremental `Data` slices, or a SAX-style parser) would reduce peak memory. Parser disk cache (`ParserDiskCache`) mitigates re-parsing, but the first parse is unbounded.

### 4.3 `fullText` column in `conversations` is unbounded

**Evidence:**
- `ConversationRecord.fullText` stores the entire conversation transcript as a single `String`. In `ConversationStore`, this is read into memory for every row in `fetchConversations(limit:)`.
- The credential-scanning batch query (`fetchTranscriptScanBatch`) mitigates this by selecting only `id, fullText`, but it still materializes the full text for every conversation in the batch.

**Verdict:** At 10,000 conversations × 100 KB fullText = 1 GB transient heap during a full refresh. The database should store `fullText` in a separate table, or use SQLite's `substr()` / `FTS` snippet extraction to avoid loading megabytes per row.

### 4.4 `SearchService` builds large in-memory maps per query

**Evidence:**
- `retrieveInGate()` constructs `candidates: [String: CandidateAccumulator]`, `lexicalChunkMap`, `lexicalDocumentMap`, `lexicalRankByChunkID`, `semanticRankByChunkID`, `conversationCache`, `chunkMap`, `documentMap`, and `scoredResults` (line 335–530). For `rerankLimit = 200`, this is ~1,000 dictionary entries—fine. But if limits are raised (e.g., 2,000), this becomes tens of thousands of temporary objects per query.

**Verdict:** No object pooling, no reuse. At high query volume (e.g., rapid chat typing), this creates GC pressure in Swift's ARC.

---

## 5. Caching Strategy Evaluation

### 5.1 Parser disk cache: effective but coarse-grained

**Evidence:**
- `ParserDiskCacheStore` (`ParserDiskCache.swift`, line 50+) persists a single JSON file per parser (Claude, Factory, etc.) containing every cached file entry. It uses `JSONEncoder` with `.prettyPrinted` and `.sortedKeys`, which is **slow and large**.
- Cache invalidation is file-signature based (`FileSignature` = mtime + size). No content-hash. If a file is touched but unchanged, it re-parses.

**Verdict:** Works for the current scale, but the monolithic JSON cache does not scale to thousands of sessions (encode/decode latency grows with entry count). A SQLite-backed cache, or at least a binary plist, would be faster.

### 5.2 No query-result caching

**Evidence:**
- `SearchService` has **no cache layer** for repeated queries. If the user types the same query twice, it re-runs FTS, re-embeds the query (network call to OpenAI), re-runs HNSW search, and re-reranks.
- `ChatSessionController.searchController` triggers a search on every keystroke (or debounce) with no `NSCache` for `query → [SearchResult]`.

**Verdict:** Missing an obvious win. An `NSCache` with a 30-second TTL for `(queryHash, filterHash) → results` would eliminate redundant work and save API costs for the embedder/reranker.

### 5.3 No view-model caching

**Evidence:**
- `DashboardUsageViewModel`, `ProviderDashboardView`, and `SessionDetailView` recompute aggregations from the raw `DataStore.usages` array on every `body` evaluation. SwiftUI `@Observable` invalidates the whole view tree when `usages` changes.

**Verdict:** For 5,000 usages this is fine. For 50,000, recomputing `groupByDay` inside a `View.body` will cause frame drops. Pre-computed rollup tables or cached `ViewModel` state are needed.

### 5.4 `SettingsManager` and `AccountManager` use `@MainActor` singletons with no cache

**Evidence:**
- `SettingsManager.shared` and `AccountManager.shared` are accessed from many `@MainActor` and background contexts. `SettingsManager` reads `UserDefaults` directly on every property access (no in-memory snapshot).

**Verdict:** Low impact today, but as settings grow, the repeated `UserDefaults` string lookups add up. A lightweight in-memory snapshot refreshed on `UserDefaults.didChangeNotification` would be cleaner.

---

## 6. Scalability Ceilings and Bottlenecks

| Component | Current Ceiling | Bottleneck | Severity |
|-----------|----------------|------------|----------|
| **HNSW Vector Search** | ~200k chunks | Entire index loaded into RAM per search; no sharding | **High** |
| **Conversation Refresh** | ~5k sessions | `ConversationIndexer` processes one conversation at a time on MainActor | **High** |
| **FTS Lexical Search** | ~50k documents | No `FTS5` `contentless` table; `fullText` loaded into memory for fallback search | **Medium** |
| **Cross-Encoder Rerank** | ~50 candidates/API call | Network latency dominates; no caching of rerank results | **Medium** |
| **Projection Pipeline** | ~1k jobs/sweep | `ProjectionPipelineService` is `@MainActor`; single-threaded sweep | **High** |
| **Credential Scan** | ~10k conversations | 100-row pagination + `NSString` regex in Swift; no SQL-side filtering | **Medium** |
| **Daemon RPC** | Unlimited connections | No connection back-pressure; 64 KB request limit only | **Medium** |
| **Cloud Sync** | ~400 conversations/batch | Hard `LIMIT 400` in `fetchUnsyncedConversations`; no cursor-based sync | **Low** |

### 6.1 The biggest scalability wall: `@MainActor ProjectionPipelineService`

`ProjectionPipelineService.runSweep()` (`ProjectionPipelineService.swift`, line 120+) is `@MainActor`. It loops `for _ in 0..<maxJobs`, leasing and processing jobs. Each job may:
- Call `chunker.makeChunks()` (CPU-bound text splitting).
- Call `chunkEmbedder.embeddings()` (network-bound OpenAI API call).
- Write to `search_documents`, `search_chunks`, `chunk_embeddings` (DB-bound).

Because the type is `@MainActor`, **all of this runs on the main thread**, blocking the UI. The code does use `await Task.yield()` every few jobs, but that only helps cooperative multitasking—it does not move work off the main thread.

**Fix:** Remove `@MainActor` from `ProjectionPipelineService`. Make `isSweeping` an `actor`-isolated property or use an `OSAllocatedUnfairLock`.

### 6.2 Second biggest wall: `ConversationIndexer` on `@MainActor`

`RefreshOrchestrator.indexConversationsOffMain()` (line 35) calls:
```swift
let indexingReport = try await Task { @MainActor in
    try await ConversationIndexer.shared.index(conversations, in: dataStore)
}.value
```

This **explicitly hops to MainActor** for every refresh, even though the caller is already off-main. `ConversationIndexer` is not shown in full, but if it performs DB writes inside this task, it blocks the UI.

**Fix:** Run `ConversationIndexer` on a background actor or `Task.detached`.

### 6.3 Third wall: HNSW index rebuilds are full rebuilds

`ProjectionPipelineService.markVectorIndexSnapshotStale()` (line 380+) marks the snapshot stale, but the actual rebuild (`BurnBarHNSWWritableIndex`) is a **full O(n log n) rebuild** from scratch. There is no incremental add/delete for the HNSW graph.

**Verdict:** For 100k chunks, a full rebuild may take 10–30 seconds on a MacBook. This blocks semantic search until complete. An incremental HNSW update (add/delete nodes without rebuilding) is needed for true scale.

---

## 7. Specific Problematic Patterns with File/Line Evidence

### 7.1 Unbounded memory: `Data(contentsOf: url)` for HNSW index
**File:** `OpenBurnBarCore/Sources/OpenBurnBarCore/BurnBarHNSWVectorIndex.swift`  
**Line:** 280 (`load(from:)`)  
**Pattern:** `loadedData = try Data(contentsOf: url)`  
**Impact:** Loads entire multi-hundred-MB index into RAM.

### 7.2 Main-thread projection work
**File:** `AgentLens/Services/ProjectionPipelineService.swift`  
**Line:** 20 (`@MainActor final class ProjectionPipelineService`)  
**Pattern:** Heavy DB + network work running on `@MainActor`.  
**Impact:** UI stutter during every projection sweep.

### 7.3 Main-thread conversation indexing
**File:** `AgentLens/Services/RefreshOrchestrator.swift`  
**Line:** 35–48 (`indexConversationsOffMain`)  
**Pattern:** `Task { @MainActor in ... }` inside an already-off-main refresh.  
**Impact:** Blocks main thread during refresh.

### 7.4 Sequential retrieval gate
**File:** `AgentLens/Services/SearchService.swift`  
**Line:** 47–53 (`SearchRetrievalGate`)  
**Pattern:** `actor SearchRetrievalGate` with a single `run` method.  
**Impact:** All search queries serialize, even independent ones.

### 7.5 N+1 document hydration
**File:** `AgentLens/Services/SearchService.swift`  
**Line:** 410–440 (`missingChunkIDs` / `missingDocumentIDs` fetches)  
**Pattern:** Two additional DB round-trips after lexical search.  
**Impact:** Latency scales with candidate count.

### 7.6 Unbounded `fullText` materialization
**File:** `AgentLens/Services/DataStore/DataStore+SearchAccess.swift`  
**Line:** 275+ (`scanConversationFullTextForCredentialExposure`)  
**Pattern:** Batched `SELECT id, fullText ... LIMIT 100 OFFSET n`.  
**Impact:** For 10k conversations, 100 round-trips and 100× batch-size string heap pressure.

### 7.7 Monolithic parser cache JSON
**File:** `AgentLens/Utilities/ParserDiskCache.swift`  
**Line:** 65–78 (`persist(_:)`)  
**Pattern:** `JSONEncoder().encode(persisted)` with `.prettyPrinted`.  
**Impact:** Cache write time grows linearly with session count; file size is 2–3× larger than binary.

### 7.8 No connection limit in daemon
**File:** `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`  
**Line:** 480–500 (`runAcceptLoop`)  
**Pattern:** `while !Task.isCancelled { accept(); Task.detached { ... } }`.  
**Impact:** Unbounded concurrency, potential FD exhaustion.

### 7.9 `onChange` storm in `ChatPanel`
**File:** `AgentLens/Views/Chat/ChatPanel.swift`  
**Line:** 75–110 (multiple `.onChange` modifiers)  
**Pattern:** Six `.onChange(of:)` handlers, some triggering `Task { ... }` that reconfigures search services.  
**Impact:** Rapid settings changes can spawn multiple concurrent reconfiguration tasks.

### 7.10 `usageStore.insert(allUsages)` is a single huge write
**File:** `AgentLens/Services/UsageAggregation/RefreshBackgroundWork.swift`  
**Line:** 95 (`try dataStore.usageStore.insert(allUsages)`)  
**Pattern:** All parsed usages inserted in one GRDB transaction.  
**Impact:** For 10k usages, this is a single large write transaction that blocks the writer queue for seconds. Chunked batch insert (e.g., 500 at a time) would reduce writer contention.

---

## 8. Verdict: Can the System Grow Without Major Rework?

### Short answer: **No—not beyond low-thousands of conversations.**

The current architecture is well-suited to the beta phase (hundreds of sessions, single user, daily refreshes). However, to scale to **10,000+ conversations** or **sub-second retrieval latency** under load, the following reworks are required:

| Priority | Rework | Effort |
|----------|--------|--------|
| **P0** | Remove `@MainActor` from `ProjectionPipelineService` and `ConversationIndexer` | Small |
| **P0** | Add chunked batch insert for usages (≤500/transaction) | Small |
| **P0** | Add an LRU query-result cache (`NSCache`) to `SearchService` | Small |
| **P1** | Implement incremental HNSW add/delete (or shard by embedding version) | Medium–Large |
| **P1** | Replace `Data(contentsOf:)` with `mmap` + lazy page loading for vector search | Medium |
| **P1** | Collapse `SearchService` hydration into a single SQL `JOIN` | Medium |
| **P1** | Add connection semaphore to daemon accept loop | Small |
| **P2** | Move parser disk cache from JSON to SQLite or binary plist | Small |
| **P2** | Add SQL-side `FTS5` snippet extraction for credential scanning | Medium |
| **P2** | Pre-compute daily usage rollups to avoid `View.body` aggregations | Medium |

### Positive notes (what's done well):
- **Heavy refresh work is off-MainActor** via `Task.detached` in `UsageAggregator`.
- **Parser disk cache exists** and correctly avoids re-parsing unchanged files.
- **Chunk diffing** (`applySearchChunkDiff`) minimizes unnecessary embedding regeneration.
- **GRDB is used with parameterized queries**—no SQL injection risk.
- **Performance tests exist** (`PerformanceTests.swift`) with reasonable thresholds.
- **Async/await is used consistently**; no legacy GCD callback spaghetti.

### Final grade:
- **Correctness:** A−
- **Performance (current scale):** B+
- **Scalability (future growth):** C+
- **Memory safety:** B
- **Concurrency hygiene:** C+

The codebase shows strong engineering discipline, but several `@MainActor` misplacements and missing caching layers are ticking time bombs for scale. Fix the P0 items and the system can comfortably grow to 10k+ conversations. Without them, users will see beachballs during refresh and retrieval latency will degrade past the point of usability.
