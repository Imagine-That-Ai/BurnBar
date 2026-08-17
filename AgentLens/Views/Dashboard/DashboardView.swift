import AppKit
import OpenBurnBarCore
import SwiftUI
import WebKit

// MARK: - Dashboard View

@MainActor
@Observable
final class DashboardSettingsPresentation {
    var isPresented = false
    private(set) var itemID: String?

    func present(itemID: String? = nil) {
        self.itemID = itemID
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        itemID = nil
    }
}

struct DashboardView: View {
    @Bindable var dataStore: DataStore
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    @Bindable var settingsManager: SettingsManager
    @Environment(NavigationCoordinator.self) var navigationCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var easterEggController = EasterEggController()
    @State private var didLogScreenView = false
    var aggregator: UsageAggregator?
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?
    var runtimeContext: OpenBurnBarRuntimeContext?
    @State var consentCoordinator: DashboardConsentCoordinator?
    /// The launch surface. Home is the root: the inbox is the only screen that
    /// turns the fleet/quota/corpus signals into a next move, so it is what the
    /// window opens on. Users who want the old spend-first landing flip
    /// `AppearanceSettings.dashboardLaunchSurface`.
    @State var mainRoute: DashboardMainRoute = DashboardLaunchSurface.current.route
    @State var fleetService = FleetService(socketURL: OpenBurnBarDaemonRuntimePaths.live().socketURL)
    /// True while Fleet asked for orchestrator chat and the CLI consent sheet
    /// is still outstanding. Deny must not open chat; allow must.
    @State private var pendingOpenOrchestratorChat = false
    @State var routeHistory: [DashboardMainRoute] = []
    @State var selectedTimeRange: TimeRange = .today
    @AppStorage("dashboardViewMode") var viewMode: DashboardViewMode = .agents
    @AppStorage("dashboardViewMode") var storedViewMode: DashboardViewMode = .agents
    @State var settingsPresentation = DashboardSettingsPresentation()
    @State var showProgressPanel = false
    @State var overviewAppeared = false
    @State private var overviewEmptyStateAppeared = false
    @State var deviceCount = 0
    @State var sidebarAppeared = false
    @State var chatPanelOpen = false
    @State private var showIndexingConsent = false
    @State private var showAnalyticsConsent = false
    @State private var showCLIConsentSheet = false
    @State private var showSessionLogCloudConsent = false
    @State var sessionLogJumpTarget: ConversationJumpTarget?
    @State var dashboardCanvasSize: CGSize = .zero
    @State private var overviewUsesStackedLanes = false
    @State private var overviewViewportHeight: CGFloat = 0
    @State var burnRailDelta: Double?
    @State var burnRailDeltaRequestID: String?
    private static let overviewScrollSpace = "dashboardOverviewScroll"
    @State var didAutoExpandEmptyTimeRange = false
    @State var showContextPackSheet = false
    @AppStorage("dashboardChatPreferMaximized") var preferMaximizedChat = false
    @AppStorage(KernelBackdropPreferences.enabledKey) private var useKernelBackdrop: Bool = false
    /// Last profile the live backdrop measured and published, or `nil` before
    /// its first publish.
    ///
    /// Deliberately optional rather than seeded with a constant: a constant
    /// seed is wrong for whichever skin it does not describe. Editorial/paper
    /// counts as a live backdrop and paints a *light* canvas immediately, so a
    /// `darkCanvasFallback` seed applied white foregrounds over white paper for
    /// every frame before `DashboardBackdrop`'s `.task` published
    /// `.lightCanvasFallback`. While this is `nil`,
    /// `dashboardActiveReadabilityProfile` resolves the skin-aware
    /// `BackdropReadabilityProfile.nativeFallback(...)` synchronously instead,
    /// so the first frame already has the right foreground family.
    @State private var backdropReadabilityProfile: BackdropReadabilityProfile?
    var chatController: ChatSessionController
    @State var quotaService = ProviderQuotaService.shared
    @State var missionConsoleController: MissionConsoleWindowController?
    /// Internal, not private: the Control Deck's Wand tile presents this same
    /// composer from `DashboardView+ControlDeck.swift`, so the app has one
    /// cast surface with one set of approval switches rather than two.
    @State var showMacWandComposer = false
    /// The Control Deck's cached facts, owned here rather than by the route
    /// view: route views carry `.id(mainRoute)` and are rebuilt on every visit,
    /// so a model held there would flash "—" each time you came back. Internal,
    /// not private — `DashboardView+ControlDeck.swift` hands it to the deck.
    @State var controlDeckModel = ControlDeckModel()
    /// The inbox shelf (pins, tags, categories, manual order).
    ///
    /// Held here rather than as a global because the models below are rebuilt
    /// on every body evaluation, and the shelf coalesces its writes on a timer:
    /// a store discarded mid-debounce loses the write. `@State` gives it a
    /// lifetime tied to this view instead of to the process.
    @State private var inboxShelf = InboxShelfStore()

    /// Fleet liveness for the Home rail.
    ///
    /// Owned here rather than by `DashboardHomeView` so the watchers keep
    /// running while the user is on another route — the panel should be warm
    /// the instant they come back, not start from "not watched".
    @State private var fleetModel = LiveFleetModel()
    @State private var fleetWatcher: ProviderSessionActivityWatcher?
    /// The inbox model Home shares with the focused route. Built once so
    /// switching between them does not reset selection or re-query.
    @State private var homeInboxModel: InboxModel?

    @State var pendingMemoryReviewCount: Int?
    /// Unread AI Inbox items, shown as a badge on the section switcher. Nil until
    /// the first read, so a profile whose daemon has never run shows no badge
    /// rather than a misleading zero.
    @State var aiInboxUnreadCount: Int?
    /// Item id from a tapped notification deep link, consumed once by the Inbox
    /// surface so it opens on that item instead of the newest one.
    @State var pendingInboxItemID: String?
    @State var showCommandPalette = false
    @State var showHeroPopover = false
    @State private var dashboardSplitVisibility: NavigationSplitViewVisibility = .all
    /// Non-nil only while the user has manually overridden the sidebar for the
    /// current route. Cleared on navigation so each route starts from its default.
    @State private var sidebarVisibilityOverride: Bool?
    @AppStorage("dashboard.statusRail.height") var storedDashboardStatusRailHeight = 52.0
    @State var dashboardStatusRailResizeOrigin: Double?

    init(
        dataStore: DataStore,
        aggregator: UsageAggregator?,
        accountManager: AccountManager = .shared,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil,
        chatController: ChatSessionController,
        operatingLayer: OpenBurnBarOperatingLayer,
        settingsManager: SettingsManager,
        runtimeContext: OpenBurnBarRuntimeContext? = nil
    ) {
        self._dataStore = Bindable(dataStore)
        self._operatingLayer = Bindable(operatingLayer)
        self._settingsManager = Bindable(settingsManager)
        self.aggregator = aggregator
        self.accountManager = accountManager
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
        self.runtimeContext = runtimeContext
        self.chatController = chatController
        self._consentCoordinator = State(initialValue: DashboardConsentCoordinator(
            settingsManager: settingsManager,
            accountManager: accountManager
        ))
    }

