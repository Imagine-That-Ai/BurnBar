# High-Leverage Improvements Plan

## Objective

Implement three high-leverage improvements to OpenBurnBar: (1) retry + circuit breaker for cloud sync, (2) reactivate or prune parked tests, and (3) wire ANN vector search into the daemon. Each improvement targets a distinct quality axis: reliability, test coverage/diligence, and performance/scalability.

---

## 1. Improvement 5 -- Add Retry + Circuit Breaker to Cloud Sync

### Current State

Six `CloudSyncDomain` implementations exist under `AgentLens/Services/CloudSync/`:
- `UsageSyncService.swift` (97 lines)
- `ConversationSyncService.swift`
- `ChatThreadSyncService.swift`
- `SessionLogSyncService.swift`
- `DownloadSyncService.swift`
- `CollaborationSyncService.swift`

All follow an identical error-handling pattern: a single `try/catch` that records the error to `lastSyncError` and, on `permissionDenied` or `unauthenticated` Firestore errors, suppresses sync globally for 10 minutes via `CloudSyncContext.suppressedSyncUntil`. There is **no** retry on transient failures (timeouts, network blips, `unavailable`) and **no** circuit breaker to avoid hammering a degraded backend.

`CloudSyncTypes.swift:66-68` defines `CloudSyncBackoffPolicy` with only `permissionDeniedCooldown`. `CloudSyncContext` has a single `suppressedSyncUntil` field.

### Implementation Plan

- [ ] **1.1 Define `CloudSyncCircuitBreaker` actor** in `AgentLens/Services/CloudSync/CloudSyncCircuitBreaker.swift`. States: `closed` (normal), `open` (tripped, all calls rejected), `halfOpen` (allow one probe). Configuration: `failureThreshold` (consecutive transient failures to trip, default 5), `resetTimeout` (time in open before halfOpen, default 60s), `successThresholdToClose` (probes needed, default 2). Rationale: an actor provides thread-safe state without manual locking, and the standard three-state model prevents thundering-herd retries against a degraded Firestore.

- [ ] **1.2 Define `CloudSyncRetryPolicy` struct** in `CloudSyncTypes.swift` (or a new file). Properties: `maxAttempts` (default 3), `baseDelay` (default 1.0s), `maxDelay` (default 30s), `jitterFactor` (default 0.25). Pure function `delay(for attempt:)` computes exponential backoff with jitter: `min(maxDelay, baseDelay * 2^attempt) * (1 +/- jitterFactor)`. Rationale: keeps retry math testable and decoupled from I/O.

- [ ] **1.3 Classify Firestore errors as retryable vs. terminal** by adding a `CloudSyncErrorClassifier` enum with a static method that inspects `FirestoreErrorCode.Code` and returns `.retryable`, `.permissionDenied`, or `.terminal`. Retryable: `.unavailable`, `.deadlineExceeded`, `.aborted`, `.resourceExhausted`, `.internal`, plus `NSURLErrorDomain` transient codes. Rationale: avoids retrying on permanent errors like `.notFound` or `.invalidArgument`.

- [ ] **1.4 Add a shared `CloudSyncRetryExecutor`** utility (free function or static method) with signature `func withRetry<T>(policy:circuitBreaker:classifier:operation:) async throws -> T`. The executor: (a) checks circuit breaker before each attempt, (b) catches errors, classifies them, (c) on retryable: increments attempt and sleeps per policy, records failure in circuit breaker, (d) on terminal/permissionDenied: propagates immediately, (e) on success: records success in circuit breaker. Rationale: all six sync services share this without code duplication.

- [ ] **1.5 Inject circuit breaker into `CloudSyncContext`**. Add a `let circuitBreaker: CloudSyncCircuitBreaker` property initialized with default config. Add `let retryPolicy: CloudSyncRetryPolicy` with default values. Rationale: single shared instance across all domains; each sync cycle consults the same breaker.

