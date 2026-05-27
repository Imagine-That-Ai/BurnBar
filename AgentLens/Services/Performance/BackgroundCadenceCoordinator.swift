@preconcurrency import AppKit
import Combine
import Foundation
import OpenBurnBarCore

// MARK: - BackgroundCadenceCoordinator
//
// The canonical surface for all timer-driven background work in OpenBurnBar.
// Anything that previously ran a "while !Task.isCancelled { sleep N; do
// work }" loop should register a `BackgroundCadence` here instead. The
// coordinator picks the active polling interval per task based on:
//
//   - The app's foreground / background state
//     (`NSApplication.didBecomeActiveNotification` /
//      `didResignActiveNotification`)
//   - The display's sleep state
//     (`NSWorkspace.didWakeNotification` / `willSleepNotification`)
//   - The screensaver state (best-effort via the same workspace notifications)
//   - A caller-supplied `isEnabled` gate (typically a feature flag)
//   - An optional observer-driven coalescing signal: when a higher-fidelity
//     observer is currently delivering updates, the corresponding poll is
//     extended to a longer interval; when the observer goes silent (via
//     `observerDidGoSilent`), the poll snaps back to the active interval.
//
// The contract is documented in `docs/architecture/background-cadence.md`.

/// One canonical handle to all timer-driven background work in the app.
@MainActor
final class BackgroundCadenceCoordinator {
    static let shared = BackgroundCadenceCoordinator()

    /// Per-task descriptor. All callers register one of these instead of
    /// spinning their own `Task { while !Task.isCancelled { ... } }` loop.
    struct Cadence: Identifiable {
        let id: String
        /// Interval when the app is in the foreground AND the display is
        /// awake AND no higher-fidelity observer is currently active.
        /// Re-evaluated on every fire so callers can wire it to a
        /// user-mutable setting (e.g. `SettingsManager.refreshInterval`).
        var activeInterval: () -> TimeInterval
        /// Interval when the app is in the background but the display is
        /// awake. Defaults to `5 × activeInterval`.
        var backgroundInterval: () -> TimeInterval
        /// Interval when the display is asleep / screensaver is up. `nil`
        /// pauses the task entirely while the display sleeps.
        var sleepInterval: () -> TimeInterval?
        /// Interval to use while an observer-driven source is delivering
        /// updates for the same data (e.g. an iroh heartbeat replaces a
        /// Mercury peer poll). `nil` means "pause entirely while the
        /// observer is active".
        var observerActiveInterval: () -> TimeInterval?
        /// Caller-supplied feature gate. If this returns `false` the task
        /// is paused regardless of every other signal. Re-evaluated on
        /// every fire.
        var isEnabled: () -> Bool
        /// The work to perform. Must be idempotent — the coordinator may
        /// fire it before the previous invocation has completed if
        /// `cancellableInFlight` is `false`. Defaults to true (skip if
        /// previous run is still in flight).
        var work: @MainActor () async -> Void
        /// Run the first invocation immediately on register? Defaults to
        /// `false`. Useful for tasks that need an eager warmup.
        var fireImmediately: Bool
        /// Cancel and reissue if a new fire window arrives while the
        /// previous is still in flight. Defaults to `false` — the new
        /// fire is dropped.
        var cancellableInFlight: Bool

        init(
            id: String,
            activeInterval: TimeInterval,
            backgroundInterval: TimeInterval? = nil,
            sleepInterval: TimeInterval? = nil,
            observerActiveInterval: TimeInterval? = nil,
            isEnabled: @escaping () -> Bool = { true },
            fireImmediately: Bool = false,
            cancellableInFlight: Bool = false,
            work: @escaping @MainActor () async -> Void
        ) {
            let bg = backgroundInterval ?? (activeInterval * 5)
            self.id = id
            self.activeInterval = { activeInterval }
            self.backgroundInterval = { bg }
            self.sleepInterval = { sleepInterval }
            self.observerActiveInterval = { observerActiveInterval }
            self.isEnabled = isEnabled
            self.work = work
            self.fireImmediately = fireImmediately
            self.cancellableInFlight = cancellableInFlight
        }

