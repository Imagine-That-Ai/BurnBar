import AppKit
import FirebaseAuth
import FirebaseCore
import FirebaseAppCheck
import GoogleSignIn
import OpenBurnBarCore
import OSLog
import SwiftUI

#if canImport(Sentry)
import Sentry
#endif

/// Single source of truth for "this process is hosting an XCTest bundle, not a real user."
///
/// XCTest's host-bundle-loader path is sensitive: any heavyweight scene work, file I/O, or
/// background `Task` started inside `App.init` / `App.body` can race the runner-connect window
/// and produce the opaque `"test runner hung before establishing connection"` failure mode.
/// We use this gate to short-circuit *every* expensive bootstrap and replace the menu-bar
/// scene with `EmptyScene` so the test process becomes a near-empty SwiftUI host whose only
/// job is loading and executing `OpenBurnBarTests.xctest`.
enum OpenBurnBarRuntime {
    @MainActor private static var harnessHostActivity: NSObjectProtocol?

    /// True when the current process is an XCTest host. Detected via the well-known
    /// XCTest environment variables that Apple injects into the test runner.
    static var isRunningTests: Bool {
        isRunningTests(
            environment: ProcessInfo.processInfo.environment,
            loadedBundlePaths: Bundle.allBundles.map(\.bundlePath),
            mainBundleContainsXCTestPlugin: mainBundleContainsXCTestPlugin()
        )
    }

    static func isRunningTests(
        environment: [String: String],
        loadedBundlePaths: [String],
        mainBundleContainsXCTestPlugin: Bool
    ) -> Bool {
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["TEST_RUNNER_CI"] == "true"
            || environment["TEST_RUNNER_GITHUB_ACTIONS"] == "true"
            || environment["TEST_RUNNER_RUNNER_OS"] != nil
            || loadedBundlePaths.contains { $0.hasSuffix(".xctest") }
            || mainBundleContainsXCTestPlugin
    }

    private static func mainBundleContainsXCTestPlugin() -> Bool {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: plugInsURL,
                includingPropertiesForKeys: nil
              ) else {
            return false
        }
        return contents.contains { $0.pathExtension == "xctest" }
    }

    /// Allows tests / harnesses to opt **in** to the live menu-bar scene by setting
    /// `OPENBURNBAR_FORCE_LIVE_SCENE=1`. Default is opt-out (skip the live scene under tests).
    static var forceLiveScene: Bool {
        ProcessInfo.processInfo.environment["OPENBURNBAR_FORCE_LIVE_SCENE"] == "1"
    }

    /// Harness-launched live-scene processes must remain alive even when AppKit
    /// sees no active window. The iroh relay smoke starts the menu-bar app from
    /// a shell, so automatic termination can otherwise kill the host right after
    /// the first relay publish.
    static var shouldDisableAutomaticTerminationForHarness: Bool {
        shouldDisableAutomaticTerminationForHarness(environment: ProcessInfo.processInfo.environment)
    }

    static func shouldDisableAutomaticTerminationForHarness(environment: [String: String]) -> Bool {
        environment["OPENBURNBAR_FORCE_LIVE_SCENE"] == "1"
            || environment["OPENBURNBAR_E2E_HOLD_OPEN"] == "1"
    }

    @MainActor
    static func beginHarnessHostActivityIfNeeded() {
        beginHarnessHostActivityIfNeeded(environment: ProcessInfo.processInfo.environment)
    }

    @MainActor
    static func beginHarnessHostActivityIfNeeded(environment: [String: String]) {
        guard shouldDisableAutomaticTerminationForHarness(environment: environment),
              harnessHostActivity == nil else { return }
        let processInfo = ProcessInfo.processInfo
        processInfo.disableSuddenTermination()
        processInfo.disableAutomaticTermination("OpenBurnBar E2E relay host is active")
        harnessHostActivity = processInfo.beginActivity(
            options: [.automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "OpenBurnBar E2E relay host is active"
        )
    }

    /// True when we should bypass the live menu-bar scene and present `EmptyScene()` instead.
    /// This is the gate that protects the XCTest runner-connect window.
    static var shouldUseTestStubScene: Bool {
        shouldUseTestStubScene(isRunningTests: isRunningTests, forceLiveScene: forceLiveScene)
    }

    static func shouldUseTestStubScene(isRunningTests: Bool, forceLiveScene: Bool) -> Bool {
        isRunningTests && !forceLiveScene
    }
}