- [ ] **1.6 Wrap each sync service's Firestore calls with `withRetry`**. In `UsageSyncService.sync()`, `ConversationSyncService.sync()`, `ChatThreadSyncService.sync()`, `SessionLogSyncService.sync()`, `DownloadSyncService.sync()`, and `CollaborationSyncService.sync()`, replace the bare `try await batch.commit()` / `try await document.setData()` / `try await query.getDocuments()` calls with the retry executor. Preserve existing `recordSyncError` for final failure propagation. Rationale: each domain already has a `do/catch`; the retry wraps only the network-bound portion.

- [ ] **1.7 Emit structured telemetry on retry and circuit-state transitions**. Each retry attempt and each circuit-state change should log via existing `os_log` / structured logging pattern used elsewhere in the app. Include `domain` (e.g. "usage", "conversation"), `attempt`, `delay`, `circuit_state`. Rationale: observability without adding new dependencies.

- [ ] **1.8 Add unit tests for circuit breaker and retry policy**. Create `AgentLensTests/Active/CloudSyncCircuitBreakerTests.swift` covering: closed->open on threshold, open->halfOpen on timeout, halfOpen->closed on probe success, halfOpen->open on probe failure, concurrent access safety. Create `AgentLensTests/Active/CloudSyncRetryPolicyTests.swift` covering: delay computation, jitter bounds, max-delay cap. Extend existing `CloudSyncServiceTests.swift` with retry-integration tests using a mock Firestore error sequence. Rationale: the circuit breaker is safety-critical; full branch coverage is non-negotiable.

- [ ] **1.9 Register new test files in `project.yml`**. Ensure the new test files are under `AgentLensTests/Active/` (which is already a source path for `OpenBurnBarTests` target) and not in the excludes list. Rationale: tests must compile and run in CI.

### Verification Criteria

- Circuit breaker transitions through all three states correctly under simulated failure sequences.
- Retry policy produces delays within expected bounds for all attempt counts 0..maxAttempts.
- Transient Firestore errors (unavailable, deadline) trigger retries; permanent errors do not.
- Sync services successfully recover after transient failures within retry budget.
- No behavioral change when Firestore calls succeed on the first attempt (zero overhead path).

---

## 2. Improvement 6 -- Reactivate or Prune Parked Tests

### Current State

44 Swift files reside in `AgentLensTests/Parked/`. Per `AgentLensTests/README.md`, parked tests are **not compiled by default**. The `OpenBurnBarTests` target in `project.yml:186-216` sources only from `AgentLensTests/Active` (with some files excluded even there).

The Active directory contains 40 test files. Several files that logically belong in Active already exist in Parked with overlapping names (e.g., `SettingsManagerTests.swift` is in both Parked and Active excludes list; `ProviderQuotaServiceTests.swift` is in both Parked and Active).

### Assessment of Each Parked Test File

**Viable for reactivation (move to Active):**

- [ ] **2.1 `SettingsManagerTests.swift`** (1204 lines, 110+ test methods) -- Comprehensive, self-contained via `UserDefaults` suite isolation and in-memory keychain backend. Currently explicitly excluded in `project.yml:197`. Dependencies: `SettingsManager`, `KeychainStore`, `KeychainStoreBackend`. Assessment: **Reactivate**. Remove from `project.yml` excludes. Rationale: this is the largest and most thorough parked test file; all tests use test doubles, no Firebase/network dependency.

- [ ] **2.2 `DailyDigestManagerTests.swift`** (392 lines) -- Uses `MockUNUserNotificationCenter` conforming to `OpenBurnBarUserNotificationCentering` protocol. Self-contained. Assessment: **Reactivate**. Rationale: well-isolated via protocol-based mock; tests notification scheduling, cancellation, and lifecycle.

