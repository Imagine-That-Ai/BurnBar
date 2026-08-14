# macOS performance — frame budget, dashboard caching, version tickers

This document is the source of truth for the May 2026 macOS performance
sweep (sections 1–6), the June 2026 invisible-wins sweep (sections
7–13, applied 2026-06-09), and the deferred round-2 fixes (sections
14–16, applied 2026-06-10). Every optimization here was applied without
altering visual behaviour. If you're touching one of these surfaces,
please read the relevant section first so the work doesn't regress.

## 1. Wallpaper canvas (`SwarmCanvasView`)

The interactive ember-swarm wallpaper was the largest single CPU
contributor on the menu-bar tray and the fullscreen wallpaper mode.

### Frame rate cap

`SwarmCanvasView` now exposes two parameters:

```swift
public let maxFrameRate: Double?     // nil = honor pace default
public let rendersAsynchronously: Bool
```

The wallpaper panel passes `maxFrameRate: 30.0, rendersAsynchronously:
true`. 30 Hz is below the threshold where human vision can detect frame
drops for organic motion patterns like a swarm, and `Canvas`'s
asynchronous render path moves the heavy `Path` construction off the
main thread.

`sanitizedFrameRate(_:fallback:)` is the static helper that turns the
optional `maxFrameRate` into the actual `TimelineView.periodic` cadence.
It clamps to `[1, 120]` and falls back to `pace == .energetic ? 60 : 30`
when nil.

### Bucketed fills

The data-driven draw branch used to call `ctx.fill` once per particle —
hundreds of `CGContextFillRect`-like ops per frame. Every live path
(swarm palette, logo/shape formation, and color-driver) now accumulates
particles into `[UInt32: (color: RGBA, path: Path)]` keyed on
`RGBA.bucketKey` (an 8-bit-per-channel quantization of the colour),
then issues exactly one `ctx.fill` per bucket. Sparkles render in a
deferred pass so they still sit on top of their dots.

Net effect: a formed constellation that used to be ~900 fills is now
tens of fills plus a handful of sparkle overlays, with no visible
difference to the eye. `SwarmSimulation.planParticleFills` pins the
budget without a `GraphicsContext`.

### Pointer throttling

`BurnBarWallpaperPanel` now batches pointer events through a 30 Hz
coalescing window (`pointerCommitInterval = 1/30`) and a 4 pt movement
gate. Without this, `mouseMoved` could fire at 1000 Hz, each event
flowing into the canvas's `externalPointer` binding, which forced a body
re-evaluation per move.

### Active-space observer

The 1 s `wallpaperPollTimer` and 3 s `wallpaperActivityTimer` were
replaced by `NSWorkspace.activeSpaceDidChangeNotification` plus a 30 s
defensive backstop. The wallpaper now reacts to space switches in real
time and idles between switches.

## 2. Dashboard caching — `usagesVersion`

`DataStoreCoordinator` exposes a monotonically increasing
`usagesVersion: Int` that is bumped on every CONTENT-CHANGING mutation of
`usages` (`replaceUsages` and `replaceUsageSnapshot`). Since June 2026 a
replacement whose rows are byte-identical to the applied set skips the
bump (and the sorts and aggregate rebuild) until the next time-window
boundary — see §14. Every dashboard view that previously observed
`dataStore.lastRefresh` (a `Date`) has been migrated to observe
`dataStore.usagesVersion`.

Why this matters: SwiftUI evaluates a body diff on every published
mutation of an `@Observable`. When views observed `usages` directly,
SwiftUI walked the entire `[TokenUsage]` array for equality on every
write — which is `O(N)` even when the array hasn't changed. The `Int`
ticker is `O(1)` and only changes when a write actually happened.

Migrated views:
- `DashboardDeviceBreakdownCard`
- `DatabaseWorkspaceView` (also dropped a redundant `usages.count`
  observer)
- `MenuBarPopoverView`
- `DashboardChatWorkspaceView`
- `ChatPanel`
- `DashboardLiveCostCurve`
- `ProjectsView`

### Pattern for new dashboard views

```swift
struct MyDashboardCard: View {
    let usages: [TokenUsage]
    let usagesVersion: Int

    @State private var cachedResult: ComputedValue
    @State private var lastVersion: Int = -1

    var body: some View {
        content
            .onAppear { rebuildIfNeeded() }
            .onChange(of: usagesVersion) { _, _ in rebuildIfNeeded() }
    }

    private func rebuildIfNeeded() {
        guard usagesVersion != lastVersion else { return }
        cachedResult = Self.compute(usages: usages)
        lastVersion = usagesVersion
    }

    static func compute(usages: [TokenUsage]) -> ComputedValue { ... }
}
```

The static `compute` function is pure and trivially testable. See
`DashboardLiveCostCurve.buildSamples` and `ProjectsView.computeMergedProjects`
for working examples.

## 3. Chat streaming — in-place mutation

`ChatMessageRecord.content` and `ChatMessageRecord.transcriptPieces` are
now `var` instead of `let`. The streaming hot path mutates these in
place:

```swift
// Before — per token allocation of a new ChatMessageRecord + array reallocation.
messages[idx] = messages[idx].withAppendedContent(chunk)

// After — Copy-On-Write append, only the new bytes are allocated.
messages[idx].content.append(chunk)
streamingTick &+= 1
```

Subscribers should observe `ChatSessionController.streamingTick` to
trigger view updates, not the messages array directly.

## 4. Background work — `BackgroundCadenceCoordinator`

All long-running timer-driven services moved to the cadence coordinator.
See [`background-cadence.md`](background-cadence.md) for the contract.

## 5. Timer publishers — `TimelineView` is the new default

Every `Timer.publish(every:, on: .main, in: .common).autoconnect()`
publisher in SwiftUI views was replaced with `TimelineView(.periodic(...))`
plus an `.onChange(of: context.date)` debouncer:

```swift
// Old
private let timer = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()
// ... onReceive(timer) { advanceIndex() }

// New
TimelineView(.periodic(from: .now, by: 2.2)) { context in
    content
        .onChange(of: context.date) { _, newDate in
            guard newDate.timeIntervalSince(lastTickDate) >= 2.2 - 0.05 else { return }
            lastTickDate = newDate
            advanceIndex()
        }
}
```

The `.common` runloop variant of `Timer.publish` fires straight through
scroll animations, costing one tick per displayed view per scroll frame.
`TimelineView` auto-suspends when the view is off-screen.

Migrated views:
- `CyclingProviderIconView` — provider logo cycler in dashboard chrome
- `InsightCardView` — popover insight rotator (already used `TimelineView`,
  unchanged)

## 6. Validation — May 2026 sweep

The May 2026 work is covered by the following test suites:

- `BackgroundCadenceCoordinatorTests` — interval selection matrix,
  lifecycle signal hook, gating, provider-style intervals, registration
  replacement.
- `SwarmCanvasFrameRateTests` — `sanitizedFrameRate` clamping +
  `RGBA.bucketKey` quantization.
- `DataStoreUsagesVersionTests` — monotonic bumps on `replaceUsages` and
  `replaceUsageSnapshot`.
- `DashboardLiveCostCurveCacheTests` — `buildSamples` matrix
  (monotonicity, totals, bucket counts, purity, out-of-domain rejection).
- `ProjectsMergedProjectsCacheTests` — `computeMergedProjects`
  correctness, slug + display-name fallback, sort order, purity.
- `ChatStreamingMessageMutationTests` — in-place content / transcript
  piece mutation, id stability under content mutation, immutability of
  other fields.

Run them locally:

```bash
xcodebuild -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:OpenBurnBarTests/BackgroundCadenceCoordinatorTests \
  -only-testing:OpenBurnBarTests/SwarmCanvasFrameRateTests \
  -only-testing:OpenBurnBarTests/DataStoreUsagesVersionTests \
  -only-testing:OpenBurnBarTests/DashboardLiveCostCurveCacheTests \
  -only-testing:OpenBurnBarTests/ProjectsMergedProjectsCacheTests \
  -only-testing:OpenBurnBarTests/ChatStreamingMessageMutationTests \
  test
```

