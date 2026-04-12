import AppKit
import FirebaseCore
import GoogleSignIn
import SwiftUI

private enum OpenBurnBarRuntime {
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
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

    private var dashboardWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var hermesSetupWindow: NSWindow?
    private var switcherOnboardingWindow: NSWindow?

    func openDashboard(
        dataStore: DataStore,
        aggregator: UsageAggregator?,
        accountManager: AccountManager,
        cloudSyncService: CloudSyncService?,
        iCloudSessionMirrorService: ICloudSessionMirrorService?,
        chatController: ChatSessionController,
        operatingLayer: OpenBurnBarOperatingLayer,
        navigationCoordinator: NavigationCoordinator
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
            operatingLayer: operatingLayer
        )
        .frame(minWidth: 900, minHeight: 600)
        .environment(navigationCoordinator)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
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
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        dashboardWindow = window
    }

    func openSettings(
        settingsManager: SettingsManager,
        accountManager: AccountManager,
        cloudSyncService: CloudSyncService?,
        iCloudSessionMirrorService: ICloudSessionMirrorService?,
        dataStore: DataStore
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
            dataStore: dataStore
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
        chatController: ChatSessionController?
    ) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let window = hermesSetupWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = HermesSetupWizardView(
            settingsManager: settingsManager,
            chatController: chatController,
            onDismiss: { [weak self] in
                self?.hermesSetupWindow?.close()
                self?.hermesSetupWindow = nil
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
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
}

// MARK: - App Entry Point

@main
struct OpenBurnBarApp: App {
    private static var didConfigureFirebase = false

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("hasShownInitialDashboard") private var hasShownInitialDashboard = false
    @StateObject private var windowManager = WindowManager.shared
    @State private var dataStore: DataStore
    @State private var settingsManager: SettingsManager
    @State private var aggregator: UsageAggregator?
    @State private var accountManager: AccountManager
    @State private var cloudSyncService: CloudSyncService?
    @State private var iCloudSessionMirrorService: ICloudSessionMirrorService?
    @State private var periodicRefreshTask: Task<Void, Never>?
    @State private var chatController: ChatSessionController
    @State private var operatingLayer: OpenBurnBarOperatingLayer
    @State private var navigationCoordinator = NavigationCoordinator()

    init() {
        if !OpenBurnBarRuntime.isRunningTests {
            Self.configureFirebaseIfAvailable()
        }
        OpenBurnBarMigration.migrateUserDefaults()
        _ = try? OpenBurnBarMigration.prepareSupportDirectory()

        // Initialize DataStore - this MUST succeed for the app to function
        let initializedStore: DataStore
        do {
            initializedStore = try DataStore()
        } catch {
            fatalError(
                "CRITICAL: Failed to initialize DataStore. The app cannot function without a working database.\n" +
                "Error: \(error.localizedDescription)\n" +
                "This usually indicates:\n" +
                "  - The application support directory is not writable\n" +
                "  - Disk space is exhausted\n" +
                "  - File permissions are incorrect\n" +
                "Please check ~/Library/Application\\ Support/OpenBurnBar/"
            )
        }

        let controller = ChatSessionController(dataStore: initializedStore, settingsManager: SettingsManager.shared)
        let layer = OpenBurnBarOperatingLayer(
            dataStore: initializedStore,
            settingsManager: SettingsManager.shared,
            accountManager: AccountManager.shared,
            chatController: controller
        )

        _dataStore = State(initialValue: initializedStore)
        _settingsManager = State(initialValue: SettingsManager.shared)
        _aggregator = State(initialValue: nil)
        _accountManager = State(initialValue: AccountManager.shared)
        _cloudSyncService = State(initialValue: nil)
        _iCloudSessionMirrorService = State(initialValue: nil)
        _chatController = State(initialValue: controller)
        _operatingLayer = State(initialValue: layer)
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
        FirebaseApp.configure(options: options)
        didConfigureFirebase = true
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        AccountManager.shared.onFirebaseConfigured()
    }

    @MainActor
    private func installCommandRouter() {
        AppCommandRouter.shared.openDashboard = {
            windowManager.openDashboard(
                dataStore: dataStore,
                aggregator: aggregator,
                accountManager: accountManager,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService,
                chatController: chatController,
                operatingLayer: operatingLayer,
                navigationCoordinator: navigationCoordinator
            )
        }

        AppCommandRouter.shared.openConversationSearch = {
            windowManager.openDashboard(
                dataStore: dataStore,
                aggregator: aggregator,
                accountManager: accountManager,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService,
                chatController: chatController,
                operatingLayer: operatingLayer,
                navigationCoordinator: navigationCoordinator
            )

            // Navigation now handled via NavigationCoordinator
            navigationCoordinator.openConversationSearch()
        }
    }

    @SceneBuilder
    private var liveMenuBarScene: some Scene {
        let _ = installCommandRouter()
        MenuBarExtra {
            if OpenBurnBarRuntime.isRunningTests {
                EmptyView()
            } else {
                MenuBarPopoverView(
                    dataStore: dataStore,
                    aggregator: aggregator,
                    quotaService: ProviderQuotaService.shared,
                    settingsManager: settingsManager,
                    operatingLayer: operatingLayer,
                    onOpenDashboard: {
                        windowManager.openDashboard(
                            dataStore: dataStore,
                            aggregator: aggregator,
                            accountManager: accountManager,
                            cloudSyncService: cloudSyncService,
                            iCloudSessionMirrorService: iCloudSessionMirrorService,
                            chatController: chatController,
                            operatingLayer: operatingLayer,
                            navigationCoordinator: navigationCoordinator
                        )
                    },
                    onOpenSettings: {
                        windowManager.openSettings(
                            settingsManager: settingsManager,
                            accountManager: accountManager,
                            cloudSyncService: cloudSyncService,
                            iCloudSessionMirrorService: iCloudSessionMirrorService,
                            dataStore: dataStore
                        )
                    },
                    chatController: chatController,
                    onOpenDashboardWithChat: {
                        windowManager.openDashboard(
                            dataStore: dataStore,
                            aggregator: aggregator,
                            accountManager: accountManager,
                            cloudSyncService: cloudSyncService,
                            iCloudSessionMirrorService: iCloudSessionMirrorService,
                            chatController: chatController,
                            operatingLayer: operatingLayer,
                            navigationCoordinator: navigationCoordinator
                        )
                        // Navigation now handled via NavigationCoordinator
                        navigationCoordinator.openChatPanel()
                    },
                    onOpenOnboardingWizard: {
                        windowManager.openOnboardingWizard(
                            dataStore: dataStore,
                            aggregator: aggregator,
                            settingsManager: settingsManager,
                            chatController: chatController,
                            onOpenDashboard: {
                                windowManager.openDashboard(
                                    dataStore: dataStore,
                                    aggregator: aggregator,
                                    accountManager: accountManager,
                                    cloudSyncService: cloudSyncService,
                                    iCloudSessionMirrorService: iCloudSessionMirrorService,
                                    chatController: chatController,
                                    operatingLayer: operatingLayer,
                                    navigationCoordinator: navigationCoordinator
                                )
                            }
                        )
                    }
                )
            }
        } label: {
            if OpenBurnBarRuntime.isRunningTests {
                EmptyView()
            } else {
                MenuBarLabel(
                    totalCostToday: dataStore.totalCostToday,
                    totalTokensToday: dataStore.totalTokensToday,
                    usageDisplayMode: settingsManager.usageDisplayMode,
                    rollingDailyAverage: dataStore.rollingDailyAverage,
                    isRefreshing: aggregator?.isRefreshing ?? false
                )
                .task {
                    await Task.yield()
                    guard !OpenBurnBarRuntime.isRunningTests else { return }
                    guard aggregator == nil else { return }
                    let sync = CloudSyncService(dataStore: dataStore, accountManager: accountManager)
                    cloudSyncService = sync
                    let mirror = ICloudSessionMirrorService(settingsManager: settingsManager)
                    iCloudSessionMirrorService = mirror
                    let newAggregator = UsageAggregator(dataStore: dataStore, cloudSync: sync, sessionMirror: mirror)
                    aggregator = newAggregator
                    operatingLayer.aggregator = newAggregator
                    operatingLayer.chatController = chatController
                    OpenBurnBarDaemonManager.shared.attach(dataStore: dataStore)
                    CursorConnectorManager.shared.attach(dataStore: dataStore)
                    if !hasShownInitialDashboard {
                        hasShownInitialDashboard = true
                        windowManager.openDashboard(
                            dataStore: dataStore,
                            aggregator: newAggregator,
                            accountManager: accountManager,
                            cloudSyncService: sync,
                            iCloudSessionMirrorService: mirror,
                            chatController: chatController,
                            operatingLayer: operatingLayer,
                            navigationCoordinator: navigationCoordinator
                        )
                    }
                    // Probe Hermes availability in the background
                    Task {
                        let enabledBackends = Set(settingsManager.enabledChatBackends)
                        if enabledBackends.contains(.hermes) || chatController.chatBackend == .hermes {
                            await chatController.probeHermesAvailability()
                        } else {
                            chatController.hermesAvailable = false
                        }
                        if enabledBackends.contains(.openclaw) || chatController.chatBackend == .openclaw {
                            await chatController.probeOpenClawAvailability()
                        } else {
                            chatController.openClawAvailable = false
                        }
                        await OpenBurnBarDaemonManager.shared.refreshHealth()
                        await operatingLayer.refreshControllerRuntime()
                    }
                    // Don't block the first frame on a long disk scan; the menu bar can appear while refresh runs.
                    Task(priority: .userInitiated) {
                        await newAggregator.refreshAll()
                        await sync.uploadPendingConversations()
                        await sync.uploadPendingChatThreads()
                        if settingsManager.dailyDigestEnabled {
                            await DailyDigestManager.shared.requestAuthorization()
                            DailyDigestManager.shared.scheduleDigest(from: dataStore, at: settingsManager.dailyDigestHour)
                        }
                    }
                    periodicRefreshTask?.cancel()
                    periodicRefreshTask = Task(priority: .utility) {
                        while !Task.isCancelled {
                            let seconds = max(settingsManager.refreshInterval, 30)
                            let nanos = UInt64(seconds * 1_000_000_000)
                            try? await Task.sleep(nanoseconds: nanos)
                            if Task.isCancelled { break }
                            await newAggregator.refreshAll()
                            await OpenBurnBarDaemonManager.shared.refreshHealth()
                            await operatingLayer.refreshControllerRuntime()
                        }
                    }
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    var body: some Scene {
        liveMenuBarScene
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

    private static let menuBarLabelSlotWidth: CGFloat = 22
    private static let menuBarLabelSlotHeight: CGFloat = 18

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
