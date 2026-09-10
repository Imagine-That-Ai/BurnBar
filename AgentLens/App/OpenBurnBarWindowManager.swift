import AppKit
import OpenBurnBarCore
import SwiftUI

// Extracted verbatim from AgentLensApp.swift (audit wave 4, item 14).
// Owns every AppKit window the menu-bar app opens: dashboard, settings,
// onboarding + Hermes/switcher wizards, startup recovery, and the chat
// pop-out (with frame persistence).

// MARK: - Window Manager

@MainActor
final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    private enum DashboardWindowMetrics {
        static let preferredWidth: CGFloat = 1360
        static let preferredHeight: CGFloat = 820
        static let minimumContentWidth: CGFloat = 1040
        static let minimumContentHeight: CGFloat = 650
        static let screenInset: CGFloat = 80
    }

    private var dashboardWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var bugReportWindow: NSWindow?
    private var bugReportWindowLifecycleHandler: DocumentWindowLifecycleDelegate?
    private var helpSupportWindow: NSWindow?
    private var helpSupportWindowLifecycleHandler: DocumentWindowLifecycleDelegate?
    private var onboardingWindow: NSWindow?
    private var onboardingWindowLifecycleHandler: DocumentWindowLifecycleDelegate?
    private var hermesSetupWindowLifecycleHandler: DocumentWindowLifecycleDelegate?
    private var switcherOnboardingWindowLifecycleHandler: DocumentWindowLifecycleDelegate?
    private var startupRecoveryWindowLifecycleHandler: DocumentWindowLifecycleDelegate?
    private var hermesSetupWindow: NSWindow?
    private var switcherOnboardingWindow: NSWindow?
    private var startupRecoveryWindow: NSWindow?
    private var receiptsWindow: NSWindow?
    private var receiptsWindowLifecycleHandler: DocumentWindowLifecycleDelegate?
    private var dashboardWindowLifecycleHandler: DashboardWindowLifecycleDelegate?
    private var settingsWindowLifecycleHandler: DocumentWindowLifecycleDelegate?

    /// `LSUIElement` apps launch as `.accessory`. Document windows (dashboard,
    /// settings, wizards) must temporarily promote to `.regular` so clicking
    /// another app resigns activation and sends BurnBar behind like a normal
    /// Mac app. Without this, `activate(ignoringOtherApps:)` leaves the
    /// accessory process sticky-frontmost.
    private func promoteToRegularActivation() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        if !OpenBurnBarRuntime.isRunningTests {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    /// Return to menu-bar-only accessory mode once every document window is gone.
    fileprivate func demoteToAccessoryIfIdle() {
        let documentWindows: [NSWindow?] = [
            dashboardWindow,
            settingsWindow,
            bugReportWindow,
            helpSupportWindow,
            onboardingWindow,
            hermesSetupWindow,
            switcherOnboardingWindow,
            startupRecoveryWindow,
            receiptsWindow,
            WindowManager.chatPopOutWindow
        ]
        let hasVisibleDocument = documentWindows.contains { window in
            guard let window else { return false }
            return window.isVisible && window.isMiniaturized == false
        }
        guard hasVisibleDocument == false else { return }
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func openDashboard(
        dataStore: DataStore,
        aggregator: UsageAggregator?,
        accountManager: AccountManager,
        cloudSyncService: CloudSyncService?,
        iCloudSessionMirrorService: ICloudSessionMirrorService?,
        chatController: ChatSessionController,
        operatingLayer: OpenBurnBarOperatingLayer,
        navigationCoordinator: NavigationCoordinator,
        settingsManager: SettingsManager,
        runtimeContext: OpenBurnBarRuntimeContext? = nil
    ) {
        promoteToRegularActivation()
        Task { @MainActor in
            await dataStore.loadUsagePresentationIfNeeded()
        }

        if let window = dashboardWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = DashboardView(
            dataStore: dataStore,
            aggregator: aggregator,
            accountManager: accountManager,
            cloudSyncService: cloudSyncService,
            iCloudSessionMirrorService: iCloudSessionMirrorService,
            chatController: chatController,
            operatingLayer: operatingLayer,
            settingsManager: settingsManager,
            runtimeContext: runtimeContext
        )
        .frame(
            minWidth: DashboardWindowMetrics.minimumContentWidth,
            minHeight: DashboardWindowMetrics.minimumContentHeight
        )
        .environment(settingsManager)
        .environment(accountManager)
        .environment(navigationCoordinator)

        let visibleFrame = NSScreen.main?.visibleFrame
        let initialWidth = min(
            DashboardWindowMetrics.preferredWidth,
            max(
                DashboardWindowMetrics.minimumContentWidth,
                (visibleFrame?.width ?? DashboardWindowMetrics.preferredWidth) - DashboardWindowMetrics.screenInset
            )
        )
        let initialHeight = min(
            DashboardWindowMetrics.preferredHeight,
            max(
                DashboardWindowMetrics.minimumContentHeight,
                (visibleFrame?.height ?? DashboardWindowMetrics.preferredHeight) - DashboardWindowMetrics.screenInset
            )
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = OpenBurnBarCore.OpenBurnBarIdentity.productName
        // Keep a real title for the Window menu / accessibility; hide the redundant title text
        // in the title bar now that the in-toolbar brand mark carries the product name.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(DesignSystem.Colors.background)
        window.contentMinSize = NSSize(
            width: DashboardWindowMetrics.minimumContentWidth,
            height: DashboardWindowMetrics.minimumContentHeight
        )
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        // Restore the user's last frame; center() above is only the
        // first-launch fallback before a saved frame exists.
        window.setFrameAutosaveName("openburnbar.dashboard")
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        let lifecycleDelegate = DashboardWindowLifecycleDelegate { [weak self] in
            self?.demoteToAccessoryIfIdle()
        }
        window.delegate = lifecycleDelegate

        dashboardWindow = window
        dashboardWindowLifecycleHandler = lifecycleDelegate
    }

    func openSettings(
        settingsManager: SettingsManager,
        accountManager: AccountManager,
        cloudSyncService: CloudSyncService?,
        iCloudSessionMirrorService: ICloudSessionMirrorService?,
        dataStore: DataStore,
        runtimeContext: OpenBurnBarRuntimeContext? = nil
    ) {
        promoteToRegularActivation()

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = SettingsView(
            settingsManager: settingsManager,
            accountManager: accountManager,
            cloudSyncService: cloudSyncService,
            iCloudSessionMirrorService: iCloudSessionMirrorService,
            dataStore: dataStore,
            runtimeContext: runtimeContext
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        let initialWidth: CGFloat = 920
        let initialHeight: CGFloat = 660

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentMinSize = NSSize(width: 780, height: 560)
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.setFrameAutosaveName("openburnbar.settings")
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        let settingsLifecycle = DocumentWindowLifecycleDelegate { [weak self] in
            self?.settingsWindow = nil
            self?.settingsWindowLifecycleHandler = nil
            self?.demoteToAccessoryIfIdle()
        }
        window.delegate = settingsLifecycle

        settingsWindow = window
        settingsWindowLifecycleHandler = settingsLifecycle
    }

    func openBugReport() {
        promoteToRegularActivation()

        if let window = bugReportWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = BugReportSheetView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Report an Issue or Feedback"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.isReleasedWhenClosed = false
        let lifecycle = DocumentWindowLifecycleDelegate { [weak self] in
            self?.bugReportWindow = nil
            self?.bugReportWindowLifecycleHandler = nil
            self?.demoteToAccessoryIfIdle()
        }
        window.delegate = lifecycle
        window.makeKeyAndOrderFront(nil)

        bugReportWindow = window
        bugReportWindowLifecycleHandler = lifecycle
    }

    func openHelpSupport() {
        promoteToRegularActivation()

        if let window = helpSupportWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = HelpSupportHubView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Help & Support"
        window.contentMinSize = NSSize(width: 580, height: 480)
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.setFrameAutosaveName("openburnbar.helpsupport")
        window.isReleasedWhenClosed = false
        let lifecycle = DocumentWindowLifecycleDelegate { [weak self] in
            self?.helpSupportWindow = nil
            self?.helpSupportWindowLifecycleHandler = nil
            self?.demoteToAccessoryIfIdle()
        }
        window.delegate = lifecycle
        window.makeKeyAndOrderFront(nil)

        helpSupportWindow = window
        helpSupportWindowLifecycleHandler = lifecycle
    }

    func openOnboardingWizard(
        dataStore: DataStore,
        aggregator: UsageAggregator?,
        settingsManager: SettingsManager,
        chatController: ChatSessionController?,
        onOpenDashboard: @escaping () -> Void
    ) {
        promoteToRegularActivation()

        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = OnboardingWizardView(
            dataStore: dataStore,
            aggregator: aggregator,
            settingsManager: settingsManager,
            chatController: chatController,
            onDismiss: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.demoteToAccessoryIfIdle()
            },
            onOpenDashboard: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                onOpenDashboard()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to OpenBurnBar"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(DesignSystem.Colors.background)
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        // The red close button must run the same demote path as onDismiss —
        // without a delegate, closing via titlebar left the menu-bar app stuck
        // with a Dock icon (regular activation) until quit.
        let onboardingLifecycle = DocumentWindowLifecycleDelegate { [weak self] in
            self?.onboardingWindow = nil
            self?.onboardingWindowLifecycleHandler = nil
            self?.demoteToAccessoryIfIdle()
        }
        window.delegate = onboardingLifecycle
        onboardingWindowLifecycleHandler = onboardingLifecycle
        onboardingWindow = window
    }

    func openHermesSetupWizard(
        settingsManager: SettingsManager,
        chatController: ChatSessionController?,
        dataStore: DataStore? = nil,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil
    ) {
        promoteToRegularActivation()

        if let window = hermesSetupWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let importService: HermesInventoryImportService? = dataStore.map { store in
            HermesInventoryImportService(
                dataStore: store,
                settingsManager: settingsManager,
                cloudSyncService: cloudSyncService ?? CloudSyncService(dataStore: store, accountManager: .shared, settingsManager: settingsManager),
                iCloudMirrorService: iCloudSessionMirrorService ?? ICloudSessionMirrorService(settingsManager: settingsManager)
            )
        }

        let contentView = HermesSetupWizardView(
            settingsManager: settingsManager,
            chatController: chatController,
            inventoryImportService: importService,
            onDismiss: { [weak self] in
                self?.hermesSetupWindow?.close()
                self?.hermesSetupWindow = nil
                self?.demoteToAccessoryIfIdle()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up Hermes"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(DesignSystem.Colors.background)
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        let hermesLifecycle = DocumentWindowLifecycleDelegate { [weak self] in
            self?.hermesSetupWindow = nil
            self?.hermesSetupWindowLifecycleHandler = nil
            self?.demoteToAccessoryIfIdle()
        }
        window.delegate = hermesLifecycle
        hermesSetupWindowLifecycleHandler = hermesLifecycle
        hermesSetupWindow = window
    }

    func openSwitcherOnboardingWizard(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        accountManager: AccountManager,
        onOpenSettings: @escaping () -> Void
    ) {
        promoteToRegularActivation()

        if let window = switcherOnboardingWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = SwitcherOnboardingWizardView(
            dataStore: dataStore,
            settingsManager: settingsManager,
            accountManager: accountManager,
            onDismiss: { [weak self] in
                self?.switcherOnboardingWindow?.close()
                self?.switcherOnboardingWindow = nil
                self?.demoteToAccessoryIfIdle()
            },
            onOpenSettings: { [weak self] in
                self?.switcherOnboardingWindow?.close()
                self?.switcherOnboardingWindow = nil
                onOpenSettings()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Account Switching"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(DesignSystem.Colors.background)
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        let switcherLifecycle = DocumentWindowLifecycleDelegate { [weak self] in
            self?.switcherOnboardingWindow = nil
            self?.switcherOnboardingWindowLifecycleHandler = nil
            self?.demoteToAccessoryIfIdle()
        }
        window.delegate = switcherLifecycle
        switcherOnboardingWindowLifecycleHandler = switcherLifecycle
        switcherOnboardingWindow = window
    }

    func openStartupRecovery(
        failure: DataStoreStartupFailure,
        isRetrying: Bool,
        isArchivingReset: Bool,
        actionError: String?,
        onRetry: @escaping () -> Void,
        onRevealSupportFolder: @escaping () -> Void,
        onArchiveAndReset: @escaping () -> Void,
        onCopyDiagnostics: @escaping () -> Bool,
        onQuit: @escaping () -> Void
    ) {
        promoteToRegularActivation()

        let contentView = DataStoreStartupRecoveryView(
            failure: failure,
            isRetrying: isRetrying,
            isArchivingReset: isArchivingReset,
            actionError: actionError,
            compact: false,
            onRetry: onRetry,
            onRevealSupportFolder: onRevealSupportFolder,
            onArchiveAndReset: onArchiveAndReset,
            onCopyDiagnostics: onCopyDiagnostics,
            onQuit: onQuit,
            onUnlockKeychain: failure.isKeychainLocked ? {
                // The user asked for this, having just read what macOS is about to
                // request. Only now may keychain UI appear.
                if DatabaseEncryptionService.unlockUnreadableKeyWithUserConsent() {
                    onRetry()
                }
            } : nil
        )

        if let window = startupRecoveryWindow {
            window.contentView = NSHostingView(rootView: contentView)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenBurnBar Recovery"
        window.backgroundColor = NSColor(DesignSystem.Colors.background)
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        let recoveryLifecycle = DocumentWindowLifecycleDelegate { [weak self] in
            self?.startupRecoveryWindow = nil
            self?.startupRecoveryWindowLifecycleHandler = nil
            self?.demoteToAccessoryIfIdle()
        }
        window.delegate = recoveryLifecycle
        startupRecoveryWindowLifecycleHandler = recoveryLifecycle
        startupRecoveryWindow = window
    }

    func closeStartupRecovery() {
        startupRecoveryWindow?.close()
        startupRecoveryWindow = nil
        demoteToAccessoryIfIdle()
    }

    // MARK: - Receipts Window

    func openReceiptsWindow(dataStore: DataStore, initialReceiptId: String? = nil) {
        promoteToRegularActivation()

        if let window = receiptsWindow {
            if let initialReceiptId {
                let contentView = ReceiptDrawerView(
                    dataStore: dataStore,
                    initialReceiptId: initialReceiptId,
                    onClose: { [weak self] in
                        self?.closeReceiptsWindow()
                    }
                )
                .frame(minWidth: 840, minHeight: 600)
                window.contentView = NSHostingView(rootView: contentView)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = ReceiptDrawerView(
            dataStore: dataStore,
            initialReceiptId: initialReceiptId,
            onClose: { [weak self] in
                self?.closeReceiptsWindow()
            }
        )
        .frame(minWidth: 840, minHeight: 600)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenBurnBar Receipts"
        window.backgroundColor = NSColor.windowBackgroundColor
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        let lifecycle = DocumentWindowLifecycleDelegate { [weak self] in
            self?.receiptsWindow = nil
            self?.receiptsWindowLifecycleHandler = nil
            self?.demoteToAccessoryIfIdle()
        }
        window.delegate = lifecycle
        receiptsWindowLifecycleHandler = lifecycle
        receiptsWindow = window
    }

    func closeReceiptsWindow() {
        receiptsWindow?.close()
        receiptsWindow = nil
        demoteToAccessoryIfIdle()
    }

    // MARK: - Chat Pop-Out Window

    private static var chatPopOutWindow: NSWindow?
    private static var chatPopOutLifecycleHandler: ChatPopOutWindowLifecycleDelegate?

    @discardableResult
    func openChatPopOutWindow(
        controller: ChatSessionController,
        dataStore: DataStore,
        settingsManager: SettingsManager,
        accountManager: AccountManager
    ) -> NSWindow {
        promoteToRegularActivation()

        if let window = WindowManager.chatPopOutWindow {
            window.makeKeyAndOrderFront(nil)
            return window
        }

        let contentView = WindowManager.chatPopOutContent(
            controller: controller,
            dataStore: dataStore,
            settingsManager: settingsManager,
            accountManager: accountManager,
            onClose: { [weak self] in self?.closeChatPopOutWindow() }
        )
        .frame(minWidth: 780, minHeight: 560)

        let initialFrame = WindowManager.persistedChatPopOutFrame()
            ?? NSRect(x: 0, y: 0, width: 1100, height: 760)

        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Chat — OpenBurnBar"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(DesignSystem.Colors.background)
        window.contentView = NSHostingView(rootView: contentView)
        if WindowManager.persistedChatPopOutFrame() == nil {
            window.center()
        }
        if OpenBurnBarRuntime.isRunningTests {
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        window.isReleasedWhenClosed = false

        let delegate = ChatPopOutWindowLifecycleDelegate { [weak self] closed in
            WindowManager.persistChatPopOutFrame(closed.frame)
            WindowManager.chatPopOutWindow = nil
            WindowManager.chatPopOutLifecycleHandler = nil
            self?.demoteToAccessoryIfIdle()
        }
        window.delegate = delegate

        WindowManager.chatPopOutWindow = window
        WindowManager.chatPopOutLifecycleHandler = delegate
        return window
    }

    func closeChatPopOutWindow() {
        WindowManager.chatPopOutWindow?.close()
        demoteToAccessoryIfIdle()
    }

    /// Test-only accessor.
    static func _currentChatPopOutWindow() -> NSWindow? { chatPopOutWindow }

    private static func chatPopOutContent(
        controller: ChatSessionController,
        dataStore: DataStore,
        settingsManager: SettingsManager,
        accountManager: AccountManager,
        onClose: @escaping () -> Void
    ) -> AnyView {
        guard !OpenBurnBarRuntime.isRunningTests else {
            return AnyView(ChatPopOutWindowTestContent(onClose: onClose))
        }

        return AnyView(
            DashboardChatWorkspaceView(
                controller: controller,
                dataStore: dataStore,
                settingsManager: settingsManager,
                sharedFeaturesAvailable: accountManager.isSignedIn,
                mode: .popOut,
                onClose: onClose
            )
            .environment(settingsManager)
            .environment(accountManager)
        )
    }

    fileprivate static func persistedChatPopOutFrame() -> NSRect? {
        let raw = UserDefaults.standard.string(forKey: "dashboardChatPopOutFrameJSON") ?? ""
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"],
              w >= 780, h >= 560
        else { return nil }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    fileprivate static func persistChatPopOutFrame(_ rect: NSRect) {
        let dict: [String: Double] = [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "w": Double(rect.size.width),
            "h": Double(rect.size.height)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let raw = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(raw, forKey: "dashboardChatPopOutFrameJSON")
        }
    }
}

@MainActor
private final class ChatPopOutWindowLifecycleDelegate: NSObject, NSWindowDelegate {
    private let onWillClose: @MainActor (NSWindow) -> Void

    init(onWillClose: @escaping @MainActor (NSWindow) -> Void) {
        self.onWillClose = onWillClose
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            self.onWillClose(window)
        }
    }
}

private struct ChatPopOutWindowTestContent: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Chat")
                .font(.headline)
            Button("Close", action: onClose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("chat-pop-out-test-content")
    }
}

@MainActor
private final class DashboardWindowLifecycleDelegate: NSObject, NSWindowDelegate {
    private let onDidHide: @MainActor () -> Void

    init(onDidHide: @escaping @MainActor () -> Void) {
        self.onDidHide = onDidHide
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        onDidHide()
        return false
    }
}

/// Clears a retained document-window reference on close and lets WindowManager
/// demote back to `.accessory` when nothing document-like remains.
@MainActor
private final class DocumentWindowLifecycleDelegate: NSObject, NSWindowDelegate {
    private let onWillClose: @MainActor () -> Void

    init(onWillClose: @escaping @MainActor () -> Void) {
        self.onWillClose = onWillClose
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.onWillClose()
        }
    }
}