## 7. Insight rollups — off the main actor, change-gated writes

`MenuBarPopoverView`, `ChatPanel`, and `DashboardChatWorkspaceView` all
refresh the workflow-insight rollup snapshot. The whole pipeline used to
run on the main actor: four projection/search reads, a health-row read,
a JSON decode, an `O(N ≤ 5000)` stale-path recompute, and — even on the
fully fresh path — a health-row **write** that took the GRDB
`DatabasePool` single-writer queue on every popover open, contending
with refresh persistence and projection sweeps.

The pipeline now lives in `InsightEngine.snapshotAsync()`: `dataStore`
and `nowProvider` are `nonisolated let` (`@Sendable`), a
`MainActorInputs` value struct captures the usages array and counters
once on main, and everything else runs in `Task.detached`.
`upsertHealthIfChanged` compares the candidate health payload against
the **verbatim stored JSON** (avoiding encoder nondeterminism) and skips
the write when status, details, and error fields are unchanged — a
fresh-path popover open no longer touches the writer queue at all, and
the stale path writes the health row exactly once instead of twice.

`MenuBarPopoverView.refreshInsightRollups` is fire-and-await behind a
monotonic request token, so an older off-main snapshot can never
overwrite a newer one when `onAppear`, the `usagesVersion` tick, and the
post-scan `isScanning` flip fire in quick succession. One deliberate
asymmetry: the chat surfaces' `onAppear` bootstrap stays **synchronous**
— the brief ribbon renders in the first frame there, and going async
would introduce a visible pop-in. Only the recurring `usagesVersion`
tick (updating an already-rendered ribbon) uses the async path.

Validation: `WorkflowInsightRollupServiceTests` —
`test_rollupSnapshotAsync_materializesFreshAndPersistsHealth` and
`test_rollupSnapshot_skipsHealthWrite_whenNothingChanged`.

## 8. Log ingestion — cached ISO8601 parsing

`ThreadSafeISO8601DateFormatter.parse()` allocated and configured a
fresh `ISO8601DateFormatter` per call, and four parsers
(`GeminiCLIParser`, `KimiParser`, `WarpParser`, `AugmentParser`) did the
same inline — on the per-line ingestion hot path.

The static `parse()` now routes through a private `NSLock`-guarded
cache holding one fractional and one basic formatter, configured once
and never mutated (consistent with the file's documented stance that
`ISO8601DateFormatter` is not thread-safe). A new `parseBasic()` exposes
the cached `[.withInternetDateTime]` formatter so Gemini/Kimi/Warp keep
their exact prior acceptance semantics — fractional timestamps are still
rejected there; no acceptance widening. All seven existing static-parse
callers get the win for free. Measured 4.47× per parse (`swiftc -O`,
10,000 mixed iterations).

Validation: `ThreadSafeISO8601DateFormatterStaticParseTests` in the
`OpenBurnBarCore` package (5 tests, including a 2,000-iteration
concurrent hammer on the shared cache and a `parseBasic`
acceptance-parity pin).

## 9. Session Logs — memoized filter/group pipeline

`SessionLogsView` derived `sourceFilteredLogs → filteredLogs →
logGroups` as chained computed properties, so every body evaluation
re-ran the full filter + group + sort pass over up to 1,000 records —
roughly 8 passes per keystroke or selection change.

The pipeline is now a key-on-read memo: an `Equatable`
`LogGroupsCacheKey` (an explicit `allLogsVersion` ticker bumped once per
`loadLogs`, `searchText`, source/device filters, `localDeviceId`,
`groupMode`, `dataSource`, `retrievalMatchedIDs`, plus `dayStamp` and a
`dayChangeTick`) is checked on every read, so each input change triggers
exactly one rebuild and all other reads are `O(1)`. Key-on-read was
chosen over `.onChange`-driven rebuilds because several handlers
(`handleSourceFilterChange`, `loadLogs`,
`reconcileSelectionWithFilteredLogs`) read the derived values
synchronously right after mutating inputs, where an `.onChange` cache
would be stale. The logic itself moved into pure static
`computeFilteredLogs` / `computeLogGroups` functions (the section 2
pattern). Time buckets stay correct across midnight two ways:
`dayStamp` is part of the key, and an `NSCalendarDayChanged` observer
bumps `dayChangeTick` proactively.

Validation: `SessionLogGroupsCacheTests` (10 tests covering the full
filter/group matrix plus purity).

## 10. Battery monitoring — event-driven, not polled

`AppDelegate` kept a standing 5 s `Timer` snapshotting IOKit power
sources — 17,280 rounds/day at idle — solely to maintain the
AC ↔ battery boolean that feeds `SwarmCanvasView`'s 15-vs-60 fps
throttle (section 1).

The timer is gone. `setupPowerMonitoring` registers an
`IOPSCreateLimitedPowerNotification` run-loop source (transition-only
semantics, <~20 events/day) on the main run loop in `.defaultMode`, with
an `Unmanaged.passUnretained(self)` context round-trip and a
`Task { @MainActor }` hop in the C callback. The decision logic is a
pure `nonisolated static isOnBattery(powerSourceDescriptions:)` with
byte-identical semantics (`kIOPSPowerSourceStateKey ==
kIOPSBatteryPowerValue` over the IOPS snapshot). Transitions now apply
instantly instead of up to 5 s late; the initial sync at registration
and the Low Power Mode (`NSProcessInfoPowerStateDidChange`) observer are
unchanged, and teardown removes + invalidates the retained
`CFRunLoopSource`.

Validation: `PowerSourceMonitoringTests` (6 pin tests on the pure
helper: empty, AC-only, battery-only, battery-among-AC, offline,
missing state key).

## 11. Daemon heartbeat — halved cadence, one atomic write

`BurnBarDaemonHeartbeat` beat every 5 s with a manual tmp-write →
`removeItem` → `moveItem` → chmod dance — ~5 filesystem mutations per
beat, ~86k FS ops/day at idle.

`defaultInterval` is now 10 s (still 2× inside the unchanged 20 s stale
threshold; the doc comment records the threshold/2 constraint and a test
pins it), and `writeSnapshot` collapsed to a single
`Data.write(.atomic)` — which does the temp+rename internally — with the
`0o600` chmod only on first create. Darwin's atomic replace preserving
the existing file mode was proven empirically and is pinned by a
regression test so a platform/Foundation change fails CI. Net idle I/O:
~86k → ~17k FS ops/day. The reader and its 20 s threshold are untouched;
the accepted trade is a missed-beat margin of 2× instead of 4× on a
diagnostic-only staleness signal.

Validation: `BurnBarDaemonHeartbeatTests` in the `OpenBurnBarDaemon`
package — `test_writeSnapshot_overwriteKeepsOwnerOnlyPermissions` and
`test_defaultInterval_staysWithinHalfTheStaleThreshold`, alongside the
pre-existing round-trip tests.

## 12. DEBUG GRDB query tracer + N+1 budgets

`OpenBurnBarQueryTracer` existed but was never installed, so N+1
regressions on the hot read paths were invisible.
`DataStoreCoordinator` now wires it into all three pool-open sites
(encryption-off, encrypted, plaintext escape hatch) via an
`#if DEBUG`-gated `installDebugQueryTracer(on:)` — registered strictly
**after** `DatabaseEncryptionService.makeConfiguration`, so the
SQLCipher `PRAGMA key` closure runs before the trace hook and the key
never reaches the trace log. The in-memory log is capped at 5,000
entries (oldest-half trim); release builds compile the helper to an
empty body, so shipping behaviour is byte-identical.

The budgets are self-calibrating rather than absolute: each test asserts
the query count with a handful of rows equals the query count with ~10×
the rows, so any per-row query growth fails as a graceful
`XCTAssertEqual` — plus a `tracer.assertMaxQueries(count: 64)` exercise
of the documented API.