- [ ] **2.3 `ParserTests.swift`** (2150 lines) -- Tests for `CopilotParser`, `AiderParser`, `CursorParser`, `CodexParser`, `KimiParser`, `ClineFormatParser`, `ForgeDevParser`, `AugmentParser`, `HermesParser`, `GeminiCLIParser`, `GooseParser`, `WindsurfParser`, `ModelFilterParser`, `FactoryDroidParser`, `ClaudeCodeParser`. All use temp directories and local file fixtures. Currently excluded in `project.yml:199`. Assessment: **Reactivate**. Some may need minor fixups if parser APIs have drifted, but the patterns are sound. Rationale: parser tests are the most directly valuable for regression coverage.

- [ ] **2.4 `CheckpointTests.swift`** (707 lines) -- Tests for `ParserCheckpointStore` using in-memory `DatabaseQueue`. Assessment: **Reactivate**. Rationale: tests persistence correctness guarantees (VAL-PERSIST-004/005/014).

- [ ] **2.5 `OpenBurnBarMigrationTests.swift`** -- Tests database migration paths. Assessment: **Reactivate** if migrations are still relevant and test fixtures compile against current schema. Rationale: migration correctness is critical.

- [ ] **2.6 `OpenBurnBarDaemonManagerTests.swift`** -- Tests daemon lifecycle management. Assessment: **Reactivate** if the `DaemonManager` API is stable. Rationale: daemon management is a reliability surface.

- [ ] **2.7 `OpenBurnBarOperatingLayerTests.swift`** -- Tests the operating layer (controller). Assessment: **Reactivate** if API is stable. Rationale: core business logic.

- [ ] **2.8 UI Tests in `Parked/UI/`** (13 files) -- `MercuryShimmerModifierTests`, `FlowLayoutTests`, `HermesToolCardTests`, `ChatMessageViewTests`, `SessionLedgerSectionTests`, `AppLogoViewTests`, `NarrativeCardViewTests`, `ChatFABTests`, `CLIAssistantConsentSheetTests`, `HermesThinkingViewTests`, `ProviderLogoViewTests`, `InsightBriefCardTests`, `DashboardActionGlyphTests`, `OnboardingCompleteViewTests`, `OnboardingProviderPillTests`, `MiniSparklineTests`. Assessment: **Reactivate** as a batch. These likely use `ViewInspector` (which is a test dependency). Rationale: UI regression tests are high-value.

**Assess-then-decide (may need API alignment):**

- [ ] **2.9 `SearchServiceTests.swift`** -- Currently excluded in both Active and `project.yml:198`. Check whether the `SearchService` API matches. Assessment: **Reactivate if compilable**, else prune. Rationale: search is a core feature.

- [ ] **2.10 `PerformanceTests.swift`** -- Benchmarks. Assessment: **Reactivate** if metrics targets are still meaningful. Rationale: perf regressions.

- [ ] **2.11 `HybridRetrievalServiceTests.swift`** -- References `makeDiscoveryInMemoryStore()`. Currently excluded in Active (`project.yml:189`). Assessment: **Reactivate** only if `makeDiscoveryInMemoryStore` is available in test support. If not, needs a minor support fixture. Rationale: hybrid retrieval is the heart of search.

- [ ] **2.12 `UsageAggregatorTests.swift`** -- Currently excluded in Active (`project.yml:190`). Assessment: **Reactivate** if `UsageAggregator` API is stable. Rationale: usage aggregation correctness.

- [ ] **2.13 `WorkflowInsightRollupServiceTests.swift`** -- Excluded in Active (`project.yml:191`). Assessment: evaluate and **reactivate** if compilable.

- [ ] **2.14 Integration/golden tests** (`ClaudeCodeParserIntegrationTests`, `FactoryDroidParserIntegrationTests`, `HermesParserIntegrationTests`, `CodexTokenAccountingRegressionTests`, `OpenBurnBarSearchIntegrationHarnessTests`, `OpenBurnBarRetrievalReplayGoldenTests`, `OpenBurnBarAuthoringReplayGoldenTests`) -- These rely on fixture files or golden data. Assessment: **Reactivate** only if golden fixtures are present in the repo; otherwise **prune or convert** to non-golden form.

- [ ] **2.15 `SwitcherCLIAuthCoordinatorTests.swift`** -- Excluded in Active. May depend on keychain or system state. Assessment: **Evaluate** and reactivate if isolated.

