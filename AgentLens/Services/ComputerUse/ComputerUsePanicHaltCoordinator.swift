#if canImport(AppKit)
import Foundation
import AppKit
import OpenBurnBarComputerUseCore

/// Independent kill paths — global hotkey, NSWorkspace auth-gate
/// notifications, Remote Config flag flip. All three converge on a
/// single `panicHalt(source:)` callback so the calling
/// `ComputerUseSessionCoordinator` can tear down without caring how the
/// panic was triggered (Decision 7).
public final class ComputerUsePanicHaltCoordinator: NSObject, @unchecked Sendable {
    public typealias HaltHandler = @Sendable (ComputerUsePanicSource) -> Void

    public private(set) var isInstalled: Bool = false
    public let halt: HaltHandler

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []

    public init(halt: @escaping HaltHandler) {
        self.halt = halt
        super.init()
    }

    deinit { uninstall() }

    /// Wire up all three kill paths. Idempotent.
    public func install() {
        guard !isInstalled else { return }
        installHotkey()
        installAuthGateListeners()
        isInstalled = true
    }

    public func uninstall() {
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
                self?.handleWorkspaceNotification(note)
            }
            workspaceObservers.append(observer)
        }
    }

    private func handleWorkspaceNotification(_ note: Notification) {
        switch note.name {
        case NSWorkspace.screensDidSleepNotification,
             NSWorkspace.sessionDidResignActiveNotification:
            halt(.macLock)
        case NSWorkspace.didActivateApplicationNotification:
            // If loginwindow / SecurityAgent activates we treat that
            // as a lock-equivalent. The user-info dictionary carries
            // the NSRunningApplication that just became frontmost.
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let bundle = app.bundleIdentifier,
               bundle == "com.apple.loginwindow" || bundle == "com.apple.SecurityAgent" {
                halt(.macLock)
            }
        default:
            break
        }
    }
}
#endif