Validation:
`DashboardUsageViewModelTests.test_dashboardSnapshotQueryCount_isIndependentOfRowCount`
and
`WorkflowInsightRollupServiceTests.test_rollupSnapshotQueryCount_isIndependentOfUsageVolume`.

## 13. Validation — June 2026 sweep

Run the June 2026 suites locally:

```bash
xcodebuild -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:OpenBurnBarTests/WorkflowInsightRollupServiceTests \
  -only-testing:OpenBurnBarTests/SessionLogGroupsCacheTests \
  -only-testing:OpenBurnBarTests/PowerSourceMonitoringTests \
  -only-testing:OpenBurnBarTests/DashboardUsageViewModelTests \
  test

(cd OpenBurnBarCore && swift test \
  --filter ThreadSafeISO8601DateFormatterStaticParseTests)

(cd OpenBurnBarDaemon && swift test \
  --filter BurnBarDaemonHeartbeatTests)
```

## 14. No-change replace short-circuit — `UsageReplaceGate`

The periodic refresh pipeline reloads the full usage table every cadence
tick (60 s minimum while active; `BillingRefreshCoordinator.reconcile`
always runs `deleteAndReload` + `fetchAllUsage`, so `UsageAggregator.
refreshAll` lands in `dataStore.replaceUsages` on every successful tick).
Before this gate, every tick — even with zero new usage — re-sorted the
full table twice (`DataStoreCoordinator` + `DashboardUsageViewModel`),
rebuilt the entire aggregate cache on the main actor, and bumped
`usagesVersion`, invalidating every cached dashboard/popover compute.

`DataStoreCoordinator.applyGateAdmits` (backed by
`AgentLens/Services/DataStore/UsageReplaceGate.swift`) short-circuits BOTH
replace paths when:

1. the order-insensitive `UsageContentFingerprint` (row count + combined
   per-row hash) matches the previously applied set, **and**
2. the clock has not crossed `UsageReplaceGate.nextWindowBoundary` — the
   next local midnight, or the first moment an in-window row exits the
   rolling 7d/30d windows (minus a one-hour DST safety margin).

The boundary clause is **load-bearing**: the old every-tick bump was what
reset "Today" at midnight and decayed the rolling-window totals on an
idle dashboard. A skipped tick still updates `lastRefresh`.

The original always-bump contract test
(`testUsagesVersion_bumpsOnEachReplaceUsagesCall_evenWithIdenticalData`)
was deliberately inverted to
`testUsagesVersion_skipsBumpOnContentIdenticalReplaceUsages`.

Validation: `DataStoreUsagesVersionTests` (skip/bump/boundary matrix,
injectable `nowProvider`) and `UsageReplaceGateTests` (fingerprint
order-insensitivity, boundary math, exit-margin fail-closed).

## 15. Menu-bar popover prewarm — `PopoverContentPrewarmer`

`popoverDidClose` nils the popover's `contentViewController` on every
close (deliberate fresh-state fix, fd19d53ac), which used to mean EVERY
click rebuilt the 1,392-line `MenuBarPopoverView` hierarchy +
`NSHostingController` and forced a synchronous `fittingSize` layout
inside the click handler.

`AppDelegate` now re-primes the content controller **off the click
path**: once when `AppCommandRouter.makeMenuBarPopoverContent` is
(re)installed — i.e. exactly when `startupState.runtimeContext` becomes
ready, never on a fixed timer — and again on the next main-queue turn
after each close. Re-priming builds a brand-new view from the current
factory, preserving the fresh-state-per-show semantics, and primes
`fittingSize` so `showPopover` reduces to a size assignment + `show()`.
A factory reinstall invalidates any prewarmed content (otherwise the
startup-recovery `EmptyView` fallback could freeze into the popover);
priming is skipped while the popover is shown (the close re-prime picks
up the latest factory). The synchronous build inside `showPopover`
remains as the fallback when a click outruns the prewarm.

Validation: `PopoverContentPrewarmerTests` (coalescing, skip-while-shown,
rebuild-on-reinstall, fallback ordering).

## 16. Daemon RPC plane — 64 KB reads + aggregated controller snapshot

`OpenBurnBarDaemonSocketClient.sendEncoded` read responses through a
1,024-byte buffer (one `read()` syscall per KB of response). The buffer
is now 64 KB with preallocated response capacity; the daemon's own
request reader got the same bump.

`controllerRuntimeSnapshot` was never one RPC — it was SIX sequential
RPCs (summary, questions, followups, missions, notification health,
simulator list), each paying the full socket/setsockopt×3/connect/close
cycle, on every popover open, periodic tick, and startup recovery; the
four controller mutations each issued the same six as a follow-up (7
connections per action). The daemon now serves an aggregated
`daemon.controller.runtime_snapshot` RPC (6→1) and embeds the refreshed
snapshot payload in the four mutation responses (7→1).

**Version-skew tolerance:** the app may talk to an older running daemon.
The client probes the aggregated RPC once, falls back to the legacy
six-RPC path on failure, and remembers the downgrade for the process
lifetime; mutation responses treat the embedded snapshot as optional and
fall back to a follow-up snapshot call when absent. Old apps decoding new
daemon responses simply ignore the extra field.

Validation: `BurnBarMissionControlContractsTests` (core round-trip +
absent-field tolerance), `BurnBarDaemonControllerRuntimeSnapshotTests`
(daemon end-to-end: aggregated == per-list, mutations embed the
snapshot), `BurnBarDaemonSocketRPCCoverageTests` (handler registration),
and `DaemonSocketClientBufferTests` (client: >64 KB response reads over a
local socket, legacy fallback + downgrade memo).

---

## §17 — Round-4 performance sweep

A comprehensive sweep across macOS (AgentLens, OpenBurnBarCore,
OpenBurnBarDaemon) and iOS (OpenBurnBarMobile) targeting state-of-the-art
throughput, latency, memory, and energy without altering features or
visuals.

### Tier A — hot-path optimizations

**A1 — ParserDiskCache binary plist persistence.** The parser disk cache
persisted JSON with `.prettyPrinted` + `.sortedKeys`, producing slow writes
and bloated cache files. Switched to binary plist
(`PropertyListEncoder`) with a dual-read fallback (plist first, then JSON)
for backward compatibility and in-place upgrade of existing JSON caches.
~3–5× faster encoding, ~2–3× smaller files, native `Date` fidelity.

**A2 — SearchQueryCache bounded LRU + metrics.** The search query cache
was an unbounded dictionary with no eviction and no observability.
Refactored to a bounded LRU cache (default 256 entries) with
opportunistic expired-entry sweeps, LRU eviction on insertion, and
metrics (hits, misses, evictions, expired evictions, entry count) emitted
via `OpenBurnBarMetrics`.

**A3 — Daemon accept-loop connection back-pressure.** The daemon's
`runAcceptLoop` spawned an unbounded `Task.detached` per connection,
risking file descriptor exhaustion under load. Introduced
`BurnBarConnectionGate` to cap simultaneously in-flight connection
handlers; new connections at capacity are immediately closed.

**A4 — Single-scan SQL for fullText occurrence counts.**
`countOccurrencesInConversationFullText` ran a full-table scan per
pattern via `UNION ALL LENGTH/REPLACE` (N scans for N patterns).
Refactored to a single scan that sums all pattern expressions in one
pass. Mathematically identical: `SUM(a_i + b_i) == SUM(a_i) + SUM(b_i)`.

**A5 — SearchService hydration JOIN collapse.** The hydration path
issued two separate DB round-trips: one for missing chunks, another for
their parent documents. Introduced `fetchChunksWithDocuments` to perform
a single JOIN query, retrieving both chunks and documents in one pass.

**A6 — iOS TrendAtlasCard digest/insights memoization.** `TrendAtlasCard`
rebuilt `TrendDataDigest.build(...)` and `TrendInsightEngine.insights(...)`
on every `body` evaluation. Introduced `DigestCacheStore`, an
`@StateObject`-backed reference cache that recomputes only when input
hashes change.

