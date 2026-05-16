import AppKit
import SwiftUI
import WebKit

// MARK: - Dashboard View

struct DashboardView: View {
    @Bindable var dataStore: DataStore
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    @Bindable var settingsManager: SettingsManager
    @Environment(NavigationCoordinator.self) var navigationCoordinator
    var aggregator: UsageAggregator?
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?
    var runtimeContext: OpenBurnBarRuntimeContext?
    @State var navigationModel = DashboardNavigationModel()
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
    @State private var showCLIConsentSheet = false
    @State private var showSessionLogCloudConsent = false
    @State var sessionLogJumpTarget: ConversationJumpTarget?
    @State var dashboardCanvasSize: CGSize = .zero
    @State var didAutoExpandEmptyTimeRange = false
    @State var showContextPackSheet = false
    @AppStorage("dashboardChatPreferMaximized") var preferMaximizedChat = false
    var chatController: ChatSessionController
    @State var quotaService = ProviderQuotaService.shared
    @State var missionConsoleController: MissionConsoleWindowController?

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
            settingsManager: context.settingsManager
        )
    }

    var isScanning: Bool { aggregator?.isRefreshing ?? false }

    var canRunRecount: Bool { aggregator != nil && !isScanning }

    func runScan() {
        guard let agg = aggregator else { return }
        Task { await agg.refreshAll() }
    }

    func runRecount() {
        guard let agg = aggregator else { return }
        Task { await agg.recountAll() }
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
        case .database: return "Database"
        case .projects: return "Projects"
        case .missions: return "Missions"
        case .sessionLogs: return "Session Logs"
        case .chat: return "Chat"
        case .provider(let provider): return provider.displayName
        case .model(let modelName): return modelName
        }
    }

    var body: some View {
        @Bindable var chatController = chatController
        return NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
                .background(DesignSystem.Colors.background)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            DashboardBackdrop(moodBand: dataStore.moodBand)
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
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                    if !chatPanelOpen {
                        if let controller = missionConsoleController {
                            MissionFAB(host: controller.host) {
                                controller.makeOrShow()
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
            .padding(EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20))
        }
        .toolbar { toolbarContent }
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
        .environment(settingsManager)
    }

    // MARK: - Detail View

    @ViewBuilder
    var detailView: some View {
        VStack(spacing: 0) {
            dashboardWorkspaceNavStrip

            Group {
                switch mainRoute {
                case .overview:
                    overviewView
                case .insights:
                    MacAgentInsightsWorkspace(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        chatController: chatController
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
        }
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

    private func autoExpandTimeRangeIfNeeded() {
        guard !didAutoExpandEmptyTimeRange else { return }
        defer { didAutoExpandEmptyTimeRange = true }
        let currentRangeEmpty = dataStore.usageWindowSummary(for: selectedTimeRange).sessionCount == 0
        let allTimeEmpty = dataStore.totalUsageSessionCount == 0
        if currentRangeEmpty, !allTimeEmpty {
            selectedTimeRange = .allTime
        }
    }

    @ViewBuilder
    private var dashboardWorkspaceNavStrip: some View {
        DashboardWorkspaceNavStrip(
            currentRoute: mainRoute,
            activeChatBackend: chatController.chatBackend
        ) { route in
            navigate(to: route)
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
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
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
                        NarrativeCardView(dataStore: dataStore)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: DesignSystem.Spacing.xl) {
                                VStack(spacing: DesignSystem.Spacing.xl) {
                                    providerLane
                                    modelLane
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                activityLane
                            }

                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                                providerLane
                                modelLane
                                activityLane
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.xl)
                }
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { overviewAppeared = true }
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
    private var liveCostCurveBand: some View {
        DashboardLiveCostCurve(
            usages: dashboardUsageWindow.usages,
            unit: .cost,
            granularity: curveGranularityForCurrentRange,
            domain: curveDomainForCurrentRange,
            accent: liveCostCurveAccent
        )
    }

    private var curveGranularityForCurrentRange: DashboardLiveCostCurve.Granularity {
        switch selectedTimeRange {
        case .today, .thisMonth, .last7Days, .last30Days, .allTime: return .day
        }
    }

    private var curveDomainForCurrentRange: ClosedRange<Date> {
        if let range = selectedTimeRange.dateRange() {
            return range
        }
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? now
        return start...end
    }

    private var liveCostCurveAccent: Color {
        if let top = dashboardProviderSummaries.first {
            return DesignSystem.Colors.primary(for: top.provider)
        }
        return DesignSystem.Colors.ember
    }

    private var overviewEmptyState: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()
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
            .opacity(overviewEmptyStateAppeared ? 1 : 0)
            .offset(y: overviewEmptyStateAppeared ? 0 : 10)
            .animation(DesignSystem.Animation.standard, value: overviewEmptyStateAppeared)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.background)
        .onAppear { overviewEmptyStateAppeared = true }
    }

    private func openSessionLogs(_ target: ConversationJumpTarget) {
        sessionLogJumpTarget = target
        if mainRoute != .sessionLogs {
            navigate(to: .sessionLogs)
        }
    }
}