**Prune candidates:**

- [ ] **2.16 `ProviderQuotaServiceTests.swift`** in Parked -- A file with the same name exists in Active. Assessment: **Delete** the Parked copy after confirming the Active version is a superset. Rationale: dead duplicate.

- [ ] **2.17 `OpenBurnBarSearchIntegrationHarness.swift`** in Parked -- This is a test support file, not a test file. It's excluded in `project.yml:204`. Assessment: **Move to `AgentLensTests/Support/`** or delete if unused. Rationale: support code belongs in Support, not Parked.

- [ ] **2.18 `ViewFixtures.swift`** in Parked/UI -- This is a fixture file, not a test. Assessment: **Move to `AgentLensTests/Support/`** if used by UI tests, or delete. Rationale: same as above.

- [ ] **2.19 `UsageAggregationAndMoodBandTests.swift`** -- Excluded in Active (`project.yml:191`). If this is superseded by `UsageAggregatorTests.swift`, **prune**. Otherwise reactivate.

### Implementation Plan (Execution Order)

- [ ] **2.20 Phase 1: Quick wins** -- Move `SettingsManagerTests`, `DailyDigestManagerTests`, `CheckpointTests` to Active. Update `project.yml` to remove them from excludes. Build and fix any compilation errors.

- [ ] **2.21 Phase 2: Parser tests** -- Move `ParserTests.swift` to `AgentLensTests/Active/Parsers/`. Remove from `project.yml` excludes. Fix any API drift.

- [ ] **2.22 Phase 3: UI tests** -- Move all `Parked/UI/*.swift` files to `AgentLensTests/Active/UI/`. Build and fix ViewInspector-related issues.

- [ ] **2.23 Phase 4: Assess-then-decide batch** -- For each of items 2.9-2.15, attempt compilation in Active. Fix or prune as needed.

- [ ] **2.24 Phase 5: Prune** -- Delete confirmed duplicates and move support files to `AgentLensTests/Support/`.

- [ ] **2.25 Phase 6: Update `project.yml` excludes** -- Clean up the excludes list to reflect the final state. Remove entries for files that now compile successfully.

### Verification Criteria

- All reactivated tests compile and pass in the `OpenBurnBarTests` target.
- No test files remain in `Parked/` unless they have a documented reason (e.g., requires external fixtures not in repo).
- `project.yml` excludes list is minimal and each exclusion has a code comment explaining why.
- CI passes with the expanded test suite.

---

## 3. Improvement 7 -- Wire ANN Vector Search into Daemon

### Current State

The daemon's `BurnBarIndexedSearchService` (`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarIndexedSearchService.swift`, 1191 lines) already has a **complete ANN infrastructure** including:

- `snapshotContext` holding a `BurnBarPersistentVectorIndexSnapshot` (line 12-17)
- `refreshVectorSnapshotIfNeeded()` that builds/loads ANN snapshots (line 505-565)
- `rebuildSnapshot()` that creates the on-disk index (line 674-799)
- `semanticCandidates()` that tries the ANN snapshot first and falls back to `streamingExactSemanticCandidates()` (line 391-457)

**However**, the ANN path has a critical issue. At line 422-435:

```swift
if let snapshot = snapshotContext?.snapshot {
    annCandidates = try snapshot.candidates(for: queryEmbedding, limit: max(annLimit, limit))
        ...
} else {
    annCandidates = try streamingExactSemanticCandidates(...)
}
```

The ANN path **is already wired** but the fallback to `streamingExactSemanticCandidates` (line 872-906) performs an O(n) linear scan by paging through all embeddings from SQLite. This is the performance bottleneck for large corpora.

The `BurnBarMappedPersistentVectorIndexBackend` (the default backend) in `OpenBurnBarCore` also uses a linear scan internally at line 326-365 -- it iterates through all records in the mapped file. The file has `backendID: "mapped_exact"` (line 217), confirming it is not a true ANN structure.

