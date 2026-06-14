#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import AppKit
import OpenBurnBarComputerUseCore

/// Independent kill paths — global hotkey, NSWorkspace auth-gate
/// notifications, Remote Config flag flip. All three converge on a
/// single `panicHalt(source:)` callback so the calling
/// `ComputerUseSessionCoordinator` can tear down without caring how the
/// panic was triggered (Decision 7).
@MainActor
public final class ComputerUsePanicHaltCoordinator: NSObject {
    public typealias HaltHandler = @Sendable (ComputerUsePanicSource) -> Void

    public private(set) var isInstalled: Bool = false
    public let halt: HaltHandler

    private let accessibilityTrustProvider: @Sendable () -> Bool
    private var lastAccessibilityTrusted: Bool = false
    private var accessibilityTimer: Timer?

    // nonisolated(unsafe): installed/removed on the main actor; the nonisolated
    // deinit reads them exclusively at dealloc to remove the monitors (NSEvent /
    // NotificationCenter removal is thread-safe).
    private nonisolated(unsafe) var globalMonitor: Any?
    private nonisolated(unsafe) var localMonitor: Any?
    private nonisolated(unsafe) var workspaceObservers: [NSObjectProtocol] = []

    public init(
        accessibilityTrustProvider: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        halt: @escaping HaltHandler
    ) {
        self.accessibilityTrustProvider = accessibilityTrustProvider
        self.halt = halt
        super.init()
    }

    deinit {
        // Monitor/observer removal is thread-safe; inline it so the nonisolated
        // deinit need not hop to the main actor to call `uninstall()`.
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Wire up all three kill paths. Idempotent.
    public func install() {
        guard !isInstalled else { return }
        lastAccessibilityTrusted = accessibilityTrustProvider()
        installHotkey()
        installAuthGateListeners()
        
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollAccessibilityTrustNow()
            }
        }
        
        isInstalled = true
    }

    public func uninstall() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        isInstalled = false
    }

    /// Public Remote-Config bridge: settings layer calls this when
    /// `computer_use_kill_switch` flips to true.
    public func remoteConfigKillSwitchFired() {
        halt(.remoteConfig)
    }

    /// Public Accessibility revocation bridge: the coordinator polls
    /// `AXIsProcessTrusted` every 5 s and on NSWorkspace activate; if
    /// it transitions from true → false mid-session, call this.
    public func accessibilityRevoked() {
        halt(.accessibilityRevoked)
    }

    // MARK: hotkey

    private func installHotkey() {
        // ⌃⌥⌘. — keycode 47 is `.` with command/option/control held.
        let hotkeyMatch: (NSEvent) -> Bool = { event in
            event.keyCode == 47 &&
            event.modifierFlags.contains([.control, .option, .command])
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            if hotkeyMatch(event) {
                self?.halt(.hotkey)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            if hotkeyMatch(event) {
                self?.halt(.hotkey)
                return nil  // consume
            }
            return event
        }
    }

    // MARK: NSWorkspace auth gates

    private func installAuthGateListeners() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        for name in names {
            let observer = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] note in
                // `note` (a non-`Sendable` `Notification`) must not cross the
                // isolation hop, so pull the `Sendable` fields out first.
                let name = note.name
                let activatedBundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier
                // Delivered on `.main` (queue: .main), so assume main-actor isolation.
                MainActor.assumeIsolated {
                    self?.handleWorkspaceNotification(name: name, activatedBundleID: activatedBundleID)
                }
            }
            workspaceObservers.append(observer)
        }
    }

    @discardableResult
    public func pollAccessibilityTrustNow() -> Bool {
        let trusted = accessibilityTrustProvider()
        if lastAccessibilityTrusted && !trusted {
            halt(.accessibilityRevoked)
        }
        lastAccessibilityTrusted = trusted
        return trusted
    }

    private func handleWorkspaceNotification(name: Notification.Name, activatedBundleID: String?) {
        switch name {
        case NSWorkspace.screensDidSleepNotification,
             NSWorkspace.sessionDidResignActiveNotification:
            halt(.macLock)
        case NSWorkspace.didActivateApplicationNotification:
            // Check accessibility trust whenever application activation changes (e.g. settings app).
            pollAccessibilityTrustNow()
            
            // If loginwindow / SecurityAgent activates we treat that
            // as a lock-equivalent. `activatedBundleID` is the bundle id of
            // the `NSRunningApplication` that just became frontmost.
            if let activatedBundleID,
               activatedBundleID == "com.apple.loginwindow" || activatedBundleID == "com.apple.SecurityAgent" {
                halt(.macLock)
            }
        default:
            break
        }
    }
}
#endif