    init(context: DashboardContext) {
        self.init(
            dataStore: context.dataStore,
            aggregator: context.aggregator,
            accountManager: context.accountManager,
            cloudSyncService: context.cloudSyncService,
            iCloudSessionMirrorService: context.iCloudSessionMirrorService,
            chatController: context.chatController,
            operatingLayer: context.operatingLayer,
            settingsManager: context.settingsManager,
            runtimeContext: context.runtimeContext
        )
    }

    var showingSettings: Bool { settingsPresentation.isPresented }
    var pendingSettingsItemID: String? { settingsPresentation.itemID }

    func presentSettings(itemID: String? = nil) {
        settingsPresentation.present(itemID: itemID)
    }

    var isScanning: Bool { aggregator?.isRefreshing ?? false }

    /// Changing the range invalidates the comparison query, not the cached
    /// current-window summary. Keep the comparison result in view state so the
    /// database worker can finish without blocking view construction.
    var burnRailDeltaTaskID: String {
        "\(selectedTimeRange.rawValue)|\(dataStore.usagesVersion)|\(settingsManager.usageDisplayMode.rawValue)"
    }

    func loadBurnRailDelta() async -> Double? {
        guard let current = selectedTimeRange.dateRange() else { return nil }
        let span = current.upperBound.timeIntervalSince(current.lowerBound)
        guard span > 0 else { return nil }

        let previous = current.lowerBound.addingTimeInterval(-span)...current.lowerBound
        guard let previousTotals = await dataStore.usageTotals(in: previous) else { return nil }

        let currentMetric: Double
        let previousMetric: Double
        switch settingsManager.usageDisplayMode {
        case .currency:
            currentMetric = dashboardUsageWindow.totalCost
            previousMetric = previousTotals.cost
        case .tokens:
            currentMetric = Double(dashboardUsageWindow.totalTokens)
            previousMetric = Double(previousTotals.tokens)
        }

        guard previousMetric > 0 else { return nil }
        return ((currentMetric - previousMetric) / previousMetric) * 100.0
    }

    var canRunRecount: Bool { aggregator != nil && !isScanning }

    func runScan() {
        guard let agg = aggregator else { return }
        Analytics.shared.track(.dashboardScanRun)
        Task { await agg.refreshAll() }
    }

    func runRecount() {
        guard let agg = aggregator else { return }
        Analytics.shared.track(.dashboardRecountRun)
        Task { await agg.recountAll() }
    }

    var isDashboardSidebarVisible: Bool {
        dashboardSplitVisibility != .detailOnly
    }

    /// Routes whose content is *about* the provider/model breakdown the sidebar
    /// renders. Workspaces that own a full-width layout (or their own left rail,
    /// like Session Logs) would otherwise show a third redundant column.
    static func routeWantsProviderSidebar(_ route: DashboardMainRoute) -> Bool {
        switch route {
        case .overview, .insights, .charts, .provider, .model:
            return true
        case .home, .database, .projects, .missions, .sessionLogs, .memoryReview, .inbox, .chat,
             .quota, .controlDeck, .fleet:
            // The Control Deck is a full-width workspace like Inbox and Quota:
            // it is *not* about the provider/model breakdown, so the provider
            // rail would be a third redundant column.
            //
            // Home owns its own right rail, so a provider column would make it
            // a fourth vertical band — and at the 1040pt window minimum there
            // is not room for a third, let alone a fourth.
            return false
        }
    }

    /// Sidebar visibility the current route asks for, unless the user has
    /// explicitly overridden it for that route via the toggle.
    var resolvedSidebarVisibility: NavigationSplitViewVisibility {
        if let override = sidebarVisibilityOverride {
            return override ? .all : .detailOnly
        }
        return Self.routeWantsProviderSidebar(mainRoute) ? .all : .detailOnly
    }

