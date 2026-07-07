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
    private var onboardingWindow: NSWindow?
    private var hermesSetupWindow: NSWindow?
    private var switcherOnboardingWindow: NSWindow?
    private var startupRecoveryWindow: NSWindow?
    private var dashboardWindowLifecycleHandler: DashboardWindowLifecycleDelegate?

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
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let window = dashboardWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFrontRegardless()
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
        window.title = OpenBurnBarIdentity.productName
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
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        let lifecycleDelegate = DashboardWindowLifecycleDelegate()
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
        NSApplication.shared.activate(ignoringOtherApps: true)

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
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        settingsWindow = window
    }

    func openOnboardingWizard(
        dataStore: DataStore,
        aggregator: UsageAggregator?,
        settingsManager: SettingsManager,
        chatController: ChatSessionController?,
        onOpenDashboard: @escaping () -> Void
    ) {
        NSApplication.shared.activate(ignoringOtherApps: true)

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

        onboardingWindow = window
    }

    func openHermesSetupWizard(
        settingsManager: SettingsManager,
        chatController: ChatSessionController?,
        dataStore: DataStore? = nil,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil
    ) {
        NSApplication.shared.activate(ignoringOtherApps: true)

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

        hermesSetupWindow = window
    }

    func openSwitcherOnboardingWizard(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        accountManager: AccountManager,
        onOpenSettings: @escaping () -> Void
    ) {
        NSApplication.shared.activate(ignoringOtherApps: true)

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
        NSApplication.shared.activate(ignoringOtherApps: true)

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
            onQuit: onQuit
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

        startupRecoveryWindow = window
    }

    func closeStartupRecovery() {
        startupRecoveryWindow?.close()
        startupRecoveryWindow = nil
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
        if !OpenBurnBarRuntime.isRunningTests {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

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

        let delegate = ChatPopOutWindowLifecycleDelegate { closed in
            WindowManager.persistChatPopOutFrame(closed.frame)
            WindowManager.chatPopOutWindow = nil
            WindowManager.chatPopOutLifecycleHandler = nil
        }
        window.delegate = delegate

        WindowManager.chatPopOutWindow = window
        WindowManager.chatPopOutLifecycleHandler = delegate
        return window
    }

    func closeChatPopOutWindow() {
        WindowManager.chatPopOutWindow?.close()
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
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
