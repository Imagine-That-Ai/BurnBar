import AppKit
import OpenBurnBarCore
import SwiftUI
import WebKit

// MARK: - Dashboard View

struct DashboardView: View {
    @Bindable var dataStore: DataStore
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    @Bindable var settingsManager: SettingsManager
    @Environment(NavigationCoordinator.self) var navigationCoordinator
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var easterEggController = EasterEggController()
    @State private var didLogScreenView = false
    var aggregator: UsageAggregator?
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?
    var runtimeContext: OpenBurnBarRuntimeContext?
    @State var consentCoordinator: DashboardConsentCoordinator?
    @State var mainRoute: DashboardMainRoute = .overview
    @State var routeHistory: [DashboardMainRoute] = []
    @State var selectedTimeRange: TimeRange = .today
    @AppStorage("dashboardViewMode") var viewMode: DashboardViewMode = .agents
    @AppStorage("dashboardViewMode") var storedViewMode: DashboardViewMode = .agents
    @State var showingSettings = false
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
    @State var burnRailDelta: Double? = nil
    @State var burnRailDeltaRequestID: String? = nil
    private static let overviewScrollSpace = "dashboardOverviewScroll"
    @State var didAutoExpandEmptyTimeRange = false
    @State var showContextPackSheet = false
    @AppStorage("dashboardChatPreferMaximized") var preferMaximizedChat = false
    @AppStorage(KernelBackdropPreferences.enabledKey) private var useKernelBackdrop: Bool = false
    var chatController: ChatSessionController
    @State var quotaService = ProviderQuotaService.shared
    @State var missionConsoleController: MissionConsoleWindowController?
    @State private var showMacWandComposer = false
    @State var pendingMemoryReviewCount: Int?
    @State var showCommandPalette = false
    @State var showHeroPopover = false
    @State private var dashboardSplitVisibility: NavigationSplitViewVisibility = .all
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

    func toggleDashboardSidebar() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignSystem.Animation.snappy) {
            dashboardSplitVisibility = isDashboardSidebarVisible ? .detailOnly : .all
        }
    }

    var canGoBack: Bool {
        !routeHistory.isEmpty || mainRoute != .overview
    }

    func navigate(to route: DashboardMainRoute) {
        guard route != mainRoute else { return }
        routeHistory.append(mainRoute)
        mainRoute = route
    }

    func goBack() {
        if let previous = routeHistory.popLast() {
            mainRoute = previous
        } else if mainRoute != .overview {
            mainRoute = .overview
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
        case .overview: route = .overview
        case .charts: route = .charts
        case .database: route = .database
        case .projects: route = .projects
        case .sessionLogs: route = .sessionLogs
        case .chat: route = .chat
        }
        withAnimation(DesignSystem.Animation.standard) {
            navigate(to: route)
        }
    }

    var backButtonHelpText: String {
        if let previous = routeHistory.last {
            return "Back to \(routeTitle(previous))"
        }
        return "Back to Overview"
    }

    func routeTitle(_ route: DashboardMainRoute) -> String {
        switch route {
        case .overview: return "Overview"
        case .insights: return "Insights"
        case .charts: return "Charts"
        case .database: return "Database"
        case .projects: return "Projects"
        case .missions: return "Missions"
        case .sessionLogs: return "Session Logs"
        case .memoryReview: return "Memory"
        case .chat: return "Chat"
        case .quota: return "Quota"
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
        return VStack(spacing: 0) {
            dashboardCommandDeck

            NavigationSplitView(columnVisibility: $dashboardSplitVisibility) {
                sidebarView
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
            DashboardBackdrop(moodBand: dataStore.moodBand)
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
        .onAppear {
            autoExpandTimeRangeIfNeeded()
            if missionConsoleController == nil {
                missionConsoleController = MissionConsoleWindowController.bind(to: operatingLayer)
            }
            Task { await refreshPendingMemoryReviewCount() }
            consumeCoordinatorDashboardRoute()
        }
        .onChange(of: navigationCoordinator.dashboardRoute) { _, _ in
            consumeCoordinatorDashboardRoute()
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
            commandPaletteShortcut
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
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                settingsManager: settingsManager,
                accountManager: accountManager,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService,
                dataStore: dataStore,
                runtimeContext: runtimeContext
            )
        }
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
        .sheet(isPresented: $showCLIConsentSheet) {
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
        .environment(\.dashboardLiveBackdropActive, dashboardLiveBackdropActive)
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
                case .overview:
                    overviewRouteView
                case .insights:
                    MacAgentInsightsWorkspace(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        chatController: chatController,
                        selectedTimeRange: selectedTimeRange
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .charts:
                    ChartsPageView(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        chatController: chatController,
                        selectedTimeRange: $selectedTimeRange
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
                            showingSettings = true
                        }
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
                afterStatusChange: { await refreshPendingMemoryReviewCount() }
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

    @MainActor
    private func refreshPendingMemoryReviewCount() async {
        guard let store = runtimeContext?.chatMemoryStore else {
            pendingMemoryReviewCount = nil
            return
        }
        do {
            pendingMemoryReviewCount = try await store.pendingChatMemoryReviewCount(scope: memoryReviewScope)
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

    private func openSessionLogs(_ target: ConversationJumpTarget) {
        sessionLogJumpTarget = target
        if mainRoute != .sessionLogs {
            navigate(to: .sessionLogs)
        }
    }
}
