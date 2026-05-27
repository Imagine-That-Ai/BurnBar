# macOS performance — frame budget, dashboard caching, version tickers

This document is the source of truth for the May 2026 macOS performance
sweep. Every optimization here was applied without altering visual
behaviour. If you're touching one of these surfaces, please read the
relevant section first so the work doesn't regress.

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

## 6. Validation

The work is covered by the following test suites:

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