/// `MenuBarExtra` uses the label image's intrinsic size and commonly ignores SwiftUI `.frame` / layout on nested
/// views. Rasterize the vector `AppLogo` to a small `NSImage` so the status item matches normal menu-bar icons.
private enum MenuBarRasterBrandMark {
    static let side: CGFloat = 18

    static let image: NSImage = {
        let empty = NSImage(size: NSSize(width: side, height: side))
        guard let source = NSImage(named: "AppLogo") else { return empty }
        let target = NSSize(width: side, height: side)
        return NSImage(size: target, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .high
            let from = NSRect(origin: .zero, size: source.size)
            source.draw(in: rect, from: from, operation: .copy, fraction: 1.0, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }()
}

@MainActor
final class AppCommandRouter {
    static let shared = AppCommandRouter()

    var openDashboard: (() -> Void)?
    var openConversationSearch: (() -> Void)?
    var openChatPanel: (() -> Void)?

    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "openburnbar" else { return false }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let target = host.isEmpty ? path : host

        switch target {
        case "dashboard":
            openDashboard?()
            return true
        case "search", "chat":
            openConversationSearch?()
            return true
        default:
            return false
        }
    }
}

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
    private var dashboardWindowLifecycleDelegate: DashboardWindowLifecycleDelegate?

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
        dashboardWindowLifecycleDelegate = lifecycleDelegate
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
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
    private static var chatPopOutDelegate: ChatPopOutWindowLifecycleDelegate?

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
            WindowManager.chatPopOutDelegate = nil
        }
        window.delegate = delegate

        WindowManager.chatPopOutWindow = window
        WindowManager.chatPopOutDelegate = delegate
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

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard window.isVisible, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }

        window.orderOut(nil)
    }
}

// MARK: - App Entry Point

@main
struct OpenBurnBarApp: App {
    private static var didConfigureFirebase = false

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("hasShownInitialDashboard") private var hasShownInitialDashboard = false
    @StateObject private var windowManager = WindowManager.shared
    @State private var startupState: OpenBurnBarStartupState
    @State private var isRetryingStartup = false
    @State private var isArchivingReset = false
    @State private var startupRecoveryActionError: String?
    @State private var hasPresentedStartupRecoveryWindow = false
    @State private var periodicRefreshTask: Task<Void, Never>?
    @State private var navigationCoordinator = NavigationCoordinator()

    init() {
        if OpenBurnBarRuntime.shouldUseTestStubScene {
            // XCTest host fast path. The developer's real `OpenBurnBar` support
            // directory frequently grows past several GB; opening the canonical
            // on-disk SQLite database from `App.init` synchronously can take
            // long enough to race the XCTest runner-connect handshake (the
            // opaque `"test runner hung before establishing connection"`
            // failure mode). We therefore skip every form of synchronous boot:
            //   - No Firebase / Sentry / Google Sign-In configuration.
            //   - No `OpenBurnBarMigration.migrateUserDefaults()` (the legacy-
            //     domain scan can stall briefly under XCTest sandboxing).
            //   - No `DataStore` open. The live menu-bar scene is short-
            //     circuited to `EmptyView` for both content and label by
            //     `OpenBurnBarRuntime.shouldUseTestStubScene` so `startupState`
            //     is never read in this branch. Tests open their own isolated
            //     `DataStore`s in `setUp`; the placeholder below exists only
            //     to satisfy `_startupState`'s non-optional initial value.
            _startupState = State(initialValue: .failed(
                DataStoreStartupFailure.testStubPlaceholder()
            ))
            return
        }

        Self.configureFirebaseIfAvailable()
        Self.configureSentryIfAvailable()
        OpenBurnBarMigration.migrateUserDefaults()

        _startupState = State(initialValue: Self.makeStartupState())
    }