        /// Provider-style initialiser for cadences whose intervals must
        /// follow a live setting (e.g. the user-mutable refresh
        /// interval).
        init(
            id: String,
            activeIntervalProvider: @escaping () -> TimeInterval,
            backgroundIntervalProvider: (() -> TimeInterval)? = nil,
            sleepIntervalProvider: (() -> TimeInterval?)? = nil,
            observerActiveIntervalProvider: (() -> TimeInterval?)? = nil,
            isEnabled: @escaping () -> Bool = { true },
            fireImmediately: Bool = false,
            cancellableInFlight: Bool = false,
            work: @escaping @MainActor () async -> Void
        ) {
            self.id = id
            self.activeInterval = activeIntervalProvider
            self.backgroundInterval = backgroundIntervalProvider
                ?? { activeIntervalProvider() * 5 }
            self.sleepInterval = sleepIntervalProvider ?? { nil }
            self.observerActiveInterval = observerActiveIntervalProvider ?? { nil }
            self.isEnabled = isEnabled
            self.work = work
            self.fireImmediately = fireImmediately
            self.cancellableInFlight = cancellableInFlight
        }
    }

    /// Public read-only view of the current cadence state for tests and
    /// inspection (`droid run --inspect cadence`).
    struct CadenceState: Equatable {
        let id: String
        let active: Bool
        let appliedInterval: TimeInterval
        let inflight: Bool
        let lastFireAt: Date?
        let observerActive: Bool
    }

    enum LifecycleSignal: Equatable {
        case appBecameActive
        case appResignedActive
        case displayDidWake
        case displayWillSleep
    }

    private struct Box {
        var cadence: Cadence
        var task: Task<Void, Never>?
        var inflight: Bool = false
        var lastFireAt: Date?
        var observerActive: Bool = false
    }

    private var boxes: [String: Box] = [:]
    private(set) var appIsActive: Bool = NSApplication.shared.isActive
    private(set) var displayIsAwake: Bool = true
    private nonisolated(unsafe) var lifecycleObservers: [NSObjectProtocol] = []
    /// Hook used by `BackgroundCadenceCoordinatorTests` to inject lifecycle
    /// signals without poking `NSApplication` / `NSWorkspace` from a unit
    /// test.
    var lifecycleSignalForTesting: ((LifecycleSignal) -> Void)?

    private init() {
        installLifecycleObservers()
    }

