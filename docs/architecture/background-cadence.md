# `BackgroundCadenceCoordinator`

> Canonical contract for all timer-driven background work in OpenBurnBar.
>
> Source: `AgentLens/Services/Performance/BackgroundCadenceCoordinator.swift`
> Tests: `AgentLensTests/Active/BackgroundCadenceCoordinatorTests.swift`

## Why

Before this coordinator existed, every long-running background task in the
app spun its own `Task { while !Task.isCancelled { sleep N; do work } }`
loop. By the time the audit ran in May 2026 there were 14 such loops
running concurrently, totaling over 35 wake-ups per second on an idle
machine. None of them throttled when the app was in the background, none
of them paused when the laptop slept, and several were running Firestore
writes against the lid-closed laptop.

`BackgroundCadenceCoordinator` is the single home for this work. Every
caller registers a `Cadence` descriptor and gets all of the following
behaviour for free:

1. Active vs background intervals (the coordinator listens to
   `NSApplication.didBecomeActive` / `didResignActive`).
2. Display-sleep pause (via `NSWorkspace.willSleepNotification` /
   `didWakeNotification` + the screensaver variants).
3. Caller-supplied gate (`isEnabled`) — the cadence is paused whenever
   the gate returns false. Re-evaluated on every fire.
4. Observer-coalescing — when a higher-fidelity observer (e.g. an iroh
   heartbeat) is delivering updates for the same data, the poll
   stretches to `observerActiveInterval` or pauses entirely. When the
   observer goes silent the poll snaps back to `activeInterval` on the
   next fire.

## Registration

```swift
BackgroundCadenceCoordinator.shared.register(
    BackgroundCadenceCoordinator.Cadence(
        id: "my-service",
        activeInterval: 5,           // 5s while foreground+awake
        backgroundInterval: 30,      // 30s when the app is in the background
        sleepInterval: nil,          // nil = paused while the display sleeps
        observerActiveInterval: nil, // nil = paused when an observer is feeding fresh data
        isEnabled: { mySettingIsOn },
        fireImmediately: false,      // run once on register?
        cancellableInFlight: false,  // drop new fires if previous still in flight
        work: { [weak self] in
            await self?.doWork()
        }
    )
)
```

When you need to wire the active interval to a live setting that the user
can change at runtime, use the provider initializer:

```swift
BackgroundCadenceCoordinator.shared.register(
    BackgroundCadenceCoordinator.Cadence(
        id: "user-tunable",
        activeIntervalProvider: { settingsManager.refreshInterval },
        backgroundIntervalProvider: nil,    // defaults to 5x active
        sleepIntervalProvider: { nil },     // paused on sleep
        isEnabled: { true },
        work: { ... }
    )
)
```

Re-registering with the same id replaces the previous cadence and cancels
the old loop.

## Cleanup

`unregister(id:)` cancels the underlying `Task`. Always call it from
`stop()` / `deinit` paths of the service that registered the cadence.

## Observer coalescing

When you have both a push observer (e.g. an iroh control stream) and a
fallback poll for the same data, the coordinator lets the push observer
take priority:

```swift
// Observer fires every time fresh data arrives.
func ingestHeartbeat(_ frame: SomeFrame) {
    BackgroundCadenceCoordinator.shared.observerDidEmit(id: "my-poll")
    apply(frame)
}

// When the observer disconnects, snap the poll back to the active
// interval so we re-converge on Firestore as the truth source.
func handleStreamClosed() {
    BackgroundCadenceCoordinator.shared.observerDidGoSilent(id: "my-poll")
}
```

While the observer is active the cadence uses `observerActiveInterval`;
if that is `nil` the poll pauses entirely.

## Force a fire

`fireNow(id:)` immediately schedules one invocation of the cadence's
work closure, bypassing the sleep cycle but honoring `isEnabled` and the
in-flight guard. Use this from "manual refresh" buttons.

## Inspection

`state(forId:)` and `allStates()` return `CadenceState` records suitable
for debug surfaces and tests. The state struct contains the currently
applied interval (or `.infinity` for paused), in-flight status, and the
last-fire timestamp.

## Testing

The coordinator's `handleLifecycleSignal(_:)` hook is public so tests can
drive lifecycle transitions deterministically without poking the AppKit
notification center. There is also a `lifecycleSignalForTesting` closure
hook for assertions.

```swift
BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.appBecameActive)
BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayWillSleep)
```

After each test, tear down every cadence the test added:

```swift
override func tearDown() {
    super.tearDown()
    for state in BackgroundCadenceCoordinator.shared.allStates() {
        BackgroundCadenceCoordinator.shared.unregister(id: state.id)
    }
}
```

## Current callers

| Caller | Cadence ID | Active | Background | Sleep | Observer |
|---|---|---|---|---|---|
| `SystemPermissionMonitor` | `system-permission-monitor` | 5s | 30s | paused | – |
| `MercuryPeerSource` | `mercury-peer-source` | 2s | 30s | paused | 30s |
| `SettingsManager` (Remote Config) | `settings-remote-config` | 60s | 300s | paused | – |
| `AgentLensApp.periodicRefreshTask` | `agentlens-periodic-refresh` | live setting | 5× active | paused | – |
| `SmartDisplayActionsListener` | `smart-display-actions-listener` | 3s | 30s | paused | – |
| `SmartHubBridgeController` (settings) | `smarthub-bridge-settings` | 2s | 30s | paused | – |
| `SmartHubBridgeController` (snapshot pump) | `smarthub-bridge-snapshot-pump` | 5s | 30s | paused | – |
| `SmartHubBridgeController` (auto-refresh) | `smarthub-bridge-auto-refresh` | 60s | 300s | paused | – |
| `SmartHubBridgeController` (cast watchdog) | `smarthub-bridge-cast-watchdog` | 30s | 150s | paused | – |
| `HermesRelayHostService` heartbeat | `hermes-relay-host-heartbeat` | 30s | 300s | paused | – |
| `PiAgentCloudRelayHostService` heartbeat | `pi-agent-relay-host-heartbeat` | 30s | 300s | paused | – |
| `ComputerUseDaemonApprovalPresenter` | `computer-use-daemon-approval-poll` | 750 ms | 5s | paused | – |