    func toggleDashboardSidebar() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignSystem.Animation.snappy) {
            sidebarVisibilityOverride = !isDashboardSidebarVisible
            dashboardSplitVisibility = resolvedSidebarVisibility
        }
    }

    /// Re-derives sidebar visibility after a route change. The manual override
    /// is per-route, so navigating away clears it.
    func syncSidebarVisibility(for route: DashboardMainRoute, previous: DashboardMainRoute) {
        guard route != previous else { return }
        sidebarVisibilityOverride = nil
        let target = Self.routeWantsProviderSidebar(route) ? NavigationSplitViewVisibility.all : .detailOnly
        guard target != dashboardSplitVisibility else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignSystem.Animation.snappy) {
            dashboardSplitVisibility = target
        }
    }

    var canGoBack: Bool {
        !routeHistory.isEmpty || mainRoute != .home
    }

    func navigate(to route: DashboardMainRoute) {
        guard route != mainRoute else { return }
        routeHistory.append(mainRoute)
        mainRoute = route
    }

    func goBack() {
        if let previous = routeHistory.popLast() {
            mainRoute = previous
        } else if mainRoute != .home {
            mainRoute = .home
        }
    }

    /// Applies an externally requested route (deep links like
    /// `openburnbar://charts` via `NavigationCoordinator`) and clears it so
    /// the request fires exactly once.
    func consumeCoordinatorDashboardRoute() {
        guard let pending = navigationCoordinator.dashboardRoute else { return }
        navigationCoordinator.dashboardRoute = nil
        let route: DashboardMainRoute
        switch pending {
        case .home: route = .home
        case .overview: route = .overview
        case .charts: route = .charts
        case .database: route = .database
        case .projects: route = .projects
        case .sessionLogs: route = .sessionLogs
        case .chat: route = .chat
        case .quota: route = .quota
        case .inbox(let itemID):
            route = .inbox
            // Carried through so a tapped notification opens the exact item.
            pendingInboxItemID = itemID
        }
        withAnimation(DesignSystem.Animation.standard) {
            navigate(to: route)
        }
    }

    var backButtonHelpText: String {
        if let previous = routeHistory.last {
            return "Back to \(routeTitle(previous))"
        }
        return "Back to Home"
    }

    func routeTitle(_ route: DashboardMainRoute) -> String {
        switch route {
        case .home: return "Home"
        case .overview: return "Overview"
        case .insights: return "Insights"
        case .charts: return "Charts"
        case .database: return "Database"
        case .projects: return "Projects"
        case .missions: return "Missions"
        case .sessionLogs: return "Session Logs"
        case .memoryReview: return "Memory"
        case .inbox: return "Inbox"
        case .chat: return "Chat"
        case .quota: return "Quota"
        case .controlDeck: return "Control Deck"
        case .fleet: return "Fleet"
        case .provider(let provider): return provider.displayName
        case .model(let modelName): return modelName
        }
    }

    func openBurnBarCursorExtension() {
        let id = "openburnbar.openburnbar"
        let candidates = [
            URL(string: "cursor:extension/\(id)"),
            URL(string: "vscode:extension/\(id)")
        ].compactMap { $0 }
        for url in candidates where NSWorkspace.shared.open(url) {
            return
        }
    }

    #if DEBUG
    func testTriggerNavigate(to route: DashboardMainRoute) {
        navigate(to: route)
    }

    func testTriggerGoBack() {
        goBack()
    }

    func testTriggerScan() {
        Task { await aggregator?.refreshAll() }
    }

    func testTriggerRecount() {
        Task { await aggregator?.recountAll() }
    }
    #endif

    var body: some View {
        @Bindable var chatController = chatController
        let activeReadabilityProfile = dashboardActiveReadabilityProfile
        let adaptiveColors = BackdropAdaptiveColors(profile: activeReadabilityProfile)
        return VStack(spacing: 0) {
            dashboardCommandDeck

            NavigationSplitView(columnVisibility: $dashboardSplitVisibility) {
                sidebarView
                    // Contrast override for the sidebar's controls and text.
                    // The sidebar's own `DashboardBackdrop` must NOT inherit it
                    // — it is handed `dashboardKernelColorScheme` explicitly so
                    // its kernel WKWebView renders the same palette as the main
                    // backdrop instead of one derived from the sampled profile.
                    .environment(
                        \.colorScheme,
                        dashboardLiveBackdropActive
                            ? activeReadabilityProfile.interfaceColorScheme
                            : colorScheme
                    )
                    .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 235)
                    .background(dashboardLiveBackdropActive ? Color.clear : DesignSystem.Colors.background)
            } detail: {
                detailView
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar(removing: .sidebarToggle)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 22,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 22,
                    style: .continuous
                ),
                style: FillStyle(antialiased: true)
            )
        }
        .background {
            DashboardBackdrop(
                moodBand: dataStore.moodBand,
                kernelColorScheme: dashboardKernelColorScheme,
                onReadabilityChange: { profile in
                    guard dashboardLiveBackdropActive else { return }
                    backdropReadabilityProfile = profile
                }
            )
            if dashboardLiveBackdropActive {
                adaptiveColors.scrim
                    .opacity(dashboardAdaptiveScrimOpacity)
                    .allowsHitTesting(false)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.22),
                        value: activeReadabilityProfile
                    )
            }
            DashboardSidebarToolbarItemRemover()
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        dashboardCanvasSize = geo.size
                    }
                    .onChange(of: geo.size) { _, newSize in
                        dashboardCanvasSize = newSize
                    }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: mainRoute) { previous, route in
            syncSidebarVisibility(for: route, previous: previous)
        }
        // A published profile describes one specific backdrop. When the skin,
        // the live-backdrop toggles, or the app appearance change, it no longer
        // does — drop it so the skin-aware native fallback covers the frames
        // until `DashboardBackdrop`'s `.task(id:)` republishes for the new
        // canvas, instead of e.g. carrying an aurora dark profile into paper.
        .onChange(of: dashboardReadabilityContextID) { _, _ in
            backdropReadabilityProfile = nil
        }
        .onAppear {
            dashboardSplitVisibility = resolvedSidebarVisibility
            autoExpandTimeRangeIfNeeded()
            if missionConsoleController == nil {
                missionConsoleController = MissionConsoleWindowController.bind(to: operatingLayer)
            }
            Task { await refreshPendingMemoryReviewCount() }
            Task { await refreshAIInboxUnreadCount() }
            consumeCoordinatorDashboardRoute()
        }
        .onChange(of: navigationCoordinator.dashboardRoute) { _, _ in
            consumeCoordinatorDashboardRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.inboxBadgeRefreshNotification)) { _ in
            // The daemon writes inbox rows in another process, so there is no
            // local mutation to react to. The shared background cadence posts
            // this after each pass; the badge query is a single COUNT.
            Task { await refreshAIInboxUnreadCount() }
        }
        .task(id: burnRailDeltaTaskID) {
            let requestID = burnRailDeltaTaskID
            burnRailDelta = nil
            let result = await loadBurnRailDelta()
            guard !Task.isCancelled, requestID == burnRailDeltaTaskID else { return }
            burnRailDeltaRequestID = requestID
            burnRailDelta = result
        }
        .onChange(of: dataStore.totalUsageSessionCount) { _, _ in
            autoExpandTimeRangeIfNeeded()
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 12) {
                if mainRoute != .chat {
                    if chatPanelOpen {
                        ChatPanel(
                            controller: chatController,
                            dataStore: dataStore,
                            settingsManager: settingsManager,
                            sharedFeaturesAvailable: accountManager.isSignedIn,
                            containerSize: dashboardCanvasSize,
                            edgePadding: 20,
                            onOpenConversationJump: { target in
                                sessionLogJumpTarget = target
                                if mainRoute != .sessionLogs {
                                    navigate(to: .sessionLogs)
                                }
                            },
                            onMaximize: {
                                preferMaximizedChat = true
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    chatPanelOpen = false
                                    navigate(to: .chat)
                                }
                            },
                            onPopOut: {
                                WindowManager.shared.openChatPopOutWindow(
                                    controller: chatController,
                                    dataStore: dataStore,
                                    settingsManager: settingsManager,
                                    accountManager: accountManager
                                )
                            },
                            onClose: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    chatPanelOpen = false
                                    UserDefaults.standard.set(dataStore.totalUsageSessionCount, forKey: "lastSeenSessionCountForChatBadge")
                                }
                            }
                        )
                        .offset(x: chatController.panelFloatOffset.width, y: chatController.panelFloatOffset.height)
                        .accessibilityIdentifier(OBBAccessibilityID.chatPanel)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                    if !chatPanelOpen {
                        if let controller = missionConsoleController {
                            MissionFAB(host: controller.host) {
                                controller.makeOrShow()
                            } onCastWand: {
                                showMacWandComposer = true
                            }
                        }
                        ChatFAB(hasNewInsights: hasNewInsightPulse) {
                            if !settingsManager.cliAssistantConsentShown {
                                showCLIConsentSheet = true
                                return
                            }
                            Task { await chatController.cliBridge.detect() }
                            if preferMaximizedChat {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    navigate(to: .chat)
                                }
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    chatPanelOpen = true
                                }
                            }
                        }
                    }
                }
            }
            .fixedSize()
            .padding(EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20))
        }
        .accessibilityIdentifier(OBBAccessibilityID.dashboardRoot)
        .background {
            sectionShortcuts
            controlDeckShortcut
            homeShortcut
            railToggleShortcut
            commandPaletteShortcut
            fleetSleepObservers
        }
        .sheet(isPresented: $showCommandPalette) {
            CommandDeckPalette(
                activeChatBackend: chatController.chatBackend,
                searchService: chatController.typedSearchService,
                onNavigate: { route in
                    withAnimation(DesignSystem.Animation.standard) {
                        navigate(to: route)
                    }
                },
                onSessionJump: { target in
                    sessionLogJumpTarget = target
                    if mainRoute != .sessionLogs {
                        navigate(to: .sessionLogs)
                    }
                }
            )
        }
        .sheet(
            isPresented: $settingsPresentation.isPresented,
            onDismiss: { settingsPresentation.dismiss() },
            content: {
                SettingsView(
                    settingsManager: settingsManager,
                    accountManager: accountManager,
                    cloudSyncService: cloudSyncService,
                    iCloudSessionMirrorService: iCloudSessionMirrorService,
                    dataStore: dataStore,
                    runtimeContext: runtimeContext,
                    chatController: chatController,
                    initialItemID: settingsPresentation.itemID
                )
            }
        )
        .onAppear {
            if !settingsManager.conversationIndexingConsentShown {
                showIndexingConsent = true
            }
        }
        .alert("Index conversation history?", isPresented: $showIndexingConsent) {
            Button("Enable") {
                settingsManager.conversationIndexingEnabled = true
                settingsManager.conversationIndexingConsentShown = true
                Task { await aggregator?.refreshAll() }
            }
            Button("Not now", role: .cancel) {
                settingsManager.conversationIndexingEnabled = false
                settingsManager.conversationIndexingConsentShown = true
            }
        } message: {
            Text("OpenBurnBar can index your conversation history for search and chat. This data stays on your Mac.")
        }
        .sheet(isPresented: $showCLIConsentSheet, onDismiss: handleFleetChatConsentDismissed) {
            CLIAssistantConsentSheet(settingsManager: settingsManager) {
                showCLIConsentSheet = false
            }
            .presentationBackground(Material.ultraThinMaterial)
        }
        .sheet(isPresented: $showSessionLogCloudConsent) {
            SessionLogCloudConsentSheet(settingsManager: settingsManager) {
                showSessionLogCloudConsent = false
            }
            .presentationBackground(Material.ultraThinMaterial)
        }
        .sheet(isPresented: Binding(
            get: { consentCoordinator?.showMemoryConsent ?? false },
            set: { consentCoordinator?.showMemoryConsent = $0 }
        )) {
            MemoryConsentSheet { grant in
                consentCoordinator?.confirmMemoryConsent(grant: grant)
                consentCoordinator?.showMemoryConsent = false
            }
            .presentationBackground(Material.ultraThinMaterial)
        }
        .sheet(isPresented: $showAnalyticsConsent) {
            AnalyticsConsentPromptView { granted in
                if granted {
                    AnalyticsConsentStore.shared.grant()
                    Analytics.shared.consentDidChange()
                } else {
                    AnalyticsConsentStore.shared.decline()
                }
                showAnalyticsConsent = false
            }
            .presentationBackground(Material.ultraThinMaterial)
        }
        .sheet(isPresented: $showMacWandComposer) {
            MacWandComposerSheet(accountManager: accountManager) { _ in
                Task { await missionConsoleController?.host.refresh() }
            }
            .presentationBackground(Material.ultraThinMaterial)
        }
        .onAppear {
            presentAnalyticsConsentIfNeeded()
            presentMemoryConsentIfNeeded()
        }
        .onChange(of: showIndexingConsent) { wasShowing, isShowing in
            if wasShowing && !isShowing {
                presentAnalyticsConsentIfNeeded()
                presentMemoryConsentIfNeeded()
            }
        }
        .onChange(of: showAnalyticsConsent) { wasShowing, isShowing in
            if wasShowing && !isShowing {
                presentMemoryConsentIfNeeded()
            }
        }
        .onChange(of: accountManager.isSignedIn) { _, isSignedIn in
            chatController.refreshRetrievalHealth(sharedFeaturesAvailable: isSignedIn)
            if isSignedIn && !settingsManager.sessionLogCloudBackupConsentShown {
                showSessionLogCloudConsent = true
            }
        }
        .onChange(of: navigationCoordinator.pendingNavigation) { _, destination in
            guard let destination else { return }
            switch destination {
            case .conversationSearch, .chatPanel:
                if preferMaximizedChat {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        navigate(to: .chat)
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        chatPanelOpen = true
                    }
                }
            case .chatPopOut:
                WindowManager.shared.openChatPopOutWindow(
                    controller: chatController,
                    dataStore: dataStore,
                    settingsManager: settingsManager,
                    accountManager: accountManager
                )
            default:
                break
            }
            navigationCoordinator.clearPendingNavigation()
        }
        .onChange(of: navigationCoordinator.chatPanelOpen) { _, isOpen in
            guard isOpen, !chatPanelOpen else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                chatPanelOpen = true
            }
        }
        .openBurnBarPreferredColorScheme(settingsManager.preferredSwiftUIColorScheme)
        .environment(\.backdropReadabilityProfile, activeReadabilityProfile)
        .environment(\.dashboardLiveBackdropActive, dashboardLiveBackdropActive)
        // Resolved once, here, so every route below draws with ink that clears
        // 4.5:1 against whatever the kernel is currently painting. Routes that
        // reached for `DesignSystem.Colors.text*` directly were readable on a
        // static canvas and invisible the moment a backdrop was switched on —
        // `textMuted` in particular cannot clear the bar on any canvas this app
        // draws. See `Theme/BackdropLegibleSurface.swift`.
        .environment(
            \.backdropInk,
            BackdropInk.resolve(
                liveBackdropActive: dashboardLiveBackdropActive,
                profile: activeReadabilityProfile
            )
        )
        .environment(settingsManager)
    }

    // MARK: - Hidden keyboard shortcuts

    /// Window-level ⌘1–⌘7 for primary sections. Zero-size, non-interactive
    /// buttons so the shortcut fires regardless of focus but the views are
    /// never visible. Mirrors the proven `globalShortcut` pattern from
    /// `BurnBarTopRail.swift`.
    @ViewBuilder
    private var sectionShortcuts: some View {
        ForEach(Array(DashboardMainRoute.primarySections.enumerated()), id: \.element) { index, route in
            Button {
                withAnimation(DesignSystem.Animation.standard) {
                    navigate(to: route)
                }
            } label: {
                EmptyView()
            }
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }

    /// Hidden ⌘0 for the Control Deck. Deliberately *outside* the ⌘1–⌘8
    /// `primarySections` range, which is positional — inserting the deck into
    /// that array would renumber every existing user's shortcuts.
    private var controlDeckShortcut: some View {
        Button {
            withAnimation(DesignSystem.Animation.standard) {
                navigate(to: .controlDeck)
            }
        } label: {
            EmptyView()
        }
        .keyboardShortcut("0", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    /// Hidden ⌘⇧H for Home.
    ///
    /// Outside the ⌘1–⌘8 range for the same reason ⌘0 is: `primarySections` is
    /// positional, and putting Home in it would shift Inbox to ⌘2 and push
    /// Memory off the end of every existing user's keyboard.
    private var homeShortcut: some View {
        Button {
            withAnimation(DesignSystem.Animation.standard) {
                navigate(to: .home)
            }
        } label: {
            EmptyView()
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    /// Hidden ⌘⌥R to show/hide Home's fleet + quota rail.
    private var railToggleShortcut: some View {
        Button {
            guard mainRoute == .home else { return }
            let key = DashboardHomeRailMetrics.collapsedStorageKey
            let collapsed = UserDefaults.standard.bool(forKey: key)
            UserDefaults.standard.set(!collapsed, forKey: key)
        } label: {
            EmptyView()
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    /// Hidden ⌘K to open the Command Palette from anywhere in the window.
    private var commandPaletteShortcut: some View {
        Button {
            showCommandPalette = true
        } label: {
            EmptyView()
        }
        .keyboardShortcut("k", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    // MARK: - Detail View

    @ViewBuilder
    var detailView: some View {
        Group {
                switch mainRoute {
                case .home:
                    homeView
                case .overview:
                    overviewRouteView
                case .insights:
                    MacAgentInsightsWorkspace(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        chatController: chatController
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .charts:
                    ChartsPageView(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        chatController: chatController,
                        selectedTimeRange: $selectedTimeRange,
                        onOpenSessionLog: { conversationID in
                            // Same landing the inbox uses: resolve a jump target
                            // so the click opens the session, then navigate.
                            Task { @MainActor in
                                let resolver = InboxConversationJumpResolver(dataStore: dataStore)
                                sessionLogJumpTarget = await resolver.jumpTarget(conversationID: conversationID)
                                navigate(to: .sessionLogs)
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .database:
                    DatabaseWorkspaceView(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        accountManager: accountManager,
                        cloudSyncService: cloudSyncService
                    )
                case .projects:
                    ProjectsView(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        operatingLayer: operatingLayer,
                        chatController: chatController
                    )
                case .missions:
                    MissionsLaneView(
                        operatingLayer: operatingLayer,
                        onOpenSessionLogs: {
                            withAnimation(DesignSystem.Animation.standard) {
                                navigate(to: .sessionLogs)
                            }
                        }
                    )
                case .sessionLogs:
                    SessionLogsView(
                        dataStore: dataStore,
                        accountManager: accountManager,
                        settingsManager: settingsManager,
                        operatingLayer: operatingLayer,
                        cloudSyncService: cloudSyncService,
                        iCloudMirrorService: iCloudSessionMirrorService,
                        jumpTarget: sessionLogJumpTarget,
                        preferredChatModelKey: chatController.hermesModelName
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .memoryReview:
                    memoryReviewView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .inbox:
                    inboxView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .chat:
                    DashboardChatWorkspaceView(
                        controller: chatController,
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        sharedFeaturesAvailable: accountManager.isSignedIn,
                        mode: .embedded,
                        onOpenConversationJump: { target in
                            sessionLogJumpTarget = target
                            if mainRoute != .sessionLogs {
                                navigate(to: .sessionLogs)
                            }
                        },
                        onPopOut: {
                            WindowManager.shared.openChatPopOutWindow(
                                controller: chatController,
                                dataStore: dataStore,
                                settingsManager: settingsManager,
                                accountManager: accountManager
                            )
                        },
                        onRestoreFloating: {
                            preferMaximizedChat = false
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                goBack()
                                chatPanelOpen = true
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .quota:
                    QuotaWorkspaceView(
                        dataStore: dataStore,
                        quotaService: quotaService,
                        settingsManager: settingsManager,
                        onOpenConnections: {
                            UserDefaults.standard.set(SettingsTab.agents.rawValue, forKey: "settings.pendingTab")
                            presentSettings()
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .controlDeck:
                    controlDeckRouteView
                case .fleet:
                    FleetView(
                        service: fleetService,
                        tokenBurnProvider: { agentID in
                            FleetTokenBurnEstimator.estimateTokensPerMinute(
                                usages: dataStore.usages,
                                agentID: agentID
                            )
                        },
                        onOpenOrchestratorChat: openOrchestratorChat
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .provider(let provider):
                    ProviderDashboardView(
                        provider: provider,
                        dataStore: dataStore,
                        timeRange: selectedTimeRange,
                        onOpenSessionLog: openSessionLogs
                    )
                case .model(let modelName):
                    ModelDashboardView(
                        modelName: modelName,
                        dataStore: dataStore,
                        timeRange: selectedTimeRange,
                        onOpenSessionLog: openSessionLogs
                    )
                }
            }
            // Route views are heavily scroll-based. Give each route a fresh identity so macOS
            // does not restore a stale NSScrollView offset from the previously visible pane.
            .id(mainRoute)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let agg = aggregator, agg.isSummarizing {
                SummarizingStatusStrip(
                    done: agg.summaryProgressDone,
                    total: agg.summaryProgressTotal,
                    currentTitle: agg.summaryCurrentTitle,
                    completedProviders: Array(Set(agg.summaryQueue.compactMap(\.provider))).sorted(),
                    onTap: { showProgressPanel = true }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(DesignSystem.Animation.standard, value: aggregator?.isSummarizing)
        .sheet(isPresented: $showProgressPanel) {
            if let agg = aggregator {
                SummaryProgressPanel(aggregator: agg)
            }
        }
        .sheet(isPresented: $showContextPackSheet) {
            ContextPackSheet(
                dataStore: dataStore,
                anchorSessionId: nil,
                anchorProject: nil,
                dateRange: selectedTimeRange.dateRange()
            )
        }
    }

    // MARK: - View helpers

    private func presentAnalyticsConsentIfNeeded() {
        guard !AnalyticsConsentStore.shared.hasDecided,
              !showIndexingConsent,
              !showCLIConsentSheet,
              !showSessionLogCloudConsent else { return }
        showAnalyticsConsent = true
    }

    /// Presents the first-run memory consent once every other first-run sheet has
    /// settled, so the permission moments never stack. Memory consent is the last
    /// link in the chain: it waits for the indexing prompt, the CLI/cloud sheets,
    /// and the analytics decision before surfacing.
    private func presentMemoryConsentIfNeeded() {
        guard let consentCoordinator,
              consentCoordinator.shouldShowMemoryConsent,
              !consentCoordinator.showMemoryConsent,
              !showIndexingConsent,
              !showCLIConsentSheet,
              !showSessionLogCloudConsent,
              !showAnalyticsConsent,
              AnalyticsConsentStore.shared.hasDecided else { return }
        consentCoordinator.showMemoryConsent = true
    }

    private func autoExpandTimeRangeIfNeeded() {
        guard !didAutoExpandEmptyTimeRange else { return }
        defer { didAutoExpandEmptyTimeRange = true }
        let currentRangeEmpty = dataStore.usageWindowSummary(for: selectedTimeRange).sessionCount == 0
        let allTimeEmpty = dataStore.totalUsageSessionCount == 0
        if currentRangeEmpty, !allTimeEmpty {
            selectedTimeRange = .allTime
        }
    }

    // MARK: - Memory Review

    /// First-class Memory Review destination. The inbox is the human approval gate
    /// for extracted memories. The closures bind directly to the SHARED
    /// `ControlPlaneStore` published on the runtime context; when that store is not
    /// yet wired (e.g. the test-stub scene), we render a graceful unavailable state
    /// mirroring how other routes degrade on a missing dependency.
    @ViewBuilder
    private var memoryReviewView: some View {
        if let store = runtimeContext?.chatMemoryStore {
            MemoryReviewInboxHost(
                store: store,
                scope: memoryReviewScope,
                afterStatusChange: {
                    await refreshPendingMemoryReviewCount()
                    // Any status change can revoke an already-exported inbox
                    // memory. The export is a FULL-SET replacement, so pushing
                    // after every change makes revocation propagate to the
                    // daemon by omission — without this, a rejected fact keeps
                    // entering model prompts until the next unrelated approval.
                    if let store = runtimeContext?.chatMemoryStore {
                        await InboxMemoryExportService(
                            store: store,
                            scope: memoryReviewScope,
                            socketURL: OpenBurnBarDaemonRuntimePaths.live().socketURL
                        ).pushApprovedSnippets()
                    }
                }
            )
            .id(ObjectIdentifier(store))
        } else {
            ContentUnavailableView(
                "Memory is unavailable",
                systemImage: "brain.head.profile",
                description: Text("The memory store is not ready yet. It activates once OpenBurnBar finishes starting up.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dashboardLiveBackdropActive ? Color.clear : DesignSystem.Colors.background)
        }
    }

    /// Chat-memory extraction writes app-scoped quarantined rows. The review inbox
    /// must read that same bucket so signed-in users can approve extracted memories.
    private var memoryReviewScope: MemoryScope {
        MemoryScope(appID: "openburnbar")
    }

    /// The AI Inbox destination.
    ///
    /// Rows are written by the daemon into the shared database, so this reads
    /// straight through `DataStore` rather than round-tripping the socket — the
    /// surface renders instantly even while the daemon is restarting.
    ///
    /// The memory-approval handler is bound to the SAME scope the Memory review
    /// surface uses, so a fact approved from the inbox is visible and revocable
    /// there too rather than living in a parallel bucket.
    /// Builds the inbox view model.
    ///
    /// Extracted so the Home surface and the focused `.inbox` route construct
    /// the *same* nine closures. Two call sites building this inline is how the
    /// two surfaces silently drift — one gaining a capability the other lacks.
    func makeInboxModel() -> InboxModel {
        InboxModel(
            loadRows: { [dataStore] states in
                try await dataStore.fetchAIInboxRows(states: states)
            },
            loadMarker: { [dataStore] in try await dataStore.aiInboxChangeMarker() },
            markRead: { [dataStore] id in try await dataStore.markAIInboxItemRead(id: id) },
            markUnread: { [dataStore] id in try await dataStore.markAIInboxItemUnread(id: id) },
            setArchived: { [dataStore] id, archived in
                try await dataStore.setAIInboxItemArchived(id: id, archived: archived)
            },
            snooze: { [dataStore] id, until in
                try await dataStore.snoozeAIInboxItem(id: id, until: until)
            },
            setFeedback: { [dataStore] id, feedback in
                try await dataStore.setAIInboxItemFeedback(id: id, feedback: feedback)
            },
            markAllRead: { [dataStore] in try await dataStore.markAllAIInboxItemsRead() },
            loadRuns: { [dataStore] in try await dataStore.fetchAIInboxRuns() },
            shelf: inboxShelf
        )
    }

    /// Opens a cited conversation at the passage that justified the item.
    ///
    /// Shared by the focused inbox and the Home surface. If the conversation is
    /// no longer indexed we still navigate — going nowhere reads as a broken
    /// link.
    func openInboxSessionLog(conversationID: String) {
        Task { @MainActor in
            let resolver = InboxConversationJumpResolver(dataStore: dataStore)
            sessionLogJumpTarget = await resolver.jumpTarget(conversationID: conversationID)
            navigate(to: .sessionLogs)
        }
    }

    /// The memory-approval handler, bound to the SAME scope the Memory review
    /// surface uses so a fact approved from the inbox is visible and revocable
    /// there rather than living in a parallel bucket.
    func makeInboxMemoryApproval() -> InboxMemoryApprovalHandler? {
        runtimeContext?.chatMemoryStore.map { store in
            InboxMemoryApprovalHandler(
                store: store,
                scope: memoryReviewScope,
                // After each approval, push the refreshed approved-snippet set
                // to the daemon so the next tick can cite the fact (L21).
                // Best-effort: approval never fails on daemon-down.
                exporter: { [memoryReviewScope] in
                    await InboxMemoryExportService(
                        store: store,
                        scope: memoryReviewScope,
                        socketURL: OpenBurnBarDaemonRuntimePaths.live().socketURL
                    ).pushApprovedSnippets()
                }
            )
        }
    }

    /// The launch surface: inbox + fleet/quota rail.
    @ViewBuilder
    private var homeView: some View {
        let model = homeInboxModel ?? makeInboxModel()
        DashboardHomeView(
            dataStore: dataStore,
            settingsManager: settingsManager,
            inboxModel: model,
            fleetModel: fleetModel,
            onOpenSessionLog: { openInboxSessionLog(conversationID: $0) },
            onOpenSettings: { presentSettings(itemID: SettingsDeepLinkRouting.aiInboxItemID) },
            onOpenInbox: { itemID in
                pendingInboxItemID = itemID
                navigate(to: .inbox)
            },
            onOpenQuota: { navigate(to: .quota) },
            memoryApproval: makeInboxMemoryApproval()
        )
        .background(dashboardLiveBackdropActive ? Color.clear : DesignSystem.Colors.background)
        .task {
            if homeInboxModel == nil { homeInboxModel = model }
            await startFleetIfNeeded()
        }
    }

    /// Arms the fleet watchers once, and does the first presence/usage merge.
    ///
    /// Idempotent: `.task` re-fires on every route return, and `arm` skips
    /// providers that already hold a stream.
    @MainActor
    private func startFleetIfNeeded() async {
        let providers = settingsManager.detectAvailableProviders()
            .filter(\.value)
            .map(\.key)
            .sorted { $0.displayName < $1.displayName }

        if fleetWatcher == nil {
            fleetWatcher = ProviderSessionActivityWatcher(model: fleetModel)
        }
        fleetWatcher?.arm(providers: providers)
        refreshFleet(providers: providers)
    }

    /// Display sleep tears the watchers down and marks external rows
    /// unobservable.
    ///
    /// A stream that survives sleep wakes the process on every write from a
    /// CLI running with the lid closed — strictly worse than the 60s poll it
    /// replaced. And showing pre-sleep timestamps as if they were current is
    /// the exact dishonesty the whole liveness model exists to prevent.
    var fleetSleepObservers: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                fleetWatcher?.handleWillSleep()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task { @MainActor in await startFleetIfNeeded() }
            }
            // The shared cadence already fires on the app's refresh interval and
            // pauses during sleep, so the fleet's parsed-usage half rides it
            // rather than owning a second timer.
            .onReceive(NotificationCenter.default.publisher(for: DashboardView.inboxBadgeRefreshNotification)) { _ in
                Task { @MainActor in
                    let providers = settingsManager.detectAvailableProviders()
                        .filter(\.value)
                        .map(\.key)
                        .sorted { $0.displayName < $1.displayName }
                    refreshFleet(providers: providers)
                }
            }
    }

    @MainActor
    private func refreshFleet(providers: [AgentProvider]) {
        let presenceModel = chatController.agentDeck.presence
        fleetModel.rebuild(
            providers: providers,
            presence: presenceModel.presence,
            busyLocation: presenceModel.busyLocation,
            usages: dataStore.usages,
            usagesVersion: dataStore.usagesVersion
        )
    }

    @ViewBuilder
    private var inboxView: some View {
        InboxView(
            model: homeInboxModel ?? makeInboxModel(),
            onOpenSessionLog: { conversationID in openInboxSessionLog(conversationID: conversationID) },
            onOpenSettings: { presentSettings(itemID: SettingsDeepLinkRouting.aiInboxItemID) },
            memoryApproval: makeInboxMemoryApproval(),
            openItemID: pendingInboxItemID
        )
        // Consume the deep link so returning to the Inbox later opens normally.
        .onAppear { pendingInboxItemID = nil }
        .background(dashboardLiveBackdropActive ? Color.clear : DesignSystem.Colors.background)
    }

    /// Name posted by the shared background cadence after each pass, so the
    /// badge tracks daemon-written rows without the view owning a second timer.
    static let inboxBadgeRefreshNotification = Notification.Name("openburnbar.aiInbox.badgeRefresh")

    /// Refreshes the inbox badge.
    ///
    /// Deliberately a `COUNT` rather than a fetch: this runs on the shared
    /// background cadence, and the whole point of the feature is that an idle
    /// inbox is free. A failure (daemon never ran, table absent) clears the badge
    /// instead of surfacing an error — a badge is not the place to report a fault.
    @MainActor
    func refreshAIInboxUnreadCount() async {
        aiInboxUnreadCount = try? await dataStore.aiInboxUnreadCount()
    }

    @MainActor
    private func refreshPendingMemoryReviewCount() async {
        guard let store = runtimeContext?.chatMemoryStore else {
            pendingMemoryReviewCount = nil
            return
        }
        do {
            // The inbox serves chat + usage memories (U7), so the badge counts
            // both — otherwise it would disagree with the inbox's own pill.
            let chatCount = try await store.pendingChatMemoryReviewCount(scope: memoryReviewScope)
            let usageCount = try await store.pendingUsageMemoryReviewCount(scope: memoryReviewScope)
            pendingMemoryReviewCount = chatCount + usageCount
        } catch {
            pendingMemoryReviewCount = nil
        }
    }

    // MARK: - Overview route (layout dispatch)
    //
    // The overview can render in any of the named `DashboardLayout` concepts.
    // `classic` (and any not-yet-built concept) routes to the original
    // `overviewView`; built concepts get their own composition over the shared
    // kernel + swarm backdrop. The inline `DashboardLayoutSwitcher` (the
    // prototype's top-rail concept switcher) is pinned above the content via a
    // top safe-area inset, shown only once there's data to arrange.

    @ViewBuilder
    private var overviewRouteView: some View {
        Group {
            if dataStore.totalUsageSessionCount > 0 {
                switch settingsManager.dashboardLayout {
                case .classic:       overviewView
                case .aurora:        auroraLayout
                case .nebula:        nebulaLayout
                case .constellation: constellationLayout
                case .cockpit:       cockpitLayout
                case .atelier:       atelierLayout
                }
            } else {
                // No usage data yet: every layout shows the shared welcome
                // empty state that `overviewView` renders.
                overviewView
            }
        }
    }

    @ViewBuilder
    private var overviewView: some View {
        if dataStore.totalUsageSessionCount == 0 {
            overviewEmptyState
        } else {
            ZStack {
                DashboardDepthBackdrop()
                    .ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                        #if !DISTRIBUTION_MAS
                        UpdateBannerCard()
                        #endif
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: 250),
                                    spacing: DesignSystem.Spacing.lg,
                                    alignment: .top
                                )
                            ],
                            alignment: .leading,
                            spacing: DesignSystem.Spacing.lg
                        ) {
                            StatCard(
                                title: "Total Cost",
                                value: totalCostForTimeRange.formatAsCost(),
                                accent: DesignSystem.Colors.whimsy,
                                detail: heroSubheadline
                            )
                            StatCard(
                                title: "Tokens",
                                value: "\(totalTokensForTimeRange.formatted())",
                                accent: DesignSystem.Colors.ember,
                                detail: "\(activeProviderCount) provider\(activeProviderCount == 1 ? "" : "s") active"
                            )
                            StatCard(
                                title: "Sessions",
                                value: "\(dashboardUsageWindow.sessionCount.formatted())",
                                accent: DesignSystem.Colors.amber,
                                detail: "\(dataStore.totalUsageSessionCount.formatted()) total tracked"
                            )
                        }
                        liveCostCurveBand
                        CastleGreatHallContainer()
                        NarrativeCardView(dataStore: dataStore)
                        if overviewUsesStackedLanes {
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                                providerLane
                                modelLane
                                activityLane
                            }
                        } else {
                            HStack(alignment: .top, spacing: DesignSystem.Spacing.xl) {
                                VStack(spacing: DesignSystem.Spacing.xl) {
                                    providerLane
                                    modelLane
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                activityLane
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear {
                                    updateOverviewLaneLayout(width: proxy.size.width)
                                }
                                .onChange(of: proxy.size.width) { _, width in
                                    updateOverviewLaneLayout(width: width)
                                }
                        }
                    }
                    // Publish scroll geometry for the easter egg detector.
                    .easterEggScrollProbe(space: Self.overviewScrollSpace)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .scrollContentBackground(.hidden)
                .coordinateSpace(name: Self.overviewScrollSpace)
                .onPreferenceChange(EasterEggScrollMetricsKey.self) { metrics in
                    easterEggController.registerScrollMetrics(
                        offset: metrics.offset,
                        contentHeight: metrics.contentHeight,
                        viewportHeight: overviewViewportHeight,
                        isDark: colorScheme == .dark,
                        reduceMotion: reduceMotion
                    )
                }
                // Top overlay over the dashboard content: full-bleed, hit-test
                // disabled, idles at zero cost until summoned.
                EasterEggOverlay(controller: easterEggController)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { overviewViewportHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, height in
                            overviewViewportHeight = height
                        }
                }
            }
            .onAppear {
                overviewAppeared = true
                if !didLogScreenView {
                    didLogScreenView = true
                    Analytics.shared.track(.screenViewed, ["surface": "dashboard_overview", "is_first_view": .bool(true)])
                }
            }
        }
    }

    // MARK: - Live Cost Curve Band
    //
    // Sits between the four hero stat cards and the narrative banner, mirroring
    // the iOS / Android Pulse hero curve: cumulative burn over the active time
    // window, with provider-tinted accent + brand-gradient stroke + a pulsing
    // "now" marker. Falls back to a dashed shimmer rail when there's no
    // activity yet so the band still feels alive.

    @ViewBuilder
    var liveCostCurveBand: some View {
        DashboardLiveCostCurve(
            usages: dashboardUsageWindow.usages,
            usagesRevision: dataStore.usagesVersion,
            unit: .cost,
            granularity: curveGranularityForCurrentRange,
            domain: curveDomainForCurrentRange,
            accent: liveCostCurveAccent
        )
    }

    var curveGranularityForCurrentRange: DashboardLiveCostCurve.Granularity {
        switch selectedTimeRange {
        case .today, .thisMonth, .last7Days, .last30Days, .allTime: return .day
        }
    }

    var curveDomainForCurrentRange: ClosedRange<Date> {
        if let range = selectedTimeRange.dateRange() {
            return range
        }
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? now
        return start...end
    }

    private func updateOverviewLaneLayout(width: CGFloat) {
        guard width > 0 else { return }
        // Match the old ViewThatFits break point without asking SwiftUI to build
        // and measure both expensive lane trees on every scroll/layout pass.
        //
        // Use a hysteresis dead-band around the 920pt break instead of a single
        // hard threshold: collapse to stacked only below 910 and expand to
        // side-by-side only above 930. Inside the 910...930 band the current
        // layout is held, so sub-pixel width jitter from the GeometryReader when
        // the user parks the divider near 920 can't oscillate the lane layout.
        let shouldStack: Bool
        if width < 910 {
            shouldStack = true
        } else if width > 930 {
            shouldStack = false
        } else {
            shouldStack = overviewUsesStackedLanes
        }
        guard shouldStack != overviewUsesStackedLanes else { return }
        overviewUsesStackedLanes = shouldStack
    }

    var liveCostCurveAccent: Color {
        if let top = dashboardProviderSummaries.first {
            return DesignSystem.Colors.primary(for: top.provider)
        }
        return DesignSystem.Colors.ember
    }

    private var overviewEmptyState: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()
            VStack(spacing: DesignSystem.Spacing.xl) {
                VStack(spacing: DesignSystem.Spacing.lg) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text("Welcome to OpenBurnBar")
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Start a session with any AI agent and click the refresh button to track your first usage.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    Button(action: runScan) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Scan for Sessions")
                                .font(DesignSystem.Typography.caption)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.vertical, DesignSystem.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                .fill(DesignSystem.Colors.primaryGradient)
                        )
                        .shadow(color: DesignSystem.Colors.blaze.opacity(0.3), radius: 10, y: 3)
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning)
                }
                CastleGreatHallContainer()
                    .frame(maxWidth: 900)
                    .padding(.horizontal, DesignSystem.Spacing.xl)
            }
            .opacity(overviewEmptyStateAppeared ? 1 : 0)
            .offset(y: overviewEmptyStateAppeared ? 0 : 10)
            .animation(DesignSystem.Animation.standard, value: overviewEmptyStateAppeared)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dashboardLiveBackdropActive ? Color.clear : DesignSystem.Colors.background)
        .onAppear { overviewEmptyStateAppeared = true }
    }

    var dashboardLiveBackdropActive: Bool {
        DashboardLiveBackdropVisibility.exposesContentBackdrop(
            appearanceSkin: settingsManager.appearanceSkin,
            useWebsiteBackground: settingsManager.useWebsiteBackground,
            useKernelBackdrop: useKernelBackdrop
        )
    }

    /// The appearance the app is actually presenting, which is not always the
    /// one in `\.colorScheme`.
    ///
    /// Two ways they diverge. `.openBurnBarPreferredColorScheme(...)` is a
    /// preference that reaches the window a pass *after* the user forces Light
    /// or Dark, so `colorScheme` still reports the macOS appearance on the
    /// frames right after the flip. And the sidebar subtree deliberately
    /// overrides `\.colorScheme` with the readability-derived interface scheme,
    /// so anything under it reads a value chosen for contrast, not for
    /// appearance. Backdrops (which paint the canvas the readability pass then
    /// samples) must follow the selected appearance, so they read this.
    var dashboardKernelColorScheme: ColorScheme {
        settingsManager.preferredSwiftUIColorScheme ?? colorScheme
    }

    /// Identity of the canvas a published readability profile describes.
    /// Mirrors `DashboardBackdrop.readabilityContextID`, whose `.task(id:)`
    /// republishes on exactly these inputs.
    var dashboardReadabilityContextID: String {
        [
            settingsManager.appearanceSkin.rawValue,
            dashboardLiveBackdropActive.description,
            useKernelBackdrop.description,
            dashboardKernelColorScheme == .dark ? "dark" : "light"
        ].joined(separator: ":")
    }

    var dashboardActiveReadabilityProfile: BackdropReadabilityProfile {
        guard dashboardLiveBackdropActive else {
            return BackdropReadabilityProfile.nativeFallback(
                colorScheme: dashboardKernelColorScheme,
                appearanceSkin: settingsManager.appearanceSkin,
                liveBackdropActive: false
            )
        }
        // Before the backdrop's first publish (and after a skin change resets
        // it) the skin-aware native fallback is the correct answer, not a
        // constant: editorial paints light paper, every other live backdrop
        // paints a dark canvas.
        return backdropReadabilityProfile ?? BackdropReadabilityProfile.nativeFallback(
            colorScheme: dashboardKernelColorScheme,
            appearanceSkin: settingsManager.appearanceSkin,
            liveBackdropActive: true
        )
    }

    var dashboardAdaptiveScrimOpacity: Double {
        let measured = dashboardActiveReadabilityProfile.scrimOpacity
        if reduceTransparency { return max(measured, 0.82) }
        if colorSchemeContrast == .increased { return max(measured, 0.38) }
        return measured
    }

    private func openSessionLogs(_ target: ConversationJumpTarget) {
        sessionLogJumpTarget = target
        if mainRoute != .sessionLogs {
            navigate(to: .sessionLogs)
        }
    }

    func openOrchestratorChat() {
        switch FleetChatOpenPolicy.decision(
            consentShown: settingsManager.cliAssistantConsentShown,
            requestedMode: .orchestrator
        ) {
        case .showConsent:
            pendingOpenOrchestratorChat = true
            showCLIConsentSheet = true
        case .present:
            presentFleetChat()
        }
    }

    func handleFleetChatConsentDismissed() {
        let continuation = FleetChatOpenPolicy.afterConsent(
            pendingOrchestrator: pendingOpenOrchestratorChat,
            allowed: settingsManager.cliAssistantAllowed
        )
        pendingOpenOrchestratorChat = false
        if continuation == .presentOrchestrator {
            presentFleetChat()
        }
    }

    private func presentFleetChat() {
        Task { await chatController.cliBridge.detect() }
        if preferMaximizedChat {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                navigate(to: .chat)
            }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                chatPanelOpen = true
            }
        }
    }
}