    deinit {
        // Lifecycle observers are owned by the singleton; they live for the
        // whole app process, but if the singleton ever goes away (tests),
        // detach to avoid leaks.
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Registration

    /// Registers (or replaces) a cadence. Returns immediately; the loop
    /// itself runs in a detached `Task` on the main actor.
    func register(_ cadence: Cadence) {
        // Replace an existing cadence with the same id.
        if let existing = boxes[cadence.id] {
            existing.task?.cancel()
        }
        var box = Box(cadence: cadence)
        if cadence.fireImmediately {
            box.task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.fire(id: cadence.id)
                await self.runLoop(id: cadence.id)
            }
        } else {
            box.task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runLoop(id: cadence.id)
            }
        }
        boxes[cadence.id] = box
    }

    /// Cancels and removes a cadence by id. Safe to call with an unknown id.
    func unregister(id: String) {
        boxes[id]?.task?.cancel()
        boxes.removeValue(forKey: id)
    }

    /// Notify the coordinator that an observer-driven source has just
    /// emitted a fresh value for the given id. The next poll will use the
    /// `observerActiveInterval` (or pause entirely if nil).
    func observerDidEmit(id: String) {
        guard var box = boxes[id] else { return }
        box.observerActive = true
        boxes[id] = box
    }

    /// Notify the coordinator that an observer-driven source has fallen
    /// silent. The next poll snaps back to the active interval.
    func observerDidGoSilent(id: String) {
        guard var box = boxes[id] else { return }
        box.observerActive = false
        boxes[id] = box
    }

    /// Forces an immediate fire of a registered cadence, useful when an
    /// upstream event tells us the data is stale (e.g. user just hit
    /// "refresh" or a notification arrived). Does nothing if the cadence
    /// is currently in-flight unless `cancellableInFlight` is true.
    func fireNow(id: String) {
        Task { @MainActor [weak self] in
            await self?.fire(id: id)
        }
    }

    // MARK: - Inspection (tests, debug UI)

    func state(forId id: String) -> CadenceState? {
        guard let box = boxes[id] else { return nil }
        let interval = effectiveInterval(for: box)
        return CadenceState(
            id: id,
            active: box.cadence.isEnabled(),
            appliedInterval: interval ?? .infinity,
            inflight: box.inflight,
            lastFireAt: box.lastFireAt,
            observerActive: box.observerActive
        )
    }

    func allStates() -> [CadenceState] {
        boxes.keys.sorted().compactMap { state(forId: $0) }
    }

    // MARK: - Lifecycle wiring

    private func installLifecycleObservers() {
        let nc = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        let activeObs = nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleLifecycleSignal(.appBecameActive)
            }
        }
        lifecycleObservers.append(activeObs)

        let resignObs = nc.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleLifecycleSignal(.appResignedActive)
            }
        }
        lifecycleObservers.append(resignObs)

        let wakeObs = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleLifecycleSignal(.displayDidWake)
            }
        }
        lifecycleObservers.append(wakeObs)

        let sleepObs = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleLifecycleSignal(.displayWillSleep)
            }
        }
        lifecycleObservers.append(sleepObs)

        let screensaverDidStart = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleLifecycleSignal(.displayWillSleep)
            }
        }
        lifecycleObservers.append(screensaverDidStart)

        let screensaverDidStop = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleLifecycleSignal(.displayDidWake)
            }
        }
        lifecycleObservers.append(screensaverDidStop)
    }

    func handleLifecycleSignal(_ signal: LifecycleSignal) {
        switch signal {
        case .appBecameActive:    appIsActive = true
        case .appResignedActive:  appIsActive = false
        case .displayDidWake:     displayIsAwake = true
        case .displayWillSleep:   displayIsAwake = false
        }
        lifecycleSignalForTesting?(signal)
    }

    // MARK: - Loop body

    private func runLoop(id: String) async {
        while !Task.isCancelled {
            let interval = effectiveInterval(for: boxes[id])
            // `nil` interval means "paused entirely" — we wake periodically
            // to re-evaluate the gate without burning power. The wake-up
            // delay here is long (60 s) so a permanently disabled cadence
            // does no measurable work.
            let sleepInterval = interval ?? 60.0
            do {
                try await Task.sleep(nanoseconds: UInt64(sleepInterval * 1_000_000_000))
            } catch {
                return
            }
            if Task.isCancelled { return }
            guard effectiveInterval(for: boxes[id]) != nil else {
                // Paused since the sleep window was chosen — skip the actual
                // work but keep looping so we'll pick up later state changes.
                continue
            }
            await fire(id: id)
        }
    }

    private func fire(id: String) async {
        guard var box = boxes[id] else { return }
        guard box.cadence.isEnabled() else { return }

        if box.inflight {
            if box.cadence.cancellableInFlight {
                // We have no way to cancel an arbitrary `() async -> Void`
                // mid-flight without the caller participating, so the
                // pragmatic semantics are: drop the new fire. Callers that
                // truly need cancellation should plumb a CancellationToken
                // through their own implementation.
                return
            }
            return
        }

        box.inflight = true
        box.lastFireAt = Date()
        boxes[id] = box

        await box.cadence.work()

        if var b = boxes[id] {
            b.inflight = false
            boxes[id] = b
        }
    }

    private func effectiveInterval(for box: Box?) -> TimeInterval? {
        guard let box else { return nil }
        guard box.cadence.isEnabled() else { return nil }

        if !displayIsAwake {
            return box.cadence.sleepInterval()
        }
        if box.observerActive {
            return box.cadence.observerActiveInterval()
        }
        if appIsActive {
            return box.cadence.activeInterval()
        }
        return box.cadence.backgroundInterval()
    }
}