    @MainActor
    private static func makeStartupState(archiveURL: URL? = nil) -> OpenBurnBarStartupState {
        do {
            return .ready(try makeRuntimeContext())
        } catch {
            AppLogger.dataStore.error(
                "startup_datastore_open_failed",
                metadata: ["error": String(describing: error)]
            )
            return .failed(DataStoreStartupFailure.make(error: error, archiveURL: archiveURL))
        }
    }

    @MainActor
    private static func makeRuntimeContext() throws -> OpenBurnBarRuntimeContext {
        let initializedStore = try DataStore()
        let settings = SettingsManager()
        let accountManager = AccountManager.shared
        let quotaService = ProviderQuotaService(settingsManager: settings)
        let daemonManager = OpenBurnBarDaemonManager(settingsManager: settings)
        let cursorConnectorManager = CursorConnectorManager(settingsManager: settings)

        let controller = ChatSessionController(dataStore: initializedStore, settingsManager: settings)
        let layer = OpenBurnBarOperatingLayer(
            dataStore: initializedStore,
            settingsManager: settings,
            accountManager: accountManager,
            daemonManager: daemonManager,
            chatController: controller
        )

        let context = OpenBurnBarRuntimeContext(
            dataStore: initializedStore,
            settingsManager: settings,
            accountManager: accountManager,
            quotaService: quotaService,
            daemonManager: daemonManager,
            cursorConnectorManager: cursorConnectorManager,
            chatController: controller,
            operatingLayer: layer
        )
        context.startRelayServices()
        context.startSmartDisplayServices()
        return context
    }

    @MainActor
    private static func configureFirebaseIfAvailable() {
        guard !didConfigureFirebase else {
            AccountManager.shared.onFirebaseConfigured()
            return
        }
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            return
        }

        // Configure App Check before FirebaseApp.configure()
        AppCheckDebugTokenEnvironment.configureIfAvailable(firebasePlistPath: path)
        let providerFactory = OpenBurnBarAppCheckProviderFactory()
        AppCheck.setAppCheckProviderFactory(providerFactory)

        FirebaseApp.configure(options: options)
        didConfigureFirebase = true
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        AccountManager.shared.onFirebaseConfigured()
        #if DEBUG
        signInWithE2ECustomTokenIfNeeded()
        #endif