**A7 — iOS HermesSquareRoot rollbackSections cache.** The
`rollbackSections` computed property filtered and sorted
`rollbackService.snapshotsBySession` on every `body` evaluation. Added a
`@State` cache rebuilt via `.onChange` only when the underlying data
changes.

### Tier B — structural improvements

**B1 — Incremental HNSW delta segments.** The HNSW vector index is an
immutable binary snapshot; every projection cycle that added or removed
embeddings triggered a full O(n log n) rebuild. Introduced
`BurnBarVectorIndexDelta` and `BurnBarVectorIndexDeltaOverlay` following
the LSM-tree "base + delta" pattern: the immutable base snapshot handles
O(log n) HNSW search; appended vectors are searched via O(k) brute-force
on the bounded delta; tombstoned keys are filtered from base results. The
delta is bounded by `compactionThreshold` (default 2,000); the caller
triggers a background compaction to fold the delta into a new base when
the threshold is exceeded. Added `searchKeys(for:limit:)`,
`chunkID(forKey:)`, and `keyToChunkIDMapping` to
`BurnBarPersistentVectorIndexSnapshot` to support the overlay merge.

The delta overlay is wired into `VectorSemanticCandidateProvider`'s
snapshot lifecycle. When the embedding version fingerprint changes
(chunks added/updated/deleted), the provider computes a delta against the
existing base snapshot instead of triggering a full rebuild. The delta
computation uses a cheap O(n) metadata scan (`fetchChunkEmbeddingKeys` —
`chunkID` + `updatedAt` only, no `vectorBlob`) to diff against the base
mapping, then an O(k) vector fetch for only the changed chunkIDs. When
the total changes exceed the compaction threshold (`max(2000, baseSize /
5)`), the provider falls through to a full rebuild. Delta metrics
(appended count, tombstoned count, compaction threshold, base vector
count) are surfaced in `SemanticRetrievalHealthDetails` for observability.

Validation: `BurnBarVectorIndexDeltaTests` (14 tests: append, tombstone,
re-add, clear, compaction threshold, parity vs. full rebuild, key codec
allocation), `VectorSemanticDeltaIntegrationTests` (6 tests: add via
delta, delete via tombstone, update via override, compaction fallback,
parity with full rebuild, fresh-launch disk recovery).

**B2 — Streaming Claude JSONL parser (bounded accumulator).** The
`ClaudeConversationAccumulator.fullText` grew unbounded via O(n²) string
concatenation (`fullText += ...` on every message). Refactored to an
array-based accumulator that joins once at finalize time (single O(n)
allocation) with a configurable `maxFullTextBytes` cap (default 1 MB).
Word/message metrics continue counting after the cap. Also added
`maxLineBytes` guard (default 16 MB) to `BufferedLineSequence` to skip
pathological single-line inputs that would blow up the read buffer.

Validation: `ConversationParsingTests` (4 new tests: cap enforcement,
word count continues after cap, join-once-at-finalize, UTF-8 scalar
boundary truncation), `BufferedLineSequenceTests` (3 new tests: oversized
line skipped, oversized line at EOF skipped, normal lines unaffected).

