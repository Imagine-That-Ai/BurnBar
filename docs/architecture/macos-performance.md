# macOS performance — frame budget, dashboard caching, version tickers

This document is the source of truth for the May 2026 macOS performance
sweep (sections 1–6) and the June 2026 invisible-wins sweep (sections
7–13, applied 2026-06-09). Every optimization here was applied without
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
hundreds of `CGContextFillRect`-like ops per frame. The new path
accumulates particles into `[UInt32: (color: RGBA, path: Path)]` keyed
on `RGBA.bucketKey` (an 8-bit-per-channel quantization of the colour),
then issues exactly one `ctx.fill` per bucket. Sparkles render in a
deferred pass so the draw order is preserved.

Net effect: a frame that used to be 600 fills is now ~12 fills, with no
visible difference to the eye.

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
`usagesVersion: Int` that is bumped on every mutation of `usages`
(currently `replaceUsages` and `replaceUsageSnapshot`). Every dashboard
view that previously observed `dataStore.lastRefresh` (a `Date`) has been
migrated to observe `dataStore.usagesVersion`.

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