The app-side `VectorSemanticProvider.swift` has a `VectorBackendKind` enum distinguishing `.ann` vs `.exact`, and defaults to `.ann` (line 102). But the underlying backend implementation is the same `BurnBarMappedPersistentVectorIndexBackend` which does brute-force search.

### The Real Gap

The daemon already orchestrates snapshot build/load/search correctly. What's missing is a **true ANN backend implementation** that replaces `BurnBarMappedReadableIndex.search()` with an O(log n) approximate nearest neighbor algorithm. The protocol system (`BurnBarPersistentVectorIndexBackend` / `ReadableIndex` / `WritableIndex`) is perfectly designed for this swap.

### Implementation Plan

- [ ] **3.1 Implement `BurnBarHNSWVectorIndexBackend`** in `OpenBurnBarCore` conforming to `BurnBarPersistentVectorIndexBackend`. This backend should implement Hierarchical Navigable Small World (HNSW) graph search. Configuration: `M` (max connections per layer, default 16), `efConstruction` (build-time beam width, default 200), `efSearch` (query-time beam width, default 64). Rationale: HNSW is the standard ANN algorithm used by usearch, faiss, hnswlib -- it offers O(log n) query time with high recall. The protocol boundary means zero changes to calling code.

- [ ] **3.2 Implement `BurnBarHNSWWritableIndex`** conforming to `BurnBarPersistentVectorIndexWritableIndex`. Build the HNSW graph during `add(key:vector:)`. Serialize the graph structure to disk via `save(to:)` using a documented binary format (header + adjacency lists + vectors). Rationale: the writable index builds the graph incrementally; the save format must support `view(from:)` via memory-mapped I/O for zero-copy loading.

- [ ] **3.3 Implement `BurnBarHNSWReadableIndex`** conforming to `BurnBarPersistentVectorIndexReadableIndex`. Support `view(from:)` using `Data(contentsOf:options:.mappedIfSafe)` for memory-mapped access. The `search(vector:limit:)` method traverses the HNSW graph from the entry point, descending layers and exploring neighbors with beam search at each layer. Rationale: memory-mapping avoids loading the entire index into RAM; beam search with `efSearch` controls the accuracy/speed tradeoff.

- [ ] **3.4 Register `BurnBarHNSWVectorIndexBackend` as a selectable backend**. Update `BurnBarPersistentVectorIndexFactory.defaultBackend()` to return the HNSW backend, or add a new factory method like `.hnswBackend()`. The `backendID` should be `"hnsw"` to distinguish from `"mapped_exact"`. Rationale: the existing fingerprint + backendID system means old exact snapshots are automatically rebuilt with the new backend when the backendID changes.

- [ ] **3.5 Update daemon's `BurnBarIndexedSearchService` initialization** to use the HNSW backend. Change the default value of `snapshotBackend` parameter in `init()` at line 51 from `BurnBarPersistentVectorIndexFactory.defaultBackend()` to the HNSW backend. The existing `refreshVectorSnapshotIfNeeded` and `rebuildSnapshot` methods will automatically rebuild the index with the new backend because the backendID won't match existing snapshots. Rationale: one-line change in the daemon; the rebuild happens lazily on next search.

- [ ] **3.6 Preserve the exact fallback path**. Keep `streamingExactSemanticCandidates()` as-is for the case when no snapshot is available (e.g., first query before build completes). This is the current behavior and is correct. Rationale: graceful degradation.

- [ ] **3.7 Add HNSW-specific configuration to `BurnBarSemanticSearchConfig`** or introduce an `ANNConfig` struct. Parameters: `hnswM`, `hnswEfConstruction`, `hnswEfSearch`. These should be passable to the daemon via its existing config pathway. Rationale: tunable accuracy vs. speed.

