import AppKit

// MARK: - PetSystemObservers

/// The hardening layer (PLAN C9): observes the system events that should pause,
/// re-clamp, or re-assert the floating pet, and forwards them to
/// ``PetCompanionController``. Centralising them here keeps the controller free
/// of `NotificationCenter` plumbing and makes the energy/placement policy a
/// single readable surface.
///
/// Policy (PLAN §4 "cost nothing when nobody's looking" + §5 hardening):
/// - **Display sleep / screen lock** → `setPaused(true)`; **wake / unlock** →
///   `setPaused(false)`. Drives the renderer to ~0% CPU while no one can see it.
/// - **`didChangeScreenParameters`** (display added/removed/resized) → re-clamp
///   the panel onto a valid visible frame so the pet never strands off-screen.
/// - **`activeSpaceDidChange`** → re-assert the window level so the pet keeps
///   floating above the newly-active Space.
/// - **Reduced-motion change** → propagate to the renderer.
///
/// `@MainActor`: it touches AppKit panel state via the controller. Owned by
/// ``PetCompanionRuntime``; `start()`/`stop()` are idempotent.
@MainActor
final class PetSystemObservers {
    private weak var controller: PetCompanionController?
    private var tokens: [NSObjectProtocol] = []
    private var isObserving = false

    init() {}

    // MARK: Lifecycle

    /// Begin observing, forwarding events to `controller`. Idempotent.
    func start(controller: PetCompanionController) {
        guard !isObserving else { return }
        self.controller = controller
        isObserving = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let appCenter = NotificationCenter.default

        // Energy gate: pause while the screen is asleep or locked.
        observe(workspaceCenter, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.controller?.setSystemIdle(true)
            self?.controller?.setPaused(true)
        }
        observe(workspaceCenter, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.controller?.setSystemIdle(false)
            self?.controller?.setPaused(false)
        }
        observe(workspaceCenter, NSWorkspace.willSleepNotification) { [weak self] in
            self?.controller?.setSystemIdle(true)
            self?.controller?.setPaused(true)
        }
        observe(workspaceCenter, NSWorkspace.didWakeNotification) { [weak self] in
            self?.controller?.setSystemIdle(false)
            self?.controller?.setPaused(false)
        }
        // Screen lock/unlock arrives via the distributed center.
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.controller?.setSystemIdle(true)
            self?.controller?.setPaused(true)
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.controller?.setSystemIdle(false)
            self?.controller?.setPaused(false)
        }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { [weak self] in
            self?.controller?.setSystemIdle(true)
        }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { [weak self] in
            self?.controller?.setSystemIdle(false)
        }

        // App focus is a sense, not an energy gate: blur can doze the pet while
        // still allowing the panel to remain visible.
        observe(appCenter, NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.controller?.setAppFocused(true)
        }
        observe(appCenter, NSApplication.didResignActiveNotification) { [weak self] in
            self?.controller?.setAppFocused(false)
        }

        // Placement hardening: re-clamp on display reconfigure, re-assert level on
        // Space change.
        observe(appCenter, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.controller?.handleScreenParametersChanged()
        }
        observe(workspaceCenter, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.controller?.handleActiveSpaceChanged()
        }

        // Reduced motion (accessibility) → propagate immediately + prime current.
        observe(workspaceCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in
            self?.propagateReducedMotion()
        }
        propagateReducedMotion()
    }

    /// Tear down all observers. Idempotent.
    func stop() {
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            DistributedNotificationCenter.default().removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
        isObserving = false
    }

    // MARK: Private

    private func propagateReducedMotion() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        controller?.setReducedMotion(reduced)
    }

    /// Register one observer and retain its token. The handler hops to the main
    /// actor since distributed/workspace notifications may arrive off-main.
    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        handler: @escaping @MainActor () -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        tokens.append(token)
    }

    private func observe(
        _ center: DistributedNotificationCenter,
        _ name: Notification.Name,
        handler: @escaping @MainActor () -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        tokens.append(token)
    }
}