        // Validate App Check token when cloud sync is enabled.
        // This is a fail-open warning: the app continues to work but logs a warning.
        Task {
            await validateAppCheckIfNeeded()
        }
    }

    #if DEBUG
    private static func signInWithE2ECustomTokenIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let token = environment["OPENBURNBAR_E2E_FIREBASE_CUSTOM_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = environment["OPENBURNBAR_E2E_FIREBASE_EMAIL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = environment["OPENBURNBAR_E2E_FIREBASE_PASSWORD"]
        guard token?.isEmpty == false || (email?.isEmpty == false && password?.isEmpty == false) else {
            return
        }

        let expectedUID = environment["OPENBURNBAR_E2E_FIREBASE_UID"]
        if let expectedUID, Auth.auth().currentUser?.uid == expectedUID {
            return
        }

        Task { @MainActor in
            do {
                let result: AuthDataResult
                if let token, token.isEmpty == false {
                    result = try await Auth.auth().signIn(withCustomToken: token)
                } else if let email, let password {
                    result = try await Auth.auth().signIn(withEmail: email, password: password)
                } else {
                    return
                }
                AccountManager.shared.onFirebaseConfigured()
                print("OpenBurnBar E2E Firebase sign-in active for uid \(result.user.uid).")
            } catch {
                print("warning: OpenBurnBar E2E Firebase sign-in failed: \(error.localizedDescription)")
            }
        }
    }
    #endif

    /// Validates that App Check is functional when cloud sync is enabled.
    /// Posts a notification if App Check cannot obtain a token so the UI can warn the user.
    @MainActor
    private static func validateAppCheckIfNeeded() async {
        guard AccountManager.shared.isCloudSyncEnabled else { return }
        do {
            let token = try await AppCheck.appCheck().token(forcingRefresh: false)
            guard !token.token.isEmpty else {
                postAppCheckWarning("App Check returned an empty token.")
                return
            }
        } catch {
            postAppCheckWarning("App Check token fetch failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func postAppCheckWarning(_ message: String) {
        os_log("App Check validation warning: %{public}@", log: .default, type: .error, message)
        NotificationCenter.default.post(
            name: .openBurnBarAppCheckValidationFailed,
            object: nil,
            userInfo: ["message": message]
        )
    }

    /// Initialize Sentry crash reporting if a DSN is available.
    /// The DSN is read from the `sentry.dsn` key in Info.plist (injected via
    /// CI for internal builds). If absent, Sentry remains disabled silently.
    #if canImport(Sentry)
    @MainActor
    private static func configureSentryIfAvailable() {
        guard let dsn = Bundle.main.object(forInfoDictionaryKey: "sentry.dsn") as? String,
              !dsn.trimmingCharacters(in: .whitespaces).isEmpty else {
            // No DSN configured — crash reporting remains disabled silently.
            return
        }
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = "app"
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            options.releaseName = "openburnbar@\(version)"
            options.enableTracing = false
            options.enableAutoSessionTracking = true
            #if DEBUG
            options.debug = false
            #endif
        }

        // Set an anonymized user ID so Sentry can correlate crashes per install
        // without collecting any personally identifiable information.
        let user = User()
        let bundleID = Bundle.main.bundleIdentifier ?? "com.openburnbar.app"
        let vendorSeed = (bundleID + NSFullUserName()).data(using: .utf8) ?? Data()
        let anonymizedID = vendorSeed.map { String(format: "%02x", $0) }.joined().prefix(32)
        user.userId = String(anonymizedID)
        SentrySDK.setUser(user)
    }
    #else
    @MainActor
    private static func configureSentryIfAvailable() {
        // Sentry SDK not linked — skip silently.
    }
    #endif

    @MainActor
    private func installCommandRouter() {
        guard let context = startupState.runtimeContext else {
            AppCommandRouter.shared.openDashboard = { openStartupRecoveryWindow() }
            AppCommandRouter.shared.openConversationSearch = { openStartupRecoveryWindow() }
            AppCommandRouter.shared.openChatPanel = { openStartupRecoveryWindow() }
            return
        }

        AppCommandRouter.shared.openDashboard = {
            openDashboard(context: context)
        }
        AppCommandRouter.shared.openConversationSearch = {
            openDashboard(context: context)
            navigationCoordinator.openConversationSearch()
        }
        AppCommandRouter.shared.openChatPanel = {
            openDashboard(context: context)
            navigationCoordinator.openChatPanel()
        }
    }

    @MainActor
    private func openDashboard(context: OpenBurnBarRuntimeContext) {
        windowManager.openDashboard(
            dataStore: context.dataStore,
            aggregator: context.aggregator,
            accountManager: context.accountManager,
            cloudSyncService: context.cloudSyncService,
            iCloudSessionMirrorService: context.iCloudSessionMirrorService,
            chatController: context.chatController,
            operatingLayer: context.operatingLayer,
            navigationCoordinator: navigationCoordinator,
            settingsManager: context.settingsManager,
            runtimeContext: context
        )
    }

    @MainActor
    private func openStartupRecoveryWindow() {
        guard let failure = startupState.failure else { return }
        windowManager.openStartupRecovery(
            failure: failure,
            isRetrying: isRetryingStartup,
            isArchivingReset: isArchivingReset,
            actionError: startupRecoveryActionError,
            onRetry: retryStartup,
            onRevealSupportFolder: revealStartupSupportFolder,
            onArchiveAndReset: archiveAndResetStartupDatabase,
            onCopyDiagnostics: copyStartupDiagnostics,
            onQuit: quitFromStartupRecovery
        )
    }

    @MainActor
    private func retryStartup() {
        guard !isRetryingStartup && !isArchivingReset else { return }
        isRetryingStartup = true
        startupRecoveryActionError = nil
        startupState = Self.makeStartupState()
        isRetryingStartup = false
        if startupState.runtimeContext != nil {
            hasPresentedStartupRecoveryWindow = false
            windowManager.closeStartupRecovery()
        } else {
            openStartupRecoveryWindow()
        }
    }

    @MainActor
    private func archiveAndResetStartupDatabase() {
        guard !isRetryingStartup && !isArchivingReset else { return }
        isArchivingReset = true
        startupRecoveryActionError = nil
        do {
            let archiveResult = try OpenBurnBarStartupRecovery.archiveDatabaseSidecars()
            startupState = Self.makeStartupState(archiveURL: archiveResult.archiveDirectory)
            isArchivingReset = false
            if startupState.runtimeContext != nil {
                hasPresentedStartupRecoveryWindow = false
                windowManager.closeStartupRecovery()
            } else {
                startupRecoveryActionError = "The database was archived, but OpenBurnBar still could not create a clean database."
                openStartupRecoveryWindow()
            }
        } catch {
            isArchivingReset = false
            startupRecoveryActionError = error.localizedDescription
            AppLogger.dataStore.error(
                "startup_datastore_archive_reset_failed",
                metadata: ["error": String(describing: error)]
            )
            openStartupRecoveryWindow()
        }
    }

    @MainActor
    private func revealStartupSupportFolder() {
        guard let failure = startupState.failure else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: failure.supportDirectory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([failure.supportDirectory])
        } else {
            NSWorkspace.shared.selectFile(
                nil,
                inFileViewerRootedAtPath: failure.supportDirectory.deletingLastPathComponent().path
            )
        }
    }

    @MainActor
    private func copyStartupDiagnostics() -> Bool {
        guard let failure = startupState.failure else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(failure.diagnostics, forType: .string)
    }

    @MainActor
    private func quitFromStartupRecovery() {
        NSApplication.shared.terminate(nil)
    }

    #if DEBUG
    @MainActor
    private func toggleHermesIrohTransportFromDebugMenu() {
        guard let context = startupState.runtimeContext else {
            NSSound.beep()
            return
        }
        context.settingsManager.hermesRemoteRelayEnabled = true
        context.settingsManager.hermesIrohTransportEnabled.toggle()
    }
    #endif

    @SceneBuilder
    private var liveMenuBarScene: some Scene {
        let _ = installCommandRouter()
        let _ = OpenBurnBarRuntime.beginHarnessHostActivityIfNeeded()
        MenuBarExtra {
            if OpenBurnBarRuntime.shouldUseTestStubScene {
                EmptyView()
            } else {
                switch startupState {
                case .ready(let context):
                    MenuBarPopoverView(
                        dataStore: context.dataStore,
                        aggregator: context.aggregator,
                        quotaService: context.quotaService,
                        settingsManager: context.settingsManager,
                        smartHubBridgeController: context.smartHubBridgeController,
                        smartDisplayRepairCoordinator: context.smartDisplayRepairCoordinator,
                        operatingLayer: context.operatingLayer,
                        onOpenDashboard: {
                            openDashboard(context: context)
                        },
                        onOpenSettings: {
                            windowManager.openSettings(
                                settingsManager: context.settingsManager,
                                accountManager: context.accountManager,
                                cloudSyncService: context.cloudSyncService,
                                iCloudSessionMirrorService: context.iCloudSessionMirrorService,
                                dataStore: context.dataStore,
                                runtimeContext: context
                            )
                        },
                        chatController: context.chatController,
                        onOpenDashboardWithChat: {
                            openDashboard(context: context)
                            navigationCoordinator.openChatPanel()
                        },
                        onOpenOnboardingWizard: {
                            windowManager.openOnboardingWizard(
                                dataStore: context.dataStore,
                                aggregator: context.aggregator,
                                settingsManager: context.settingsManager,
                                chatController: context.chatController,
                                onOpenDashboard: {
                                    openDashboard(context: context)
                                }
                            )
                        }
                    )
                    .environment(context.settingsManager)
                case .failed(let failure):
                    DataStoreStartupRecoveryView(
                        failure: failure,
                        isRetrying: isRetryingStartup,
                        isArchivingReset: isArchivingReset,
                        actionError: startupRecoveryActionError,
                        compact: true,
                        onRetry: retryStartup,
                        onRevealSupportFolder: revealStartupSupportFolder,
                        onArchiveAndReset: archiveAndResetStartupDatabase,
                        onCopyDiagnostics: copyStartupDiagnostics,
                        onQuit: quitFromStartupRecovery
                    )
                }
            }
        } label: {
            if OpenBurnBarRuntime.shouldUseTestStubScene {
                EmptyView()
            } else {
                switch startupState {
                case .ready(let context):
                    MenuBarLabel(
                        totalCostToday: context.dataStore.totalCostToday,
                        totalTokensToday: context.dataStore.totalTokensToday,
                        usageDisplayMode: context.settingsManager.usageDisplayMode,
                        rollingDailyAverage: context.dataStore.rollingDailyAverage,
                        isRefreshing: context.aggregator?.isRefreshing ?? false
                    )
                    .task {
                        await Task.yield()
                        guard !OpenBurnBarRuntime.shouldUseTestStubScene else { return }
                        let sync: CloudSyncService
                        if let existingSync = context.cloudSyncService {
                            sync = existingSync
                        } else {
                            sync = CloudSyncService(
                                dataStore: context.dataStore,
                                accountManager: context.accountManager,
                                settingsManager: context.settingsManager
                            )
                        }
                        context.cloudSyncService = sync

                        context.startRelayServices()
                        #if !DISTRIBUTION_MAS
                        context.startComputerUseServices(cloudSyncService: sync)
                        #endif
                        context.startSmartDisplayServices()

                        let mirror: ICloudSessionMirrorService
                        if let existingMirror = context.iCloudSessionMirrorService {
                            mirror = existingMirror
                        } else {
                            mirror = ICloudSessionMirrorService(settingsManager: context.settingsManager)
                        }
                        context.iCloudSessionMirrorService = mirror

                        let aggregator: UsageAggregator
                        if let existingAggregator = context.aggregator {
                            aggregator = existingAggregator
                        } else {
                            aggregator = UsageAggregator(
                                dataStore: context.dataStore,
                                cloudSync: sync,
                                sessionMirror: mirror,
                                settingsManager: context.settingsManager,
                                quotaService: context.quotaService
                            )
                        }
                        context.aggregator = aggregator
                        context.operatingLayer.aggregator = aggregator
                        context.operatingLayer.chatController = context.chatController
                        context.daemonManager.attach(dataStore: context.dataStore, cloudSyncService: sync)
                        #if !DISTRIBUTION_MAS
                        ComputerUseDaemonApprovalPresenter.shared.start(daemonManager: context.daemonManager)
                        #endif
                        context.cursorConnectorManager.attach(dataStore: context.dataStore)
                        context.quotaService.startAutomaticRefresh(dataStore: context.dataStore)
                        if !hasShownInitialDashboard {
                            hasShownInitialDashboard = true
                            windowManager.openDashboard(
                                dataStore: context.dataStore,
                                aggregator: aggregator,
                                accountManager: context.accountManager,
                                cloudSyncService: sync,
                                iCloudSessionMirrorService: mirror,
                                chatController: context.chatController,
                                operatingLayer: context.operatingLayer,
                                navigationCoordinator: navigationCoordinator,
                                settingsManager: context.settingsManager,
                                runtimeContext: context
                            )
                        }
                        // Probe managed runtime availability in the background.
                        Task {
                            if context.settingsManager.launchHermesWithOpenBurnBar {
                                let baseURL = URL(string: context.settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                                    ?? URL(string: "http://127.0.0.1:8642")!
                                let bearerToken = context.settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
                                await HermesRuntimeLauncher().openHermesAndGateway(
                                    baseURL: baseURL,
                                    bearerToken: bearerToken.isEmpty ? nil : bearerToken
                                )
                            }
                            if context.settingsManager.launchPiAgentsWithOpenBurnBar {
                                let baseURL = URL(string: context.settingsManager.piAgentGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                                    ?? URL(string: "http://127.0.0.1:8765")!
                                let bearerToken = context.settingsManager.piAgentBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
                                let preferred = context.settingsManager.piAgentSelectedInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
                                let redisRaw = context.settingsManager.piAgentRedisURL.trimmingCharacters(in: .whitespacesAndNewlines)
                                let piAdapter = PiAgentRuntimeAdapter(
                                    preferredInstanceID: preferred.isEmpty ? nil : preferred,
                                    redisURL: redisRaw.isEmpty ? nil : URL(string: redisRaw)
                                )
                                _ = await piAdapter.openManagedRuntime(
                                    baseURL: baseURL,
                                    bearerToken: bearerToken.isEmpty ? nil : bearerToken
                                )
                            }
                            let enabledBackends = Set(context.settingsManager.enabledChatBackends)
                            if enabledBackends.contains(.hermes) || context.chatController.chatBackend == .hermes {
                                await context.chatController.probeHermesAvailability()
                            } else {
                                context.chatController.hermesAvailable = false
                            }
                            if enabledBackends.contains(.openclaw) || context.chatController.chatBackend == .openclaw {
                                await context.chatController.probeOpenClawAvailability()
                            } else {
                                context.chatController.openClawAvailable = false
                            }
                            if enabledBackends.contains(.piAgent) || context.chatController.chatBackend == .piAgent {
                                await context.chatController.probePiAgentAvailability()
                            } else {
                                context.chatController.piAgentAvailable = false
                            }
                            await context.daemonManager.refreshHealth()
                            await context.operatingLayer.refreshControllerRuntime()
                        }
                        // Delay the first scan so app activation, menu-bar paint, SmartHub
                        // bridge startup, and Pixel Clock setup are not competing with parser
                        // and DB I/O. When a physical clock is enabled, the hardware control
                        // path needs to become responsive before historical log backfill starts.
                        Task(priority: .utility) {
                            for _ in 0..<30 where !context.accountManager.isSignedIn {
                                try? await Task.sleep(for: .seconds(1))
                                guard !Task.isCancelled else { return }
                            }
                            await sync.uploadPending()
                            let startupScanDelay: Duration = context.settingsManager.pixelClockConfig.enabled
                                ? .seconds(600)
                                : .seconds(15)
                            try? await Task.sleep(for: startupScanDelay)
                            guard !Task.isCancelled else { return }
                            await aggregator.refreshAll()
                            await sync.uploadPendingConversations()
                            await sync.uploadPendingChatThreads()
                            if context.settingsManager.dailyDigestEnabled {
                                await DailyDigestManager.shared.requestAuthorization()
                                DailyDigestManager.shared.scheduleDigest(
                                    from: context.dataStore,
                                    at: context.settingsManager.dailyDigestHour
                                )
                            }
                        }
                        periodicRefreshTask?.cancel()
                        periodicRefreshTask = Task(priority: .utility) {
                            while !Task.isCancelled {
                                let minimumRefreshInterval: TimeInterval = context.settingsManager.pixelClockConfig.enabled
                                    ? 10 * 60
                                    : 60
                                let seconds = max(context.settingsManager.refreshInterval, minimumRefreshInterval)
                                let nanos = UInt64(seconds * 1_000_000_000)
                                try? await Task.sleep(nanoseconds: nanos)
                                if Task.isCancelled { break }
                                await aggregator.refreshAll()
                                await context.daemonManager.refreshHealth()
                                await context.operatingLayer.refreshControllerRuntime()
                            }
                        }
                    }
                case .failed:
                    Label {
                        EmptyView()
                    } icon: {
                        Image(nsImage: MenuBarRasterBrandMark.image)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(DesignSystem.Colors.error)
                                    .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                                    .offset(x: 4, y: -3)
                            }
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: MenuBarLabel.menuBarLabelSlotWidth, height: MenuBarLabel.menuBarLabelSlotHeight)
                    .fixedSize()
                    .help("OpenBurnBar recovery mode")
                    .task {
                        await Task.yield()
                        guard !hasPresentedStartupRecoveryWindow else { return }
                        hasPresentedStartupRecoveryWindow = true
                        openStartupRecoveryWindow()
                    }
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// The live menu-bar scene already short-circuits both `content` and `label`
    /// to `EmptyView()` when `OpenBurnBarRuntime.isRunningTests` is true (see
    /// `liveMenuBarScene` above), so all heavyweight work (popover construction,
    /// `task` blocks, daemon attaches, periodic refresh) is already gated. The
    /// remaining XCTest-host concern (synchronous `DataStore` open + Firebase /
    /// Sentry boot) is handled in `init()`. Returning `liveMenuBarScene`
    /// unconditionally keeps `body` as a single concrete `Scene` type, avoiding
    /// SwiftUI's `SceneBuilder` if/else inference quirks.
    var body: some Scene {
        liveMenuBarScene
            .commands {
                #if DEBUG
                CommandMenu("Debug") {
                    Button(
                        startupState.runtimeContext?.settingsManager.hermesIrohTransportEnabled == true
                            ? "Disable Hermes iroh Transport"
                            : "Enable Hermes iroh Transport"
                    ) {
                        toggleHermesIrohTransportFromDebugMenu()
                    }
                    .keyboardShortcut("i", modifiers: [.command, .option, .control])
                }
                #endif
            }
    }
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let totalCostToday: Double
    let totalTokensToday: Int
    let usageDisplayMode: UsageDisplayMode
    let rollingDailyAverage: Double
    let isRefreshing: Bool

    @State private var showCostIncrease = false
    @State private var bounceTick = 0
    @State private var logoBounceScale: CGFloat = 1
    @State private var pulseGlow: CGFloat = 0
    @AppStorage("lastDailyCostPulseDay") private var lastDailyCostPulseDay: String = ""

    /// Shown on hover in the menu bar (balance for the selected display mode).
    private var balanceTooltip: String {
        switch usageDisplayMode {
        case .currency:
            return "Today: \(totalCostToday.formatAsCost())"
        case .tokens:
            return "Today: \(totalTokensToday.formatAsTokenVolume()) tokens"
        }
    }

    private var todayDayKey: String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private var shouldDailyPulse: Bool {
        rollingDailyAverage > 0 && totalCostToday > rollingDailyAverage * 1.2
    }

    static let menuBarLabelSlotWidth: CGFloat = 22
    static let menuBarLabelSlotHeight: CGFloat = 18

    private var menuBarIcon: some View {
        Image(nsImage: MenuBarRasterBrandMark.image)
    }

    var body: some View {
        Label {
            EmptyView()
        } icon: {
            menuBarIcon
                .scaleEffect(logoBounceScale)
                .shadow(color: Color.primary.opacity(pulseGlow * 0.35), radius: pulseGlow * 3)
        }
        .labelStyle(.iconOnly)
        .overlay(alignment: .topTrailing) {
            Group {
                if isRefreshing {
                    AnimatedMiningPickView()
                        .frame(width: 14, height: 14)
                        .clipShape(.circle)
                        .scaleEffect(0.5)
                        .offset(x: 3, y: -3)
                } else if showCostIncrease {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.green)
                        .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                        .offset(x: 3, y: -2)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: Self.menuBarLabelSlotWidth, height: Self.menuBarLabelSlotHeight)
        .fixedSize()
        .help(balanceTooltip)
        .accessibilityLabel("\(OpenBurnBarIdentity.productName), \(balanceTooltip)")
        .onChange(of: isRefreshing) { _, new in
            guard !new else { return }
            Task { @MainActor in
                bounceTick &+= 1
            }
        }
        .onChange(of: bounceTick) { _, _ in
            Task { @MainActor in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                    logoBounceScale = 1.14
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                        logoBounceScale = 1
                    }
                }
            }
        }
        .onChange(of: totalCostToday) { oldValue, newValue in
            guard newValue > oldValue, oldValue > 0 else { return }
            Task { @MainActor in
                withAnimation(.easeIn(duration: 0.2)) {
                    showCostIncrease = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showCostIncrease = false
                    }
                }
            }
        }
        .onChange(of: shouldDailyPulse) { _, pulse in
            guard pulse, lastDailyCostPulseDay != todayDayKey else { return }
            Task { @MainActor in
                lastDailyCostPulseDay = todayDayKey
                pulseGlow = 0
                withAnimation(.easeInOut(duration: 0.45)) {
                    pulseGlow = 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeOut(duration: 0.6)) {
                        pulseGlow = 0
                    }
                }
            }
        }
    }
}