- [ ] **3.8 Add unit tests for the HNSW backend** in `OpenBurnBarCore/Tests/`. Test cases:
  - Build index with known vectors, query returns correct nearest neighbors.
  - Recall test: for random vectors, HNSW recall@10 >= 95% compared to exact search.
  - Dimension mismatch throws `invalidVectorDimensions`.
  - Empty index returns empty results.
  - Save/load round-trip preserves search results.
  - Memory-mapped `view(from:)` produces same results as `load(from:)`.
  Rationale: ANN correctness is non-trivial; recall measurement is essential.

- [ ] **3.9 Add integration test in daemon tests** (`OpenBurnBarDaemonTests/`) that exercises the full search pipeline with the HNSW backend: create a test database with chunk embeddings, run `search()`, verify semantic candidates are returned with correct ranking. Rationale: end-to-end validation.

- [ ] **3.10 Benchmark the improvement**. Add a performance test (or script) that compares search latency for the mapped-exact backend vs. HNSW at corpus sizes of 1K, 10K, 50K vectors. Document expected speedup (exact is O(n), HNSW is O(log n), so ~10x-100x faster at 10K-50K). Rationale: validates the improvement claim.

### Alternative Approaches

1. **Wrap an existing C library (USearch/hnswlib) via Swift C interop** instead of a pure Swift HNSW. Trade-offs: faster development via battle-tested library, but adds a C dependency and complicates the build. The codebase currently has no C dependencies in OpenBurnBarCore. The `usearch` reference in `BurnBarPersistentVectorIndex.swift:28` (`index.usearch` filename) suggests USearch was considered but the current implementation is pure Swift mapped-exact.

2. **Use Apple's `vDSP`/`Accelerate` for distance computations** within the HNSW implementation. Trade-offs: significant speedup for distance math (SIMD), but the algorithm bottleneck is graph traversal, not distance computation. Worth doing but secondary.

3. **Product Quantization (PQ) or IVF-PQ** for memory reduction. Trade-offs: better memory footprint for very large corpora (100K+), but adds implementation complexity. Not needed at current scale; HNSW alone solves the performance gap.

### Verification Criteria

- Daemon uses HNSW backend by default (backendID = "hnsw").
- Existing exact snapshots are automatically rebuilt on first search after upgrade.
- Search latency at 10K vectors drops from O(seconds) to O(milliseconds).
- Recall@10 >= 95% compared to exact search on the same corpus.
- All existing daemon search tests pass without modification.
- The exact fallback path still works when no snapshot is available.

---

## Potential Risks and Mitigations

1. **Circuit breaker false-trips during transient Firestore maintenance**
   Mitigation: Conservative defaults (threshold=5, reset=60s) and halfOpen probe mechanism prevent permanent lockout. The `resetTimeout` ensures recovery within 1 minute.

2. **Reactivated tests fail due to API drift**
   Mitigation: Phase the reactivation, starting with the most self-contained tests. Fix compilation errors incrementally. If a test requires more than minor fixups, re-park it with a documented reason.

3. **HNSW implementation correctness**
   Mitigation: Recall benchmarks against exact search are mandatory. The existing `BurnBarMappedPersistentVectorIndexBackend` serves as the ground truth for comparison. Keep the exact backend available as a fallback.

4. **HNSW index build time for large corpora**
   Mitigation: Index building is already lazy and happens on a background queue (`dbQueue`). The existing paged loading pattern (`snapshotPageSize`) limits memory during build. HNSW build is O(n log n) which is acceptable for the expected corpus sizes (< 100K vectors).

5. **Retry storms during Firestore outages**
   Mitigation: The circuit breaker's `open` state rejects calls immediately (no retries). The exponential backoff with jitter spreads load. The `maxDelay` cap (30s) bounds worst-case wait.

## Priority Order

1. **Improvement 6 (Parked Tests)** -- Lowest risk, highest confidence in immediate coverage gain. No production code changes.
2. **Improvement 5 (Retry + Circuit Breaker)** -- Medium risk, direct reliability improvement. Changes are additive (new files + wrapping existing calls).
3. **Improvement 7 (ANN Vector Search)** -- Highest complexity, highest performance payoff. Changes are behind the protocol boundary, limiting blast radius.