**B3 — SQL-side pre-filter for credential scans.** The credential
exposure scanner loaded `fullText` for every conversation matching
metadata filters, then applied regex in Swift. Added
`fetchTranscriptScanBatchWithCredentialPreFilter` with `INSTR`-based
WHERE clauses using distinctive credential indicator substrings (`sk-`,
`AIza`, `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `api_key`, `access_token`,
`secret_key`, `secret`, `token`, `password`, `bearer `, `private_key`,
`aws_access_key`, `slack_token`). SQLite skips conversations that don't
contain any indicator before loading their `fullText` into Swift memory.
The pre-filter is high-recall/low-precision; the Swift-side regex still
provides precise filtering.

Validation: `CredentialExposureScanTests` (10 tests: OpenAI key, GitHub
token, Google API key, generic key assignment, `PASSWORD=` / `TOKEN=`
recall, clean conversation skipped, pre-filter selectivity, pre-filter
false-positive rejection, placeholder filtering, limit enforcement).

---

## §18 — O(delta) refresh tick + bounded cloud-total fetch (July 2026)

The July 2026 diligence review flagged the last O(total-history)-per-tick
surfaces the §14 gate could not remove: the gate only skipped the APPLY,
but every cadence tick still (a) fetched the ENTIRE `token_usage` table
2–3× for the billing reconcile (`fetchAllUsage` for the baseline, again
after `deleteAndReload`, again after `persistAndReload`), (b) handed the
full row array back to the main actor to fingerprint-and-discard, and
(c) `fetchCloudTotal` downloaded every 90-day usage document per sync
cycle just to sum one field.

**Write marker (`UsageTableWriteMarker`).** `UsageStore` (and the
test-only `AtomicIngestionTransaction`) now bump a monotonic in-process
counter whenever a committed transaction actually changed `token_usage`
rows — measured with `db.totalChangesCount` deltas inside the write
closure, so the value-diff `WHERE` gates on the upserts mean an idle
re-parse of unchanged sessions does NOT advance it. `markSynced` is
deliberately excluded (`syncedAt` is not part of decoded row content).

**Marker-gated reload (`DataStoreCoordinator.reloadUsagesIfChanged`).**
`UsageAggregator.refreshAll()` / `refresh(provider:)` end with this
instead of an unconditional full reload: if the marker is unchanged since
the last reload AND the clock has not crossed the §14 window boundary
(midnight / rolling 7d/30d exits), the tick costs one actor hop and a
`lastRefresh` touch. When content DID change, the exact same
`fetchAllUsage → replaceUsages` full path runs, so steady-state displayed
numbers are bit-identical to the old architecture. The §14 fingerprint
gate remains as the second layer.

**Bounded billing baseline.** `BillingRefreshCoordinator.reconcile` now
takes `fetchReconciliationBaseline(cutoff)` — rows intersecting
`[min(startOfDay(record.date)), ∞)` via the existing intersection
predicate — instead of `fetchAllUsage`. Supplemental reconciliation only
ever matches rows intersecting a record's day window, so any superset of
the bounded set yields byte-identical output (`RefreshTickPerfTests`
asserts bounded == full on a 120-day fixture with a long-running session
straddling the window edge). Drift detection's per-credential all-time
cost sums moved to one SQL `GROUP BY`
(`UsageStore.driftCredentialCostTotals`), and the delete/persist steps
return counts instead of re-fetching the whole table.

**Cloud total via server-computed rollup.** `DownloadSyncService.
fetchCloudTotal` reads the pre-computed `users/{uid}/usage_rollups/90d`
document (`totals.costUsd`, the same source iOS uses): one document read
instead of O(doc-count) downloads or a per-sync aggregation RPC. A missing
or undecodable rollup yields a nil total (the UI shows a placeholder)
rather than a fabricated zero.

**Ratchet.** `scripts/debt/check-usage-refresh-tick-budget.sh`
(baseline `budgets/usage-refresh-tick-baseline.json`) freezes production
`fetchAllUsage()` call sites at 2 (the marker-gated reload + the actor
forwarder) and asserts ZERO raw `token_usage` write statements outside
the marker-aware stores — a new raw writer would silently stale the
marker-gated dashboard until the next window boundary.

Validation: `RefreshTickPerfTests` (`BillingReconcileBoundedBaselineTests`
bounded==full supplemental equality + SQL/Swift drift-totals parity,
`UsageTableWriteMarkerTests` bump/no-bump matrix incl. idle re-upsert and
`markSynced`, `ReloadUsagesIfChangedTests` skip/reload/boundary matrix +
tick-path-vs-legacy-full-recompute aggregate equality).
`DownloadSyncServiceRollupTotalsTests` covers the rollup read end to end:
one-read proof, verbatim costUsd, integer-stored cost decode, and nil on
missing or undecodable rollups.

---

## §19 — Graphics / GRDB / quota mining (August 2026)

Three remaining hot paths after §18, measured without Instruments:

### Lane 1 — Constellation / logo fills

`SwarmSimulation.draw` still took the per-particle fill path for
shape, provider-logo, and color-driver frames (`shouldRenderIndividually`).
Dashboard Constellation and Website backgrounds spend half their cycle
formed, so the 30 Hz cap was paying ~900 `ctx.fill` calls/frame.

The individual path is gone. Every non-glyph dot batches through
`RGBA.bucketKey`; sparkles stay a deferred second pass. Fill counts are
pinned by `SwarmCanvasFrameRateTests` (`planParticleFills`).

### Lane 2 — Dashboard snapshot + idle persist

`fetchDashboardUsageSnapshot` ran 14 separate `fetchUsageTotals`
round-trips for the last-7-day series and rolling average (two loops
over the same days). Those windows now come from one
`fetchOverlappingDayCostAndTokens` scan using the same intersection
predicate, so overlapping long-runners stay bit-identical.
`test_dashboardSnapshot_last7DaySeriesMatchesPerDayTotals` pins that
equality; `test_dashboardSnapshotQueryCount_isIndependentOfRowCount`
tightens the SELECT ceiling from 64 to 24 (ratcheted to 12 in §20).

Idle usage ticks still issued `INSERT…ON CONFLICT` for every parsed row
even when the value-diff WHERE gate changed nothing. `insertChunked`
now fingerprints persist-visible content (not UUID/`createdAt`) and
skips the upsert storm when the fingerprint matches and
`UsageTableWriteMarker` has not advanced. Fail-closed: any other writer
or a token/cost change re-runs the upserts.
`UsagePersistSkipTests` pins skip vs. write.

### Lane 3 — Grok `updates.jsonl` resume

Codex and Claude already resume from `ParserDiskCache`. Grok re-read
every `~/.grok/sessions/**/updates.jsonl` on every usage tick.
`GrokParser` now caches exact turn totals by mtime+size (token
breakdowns only — no conversation bodies) and skips `chat_history.jsonl`
on usage-only passes when exact totals exist. Child-session
reconciliation still runs in memory so parent totals stay correct.
`test_parse_skipsUnchangedUpdatesJsonlOnSecondPass` pins scan vs. hit
counts and grown-file invalidation.

Validation:
- `OpenBurnBarTests/SwarmCanvasFrameRateTests`
- `OpenBurnBarTests/DashboardUsageViewModelTests`
- `OpenBurnBarTests/RefreshTickPerfTests` (`UsagePersistSkipTests`)
- `OpenBurnBarCoreTests/GrokParserTests`

---

## §20 — Remaining hot paths (August 2026, round 2)

Round 1 closed constellation fills, overlapping-day scans, idle persist
skip, and Grok resume. This round burns down the leftovers that were
still on the 60s/appear path, without changing usage totals, quota
remaining%, `resetsAt`, or `.exact|.estimated|.unavailable`.

### Lane 1 — Graphics

Chart Studio, Burn, and Trend Atlas were rebuilding gallery facts /
insights on every Hermes token and every SwiftUI body. iOS now memoizes
through `TrendDigestCacheStore` / `ChartStudioDerivedCache` keyed on
digest equality. Android uses unconditional `remember(digest)` so
Compose never calls `TrendInsightEngine` per recomposition.

Substrate `sizePx` uses `upperMedian` (`selectNth`, same as
`sorted()[count/2]`) instead of a per-frame sort. Editorial website
backdrop requests `streamingThrottledFrameRate(30)` instead of the 60
fps canvas default. Insight time-series domains are one `DomainLayout`
pass computed once per body. Quota dials flatten the trimmed stroke
with `.compositingGroup()` before the drop shadow so animated `Circle.trim`
does not re-blur every frame.

### Lane 2 — GRDB

Dashboard window totals (today / 7d / 30d / month / all-time) come from
one `GROUP BY` over membership flags (`CASE WHEN <intersection> THEN 1`)
evaluated once per window per row, then `SUM(flag * column)`. Overlapping
day cost/token series uses the same flag shape (one bind set per day).
Row fetches per window stay: credential and project summaries need
`LIMIT` rows, and all-time `LIMIT` cannot be reused for shorter windows.
`test_dashboardSnapshot_windowTotalsMatchPerWindowAggregateQueries`
pins totals against per-window `fetchUsageTotals`; the SELECT ceiling
is 12.

Database workspace snapshot counts are one `GROUP BY status` each for
shared-artifact sync states and projection jobs.

### Lane 3 — Quota

`QuotaRefreshPolicy` now drives Mac `refreshIfNeeded` and Linux
`BurnBarLinuxQuotaRefreshService`. High remaining (≥50%) refreshes every
30m, 20–50% every 10m, <20% every 3m, unknown 15m, clamped to
`resetsAt` / 60s / 4h. `maxAge <= 0` still force-refreshes everyone.
Subset refreshes do not occupy the full `refreshAll` in-flight slot.

SuperGrok pacing tail-reads JSONL from EOF in 64KB chunks until the
newest timestamp in a chunk is older than the 2h window. Lines longer
than a chunk are carried, not dropped. `sawAnyEvent` still reflects
historical lines so the empty-log status message does not flip.

Claude JSONL quota scans resume from the previous newline when a
transcript only grew. A mid-line last parse fail-closes to a full
re-read. Codex rollout enumeration skips `rollout-*.jsonl` whose mtime
is older than the 7-day freshness cutoff and prunes those cache
entries.

### Named leftovers

- `ChartsDataService.refresh` still materializes `fetchAllUsage()` for
  all-time. `ChartsSnapshot.build` needs per-session rows (heatmap,
  outliers, project entropy); a SQL rewrite is a different coherent unit.
- `ConversationIndexer.index` still opens one write transaction per
  *changed* conversation. Steady-state ticks already skip via the
  batched identity map; first-index of thousands of new rows is the
  remaining cost.
- `fetchDailySummaries` still `GROUP BY DATE(startTime)` (start-day
  membership, not the intersection predicate). Do not fold it into the
  overlapping-day scan without a dedicated equality test.
- `QuotaRefreshActor.fetchAllSnapshots` still runs provider, account,
  and switcher phases sequentially (4-wide inside each phase). Wall-clock
  only; snapshots stay last-write-wins.
- Usage parse still must not share indexing `idx2:` discovery tokens /
  `minimumFileModificationDate` with conversation indexing.

Validation:
- `OpenBurnBarTests/SwarmCanvasFrameRateTests`
- `OpenBurnBarTests/DashboardUsageViewModelTests`
- `OpenBurnBarTests/ProviderQuotaServiceTests`
- `OpenBurnBarTests/XAIQuotaAdapterTests`
- `OpenBurnBarTests/ClaudeQuotaJSONLScannerTests`
- `OpenBurnBarCoreTests/QuotaRefreshPolicyTests`
- `OpenBurnBarCoreTests/CodexRolloutScannerTests`
- `OpenBurnBarCoreTests/SuperGrokLogScanTests`
- `OpenBurnBarCoreTests/ClaudeJSONLResumeTests`
- `OpenBurnBarDaemonTests/BurnBarLinuxQuotaRefreshServiceTests` (Linux)

---

## §21 — Remaining hot paths (August 2026, round 3)

Round 2 closed adaptive quota TTL, SQL window flags, and Claude JSONL
resume. This round burns down the leftovers that were still on the
Charts appear path, first-index writes, and decorative 60 fps loops.

### Lane 1 — Graphics

Cooking and mining loaders were ticking `TimelineView` at 60 fps for a
bounce/swing the eye cannot resolve above ~30 Hz. Both now request
`1.0 / 30`. The Cloud store hero orbit was `TimelineView(.animation)`
uncapped (sparks were already 30 fps); the orbit matches. iOS easter-egg
canvas now uses the same 30 fps cap as macOS.

### Lane 2 — GRDB / Charts

`ChartsDataService.refresh` issued `fetchAllUsage()` (or the selected
window) **and** a second last-31-day `fetchUsage`. Every bounded
`TimeRange` (today / 7d / 30d / month) sits inside that 31-day covering
window, so one intersection scan now supplies both row sets.
`deriveWindows` filters with `TokenUsage.intersects(dateRange:)`, the
same predicate as `fetchUsage(in:)`. All-time still materializes every
row because heatmap / outliers / entropy need per-session values.

`ConversationIndexer.index` still skipped unchanged rows from a batched
identity map, then opened **two** transactions per changed row (upsert +
`fetchConversation` + enqueue). Changed rows now persist in chunks of 64
inside one write: upsert uses the existing ON CONFLICT body, and a
projection job is enqueued only when `deletedAt` is nil so tombstones
stay buried. Steady-state ticks remain O(ceil(N/500)) reads and zero
writes.

Database workspace snapshot counts/fetches launch concurrently so GRDB
pool reads overlap; assignments still hop back to the main actor.

### Lane 3 — Quota

Factory droid `.settings.json` files whose mtime is older than 30 days
cannot contribute to the 5h / 7d / 30d displayable buckets, so they are
skipped (missing mtime fail-closes to a full read). Historical-only trees
still return a local snapshot instead of flipping to unavailable.
Antigravity `history.jsonl` tail-reads from EOF in 64KB chunks until the
newest timestamp in a chunk is older than the 5h window, with the same
long-line carry as SuperGrok. UTF-8 split fail-closes to a full-file
read, then to unavailable.

### Named leftovers

- `fetchDailySummaries` still `GROUP BY DATE(startTime)` (start-day
  membership, not the intersection predicate). Do not fold it into the
  overlapping-day scan without a dedicated equality test.
- `QuotaRefreshActor.fetchAllSnapshots` still runs provider, account,
  and switcher phases sequentially (4-wide inside each phase). Overlapping
  the phases would race the Codex rollout cache (whole-cache last-write-wins).
- Usage parse still must not share indexing `idx2:` discovery tokens /
  `minimumFileModificationDate` with conversation indexing.
- `ChartsSnapshot.build` still needs per-session rows; a SQL rewrite of
  heatmap / outliers / entropy is a different coherent unit.
- Warp / Kilo Code quota fallbacks still `Data(contentsOf:)` whole files
  (JSON arrays / unstructured telemetry, not append-only JSONL).
- Goose / Antigravity **usage parsers** still scan from offset 0 because
  they accumulate conversation bodies, not just windowed quota counts.

Validation:
- `OpenBurnBarTests/ChartsSnapshotBuilderTests`
- `OpenBurnBarTests/IncrementalConversationIndexingTests`
- `OpenBurnBarTests/SwarmCanvasFrameRateTests`
- `OpenBurnBarTests/LocalSearchSchemaStoreTests` (workspace snapshot)
- `OpenBurnBarCoreTests/FactoryQuotaSessionSkipTests`
- `OpenBurnBarCoreTests/AntigravityJSONLTailTests`
- plus the §20 quota / dashboard suites

---

## §22 — Remaining hot paths (August 2026, round 4)

Round 3 closed the Charts covering scan, indexer write batching, and
Factory / Antigravity quota tails. This round burns down the leftovers
that were still whole-file on the quota tick or re-parsed on every
usage tick.

### Lane 1 — Graphics

`BurnBarLogoFormationView` (splash / onboarding) was ticking `TimelineView`
and the glyph `Timer` at 45 fps. Both now use `1.0 / 30` so wall-clock
formation time stays the same at the editorial decorative cap.

### Lane 2 — Quota

Warp's local telemetry fallback still needed the newest credit bucket
from unstructured `warp_network*.log` files. It now reads the last
512 KB first (`CodexQuotaScanPolicy.tailReadBytes`). A UTF-8 split or
a tail with no credit fail-closes to a full-file read so remaining% /
`resetsAt` stay bit-identical. Factory session timestamps reuse
`ThreadSafeISO8601DateFormatter.parse` instead of allocating a pair of
formatters per `.settings.json`.

### Lane 3 — Usage parsers

Usage ticks do not share indexing `idx2:` / `fileDiscoveryTracker` /
`minimumFileModificationDate`, so `ParserFileReadGate` admits every
session file every 60s. Gemini CLI now keeps a mtime+size disk cache of
token totals (never bodies) and skips transcript markdown on usage-only
passes. Cache keys for files that still exist are kept even when a
watermark or tracker skips the content read, so an indexing pass cannot
evict a warm usage cache (Grok `updates.jsonl` got the same prune fix).

Cursor Agent and Antigravity usage parsers parse timestamps through the
shared formatter instead of two `ISO8601DateFormatter` instances per
session. Cursor Agent also skips `fullText` / key-file / tool-name
assembly when `includeConversationBodies` is false; token estimates
still count characters.

### Named leftovers

- `fetchDailySummaries` still `GROUP BY DATE(startTime)` (start-day
  membership, not the intersection predicate). Do not fold it into the
  overlapping-day scan without a dedicated equality test.
- `QuotaRefreshActor.fetchAllSnapshots` still runs provider, account,
  and switcher phases sequentially (4-wide inside each phase). Overlapping
  the phases would race the Codex rollout cache (whole-cache last-write-wins).
- Usage parse still must not share indexing `idx2:` discovery tokens /
  `minimumFileModificationDate` with conversation indexing.
- `ChartsSnapshot.build` still needs per-session rows; a SQL rewrite of
  heatmap / outliers / entropy is a different coherent unit.
- Kilo Code's `KiloCodeQuotaAdapter` still `Data(contentsOf:)` task JSON
  arrays, but it is not on the quota refresh path (`quotaSignalProviders`
  / the adapter registry omit it). Cline-family usage still goes through
  `ClineFormatParser` (now with the idle-tick disk cache in §23).
- Warp **usage** parsing still reads a changed `warp_network*.log` in
  full because every Body object can contribute a usage row.
- Goose / Antigravity **usage parsers** no longer rescan unchanged
  transcripts on idle ticks (see §23). A miss still reads from offset 0
  because token estimates accumulate conversation characters.

Validation:
- `OpenBurnBarTests/SwarmCanvasFrameRateTests`
- `OpenBurnBarTests/WarpQuotaAdapterMattersTests`
- `OpenBurnBarCoreTests/WarpTelemetryTailTests`
- `OpenBurnBarCoreTests/GeminiCLIParserCacheTests`
- `OpenBurnBarCoreTests/GrokParserTests`
- `OpenBurnBarCoreTests/LiftedParserBoundaryTests` (Cursor Agent usage-only)
- plus the §21 Charts / indexer / quota suites

---

## §23 — Remaining hot paths (August 2026, round 5)

Round 4 cached Gemini CLI and tailed Warp quota. Usage ticks still had
no `fileDiscoveryTracker` / `minimumFileModificationDate`, so
`ParserFileReadGate` admitted every remaining session tree every 60s.

### Lane 1 — Idle usage parser caches

Cursor Agent, Cline-family (`ClineFormatParser` for Cline / Kilo / Roo),
Copilot CLI, Antigravity, and Goose now keep a mtime+size disk cache of
**token totals only** (never conversation bodies). Usage-only ticks
skip `fullText` / titles / key-files / tool-names on a miss; character
counts for token estimates still run.

Signatures fail closed:

- Cursor Agent includes nested `summary.json` so a sidecar model/title
  change busts the hit.
- Copilot includes process-log fallback integers so a later
  `CompactionProcessor` parse cannot reuse a zeroed JSONL row.
- Antigravity includes the `settings.json` fallback model string so a
  selector change cannot reuse a cached row that still carried the
  previous model.
- Goose caches both legacy JSONL sessions and `sessions.db` as a
  session bundle (one SQLite file yields many rows).

Cache keys for files that still exist stay even when a watermark or
tracker skips the content read, so an indexing pass cannot evict a warm
usage cache.

### Lane 2 — Quota ISO-8601

Spend / reset parsers that allocated a fractional+basic
`ISO8601DateFormatter` pair per payload now use
`ThreadSafeISO8601DateFormatter.parse` (xAI spend points, Kimi, Warp
GraphQL `nextRefreshTime`, Ollama Cloud HTML). Parsers that used a
default `ISO8601DateFormatter()` now use `parseBasic` (Copilot
`quotaResetDate`, Cursor `billingCycleEnd`, Factory dashboard
`endDate`) so `resetsAt` acceptance does not widen to fractional
strings. Codex `last_refresh` stays on its throwing Codable path.

### Named leftovers

- `fetchDailySummaries` still `GROUP BY DATE(startTime)` (start-day
  membership, not the intersection predicate). Do not fold it into the
  overlapping-day scan without a dedicated equality test.
- `QuotaRefreshActor.fetchAllSnapshots` still runs provider, account,
  and switcher phases sequentially (4-wide inside each phase). Overlapping
  the phases would race the Codex rollout cache (whole-cache last-write-wins).
- Usage parse still must not share indexing `idx2:` discovery tokens /
  `minimumFileModificationDate` with conversation indexing.
- `ChartsSnapshot.build` still needs per-session rows; a SQL rewrite of
  heatmap / outliers / entropy is a different coherent unit.
- Warp **usage** parsing still reads a changed `warp_network*.log` in
  full because every Body object can contribute a usage row.
- Windsurf / Hermes / Forge / Augment / Muse / Prime / Kimi usage
  parsers still reread admitted session files on every usage tick.
  Cache them the same way only with a bit-identical equality test per
  provider.

Validation:
- `OpenBurnBarCoreTests/IdleUsageParserCacheTests`
- `OpenBurnBarCoreTests/CopilotParserTests`
- `OpenBurnBarCoreTests/LiftedParserBoundaryTests`
- `OpenBurnBarCoreTests/ParserParseOptionsTests` (Antigravity / Goose gates)
- `OpenBurnBarCoreTests/GeminiCLIParserCacheTests`
- plus the §22 Warp / Gemini / Grok suites

---

## §24 — Remaining hot paths (August 2026, round 6)

Round 5 cached Cursor Agent / Cline / Copilot / Antigravity / Goose.
Every other Core usage parser still reread admitted session files on
the 60s tick because usage parse does not share indexing watermarks.

### Lane 1 — Remaining idle usage parser caches

Warp, Prime, Muse, Kimi, Windsurf, Hermes, Forge, Augment, Aider,
Cursor SQLite, OpenCode, Pi, OMP, OpenClaw, Ollama, Junie, and
ModelFilter (zai / minimax / the Mac ollama Factory filter) now keep a
mtime+size disk cache of **token totals only** (never conversation
bodies). Session ids are stored in the bundle so Prime envelope ids
survive a filename mismatch.

Signatures fail closed:

- Warp caches per `warp_network*.log` and re-applies global Body
  dedup on a hit. A changed log still reads in full because every Body
  object can contribute a usage row.
- Kimi signs the session directory (`context.jsonl` + optional
  `wire.jsonl`). CJK character fallback still runs on a miss when wire
  has no buckets. Cache-only nil from `parseWireFile` is unchanged.
- Windsurf signs the protobuf plus the global `state.vscdb` (and WAL)
  so a model/workspace rewrite cannot reuse a cached row. In-memory
  `state.vscdb` lookups are keyed on that same signature.
- Hermes signs `state.db` + WAL, the gateway index **and** referenced
  transcripts, CLI `session_*.json`, and leftover jsonl. Hits still
  honor `seenSessionIds` / `profile::sessionId`.
- Forge override reads only `{override}/.forge.db` and jsonl under
  that directory; production home-wide `*/.forge.db` crawl is unchanged
  when override is nil. SQLite usage-only misses skip conversation
  assembly.
- Aider signs `analytics.jsonl` + `.json` as one combined stream.
- Cursor / OpenCode SQLite sign the db + WAL. OpenCode usage-only
  skips the `part` table when every session already has explicit token
  buckets (heuristic totals still need `part` text).
- ModelFilter signs jsonl + settings/metadata sidecars and caches an
  **empty** bundle for non-matching Factory sessions so a zai tick does
  not rescan gpt-4o jsonl.

Cache keys for files that still exist stay even when a watermark or
tracker skips the content read. Goose still signs `sessions.db` only
(do not bump its schema to WAL without a dedicated equality test).

### Lane 2 — Quota ISO-8601 format leftovers

xAI spend-point writes, Claude OAuth disk cache read/write, Claude
auto-install attempt markers, and Claude `firstDate` now go through
`formatBasic` / `parseBasic` / `parse` instead of allocating a
default `ISO8601DateFormatter()`. Codex `last_refresh` stays on its
throwing Codable path.

### Named leftovers

- `fetchDailySummaries` still `GROUP BY DATE(startTime)` (start-day
  membership, not the intersection predicate). Do not fold it into the
  overlapping-day scan without a dedicated equality test.
- `QuotaRefreshActor.fetchAllSnapshots` still runs provider, account,
  and switcher phases sequentially (4-wide inside each phase). Overlapping
  the phases would race the Codex rollout cache (whole-cache last-write-wins).
- Usage parse still must not share indexing `idx2:` discovery tokens /
  `minimumFileModificationDate` with conversation indexing.
- `ChartsSnapshot.build` still needs per-session rows; a SQL rewrite of
  heatmap / outliers / entropy is a different coherent unit.
- Kilo Code's `KiloCodeQuotaAdapter` still `Data(contentsOf:)` task JSON
  arrays, but it is not on the quota refresh path.
- Warp **usage** parsing still reads a changed `warp_network*.log` in
  full because every Body object can contribute a usage row.
- AgentLens Mac shadows (Copilot, Aider, Cursor, OpenCode, Pi, OpenClaw,
  Junie) still run on Mac idle ticks. They are **not** bit-identical to
  the Core lifts (Copilot shutdown double-count, Junie `state.json`,
  OpenClaw nested wrappers). Do not alias `ParserRegistry` to Core
  without per-provider golden tests. Prefer a later Mac-semantics cache
  over a second copy of Core totals.
- Windsurf / Hermes / Forge **discovery** of home-wide session trees
  still stats every candidate even when the content read is a cache hit.
- OpenCode usage-only still reads `part` when any session has zero
  explicit token buckets (needed for heuristic totals).

Validation:
- `OpenBurnBarCoreTests/IdleUsageParserCacheTests` (including Warp /
  Prime / Muse / Kimi / Windsurf / Hermes / Forge / Augment / Aider /
  Cursor SQLite / OpenCode / Pi / OMP / OpenClaw / Ollama / Junie /
  ModelFilter, plus WAL-vs-shm signature)
- `OpenBurnBarCoreTests/ThreadSafeISO8601DateFormatterStaticParseTests`
  (`formatBasic` matches `ISO8601DateFormatter().string(from:)`)
- plus the §23 idle-cache / quota suites

## §25 — Remaining hot paths (August 2026, round 7)

Round 6 cached remaining Core parsers. Five leftovers were still on
the table: Mac AgentLens shadows, `fetchDailySummaries` start-day
membership, sequential quota phases racing the Codex rollout cache,
Warp usage full-reads on append, and Windsurf / Hermes / Forge
discovery stats on cache hits.

### Lane 1 — Mac-semantics idle caches

Mac Copilot, Aider, Cursor, OpenCode, Pi, OpenClaw, and Junie keep a
mtime+size disk cache of **token totals only** around the existing
AgentLens parse math, written to dedicated `mac_*_parser_cache.json`
files. ParserRegistry is not aliased to Core: Copilot still
double-counts `assistant.usage` + `session.shutdown`, Junie still
prefers `state.json`, OpenClaw still flattens nested wrappers. Aider
signs each analytics file separately. Copilot's process-log fallback
integers participate in the signature. Sharing Core cache files would
let an isomorphic signature decode Mac totals as a Core hit.

### Lane 2 — Daily summaries use intersection membership

`fetchDailySummaries` attributes each row to every overlapped local
calendar day (same predicate as last-7-day SQL). A spanning
yesterday→today session counts on both days; a start-today session
counts today only. `DashboardUsageViewModel` in-memory rebuild uses
the same helper. Equality test: folded scan vs per-day intersection
`GROUP BY`.

### Lane 3 — Overlapping quota phases

`CodexRolloutScanner` prunes only files under the directories it
scanned. `CodexRolloutScanCache.mergingScan` overlays those roots on
the live box and keeps other trees (default `~/.codex` vs switcher
`CODEX_HOME`). `QuotaRefreshActor.fetchAllSnapshots` then `async let`s
provider, account, and switcher phases.

### Lane 4 — Warp append resume

Changed `warp_network*.log` files resume from the last complete Body
when the 4096-byte head digest matches. `byteOffset` is the UTF-8
offset after that Body, so a partial Body at EOF is reread next tick.
Head-digest mismatch (rewrite / rotation) fails closed to a full read.

### Lane 5 — Discovery stats

Windsurf and Hermes listing prefetches size/mtime/creation and builds
`FileSignature` from those values (no second `FileSignature(for:)`
stat). Hermes gateway signatures use that listing for `sessions.json`
plus every sibling `.jsonl` — they do not `Data(contentsOf:)` the
index or stat referenced transcripts to decide a cache hit. Forge
still readdirs home every tick (creating `~/foo/.forge.db` does not
change `~` mtime) but reuses per-child directory mtime to skip
`.forge.db` `fileExists` probes. Override `{override}/.forge.db` stays
scoped.

### Named leftovers

- Usage parse still must not share indexing `idx2:` discovery tokens /
  `minimumFileModificationDate` with conversation indexing.
- `ChartsSnapshot.build` still needs per-session rows; a SQL rewrite of
  heatmap / outliers / entropy is a different coherent unit.
- Kilo Code's `KiloCodeQuotaAdapter` still `Data(contentsOf:)` task JSON
  arrays, but it is not on the quota refresh path.
- OpenCode usage-only still reads `part` when any session has zero
  explicit token buckets (needed for heuristic totals).
- `fetchDistinctUsageDayCount` still `COUNT(DISTINCT DATE(startTime))`
  (start-day). Daily summaries and last-7-day series are intersection.

Validation:
- `OpenBurnBarCoreTests/CodexRolloutScannerTests` (scoped prune,
  merge-on-write, locked apply)
- `OpenBurnBarCoreTests/IdleUsageParserCacheTests` (Warp append resume,
  rewrite fail-closed, Forge home-child probe skip, Mac vs Core cache
  URL split)
- `AgentLensTests/Active/DailySummaryIntersectionTests` (Swift vs
  per-day SQL equality, spanning session)
- `AgentLensTests/Active/MacIdleUsageParserCacheTests` (Copilot / Aider /
  Cursor / OpenCode / Pi / OpenClaw usage-only second pass)

## §26 — Remaining hot paths (August 2026, round 8)

Round 7 closed Mac-semantics caches, daily-summary intersection, overlapping
quota phases, Warp append resume, and discovery stats. Four leftovers were
still on the table: distinct-day count was start-day SQL, OpenCode usage-only
read every `part` row when any session lacked buckets, Kilo Code quota
re-parsed every `ui_messages.json`, and Charts heatmap / outliers / entropy
still needed a TokenUsage materialize.

### Lane 1 — Distinct usage days use intersection membership

`fetchDistinctUsageDayCount` counts unique local calendar days that at least
one session overlaps (same `UsageDayIntersection` fold as daily summaries).
The dashboard snapshot reuses `dailySummaries.count` so the all-time scan
is not repeated. A spanning yesterday→today session is two days; a same-day
session is one. Start-day `COUNT(DISTINCT DATE(startTime))` is gone.

### Lane 2 — OpenCode usage-only `part` scope

Core and Mac OpenCode parsers skip the `part` table on usage-only when every
session has explicit token buckets. If some sessions are zero-bucket, they
`SELECT * FROM part WHERE messageID IN (…)` for those message ids only
(chunked). Conversation-body passes still read every text/reasoning part so
transcripts stay complete. Heuristic totals for zero-bucket sessions are
unchanged.

### Lane 3 — Kilo Code quota task cache

`KiloCodeQuotaAdapter` resumes unchanged `ui_messages.json` files from a
mtime+size disk cache of **quota totals only** (tasks / tokens / cost).
Conversation bodies are not stored. Kilo is not a `quotaSignalProviders`
member, so it stays off `ProviderQuotaAdapterRegistry.standard`.

### Lane 4 — Charts heatmap / outliers / entropy SQL twin

`ChartSessionAnalytics` is the shared fold. `UsageStore.fetchChartSessionAnalytics`
loads a narrow `startTime, cost, sessionId, projectName, model, provider`
projection with the same intersection window as `fetchUsage(in:)`, then
clamps `startTime` into the resolved chart range (not exploded onto every
overlapped day). Equality tests match `ChartsSnapshot.build` on heatmap,
top-5 outliers, and project entropy. Burn / cache / provenance / histogram
still use the covering TokenUsage scan; all-time covering rows remain for
those cards.

### Named leftovers

- Usage parse still must not share indexing `idx2:` discovery tokens /
  `minimumFileModificationDate` with conversation indexing.

Validation:
- `AgentLensTests/Active/DailySummaryIntersectionTests` (distinct-day count
  vs per-day intersection summaries, spanning session)
- `OpenBurnBarCoreTests/IdleUsageParserCacheTests` (OpenCode usage-only
  skips `part` when every session has buckets; mixed explicit+heuristic
  reads only heuristic message ids)
- `AgentLensTests/Active/MacIdleUsageParserCacheTests` (Mac OpenCode `part`
  scope)
- `OpenBurnBarCoreTests/KiloCodeQuotaCacheTests` (second fetch cache hit,
  changed task reread, bodies absent from cache)
- `AgentLensTests/Active/ChartSessionAnalyticsSQLTests` (SQL vs
  `ChartsSnapshot.build`, crossing-range clamp)

## §27 — Charts covering scan uses fact rows (August 2026, round 9)

Round 8 left burn / cache / provenance / histogram on the covering
`TokenUsage` scan. `ChartsDataService.refresh` still `fetchAllUsage()`
for all-time even after the heatmap SQL twin. This round wires a
`ChartFactRow` projection so production Charts never decodes ledger
identity for those cards.

### Lane 1 — Chart fact-row covering scan

`ChartFactRow` is the columns `ChartsSnapshot.build` actually reads:
`startTime`, `endTime`, `cost`, `sessionId`, `projectName`, `model`,
`provider`, `billingKind`, `usageSource`, token buckets, `totalTokens`
(via `TokenUsage.billedTotalTokens`), `provenanceConfidence`,
`isRemote`. `UsageStore.fetchChartFactRows` uses the same intersection
predicate as `fetchUsage(in:)` and `ORDER BY startTime DESC`. Bounded
ranges still cover the last 31 days in one scan; all-time covers the
table without `SELECT *`. `ChartsSnapshot.build([TokenUsage])` stays
the oracle (maps to fact rows). Heatmap attribution still clamps
`startTime` into the resolved range — not exploded onto every
overlapped day. Stamped `billingKind` is preserved (a Claude Code
`.api` row does not reclassify to subscription).

### Named leftovers

- Usage parse still must not share indexing `idx2:` discovery tokens /
  `minimumFileModificationDate` with conversation indexing.
  **Invariant, not remaining work.**

OpenCode JSON-only `part` schemas still full-scan `part` when any
heuristic session exists (IN-list needs a messageID column). Forge
still `contentsOfDirectory` on home every tick (creating
`~/foo/.forge.db` does not change `~` mtime) but already skips
`.forge.db` `fileExists` via per-child directory mtime.

Validation:
- `AgentLensTests/Active/ChartFactRowSQLTests` (fact rows vs
  `fetchAllUsage` / `ChartsSnapshot.build`, 31-day covering split,
  crossing-range clamp, stamped billing kind + Spend Lens conservation)
- `AgentLensTests/Active/ChartSessionAnalyticsSQLTests`
- `AgentLensTests/Active/ChartsSnapshotBuilderTests`
- `AgentLensTests/Active/SpendLensConservationTests`




