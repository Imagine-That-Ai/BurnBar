import AppKit
import SwiftUI
import WebKit

// MARK: - Dashboard Main Route

private enum DashboardMainRoute: Hashable {
    case overview
    case database
    case projects
    case sessionLogs
    case provider(AgentProvider)
    case model(String)
}

// MARK: - Dashboard View

struct DashboardView: View {
    @Bindable var dataStore: DataStore
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    @Bindable private var settingsManager = SettingsManager.shared
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    var aggregator: UsageAggregator?
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?
    @State private var mainRoute: DashboardMainRoute = .overview
    @State private var routeHistory: [DashboardMainRoute] = []
    @State private var selectedTimeRange: TimeRange = .today
    @AppStorage("dashboardViewMode") private var viewMode: DashboardViewMode = .agents
    @State private var showingSettings = false
    @State private var showProgressPanel = false
    @State private var overviewAppeared = false
    @State private var deviceCount = 0
    @State private var sidebarAppeared = false
    @State private var chatPanelOpen = false
    @State private var showIndexingConsent = false
    @State private var showCLIConsentSheet = false
    @State private var showSessionLogCloudConsent = false
    @State private var sessionLogJumpTarget: ConversationJumpTarget?
    @State private var sessionLogJumpLookup: [String: ConversationRecord] = [:]
    @State private var dashboardCanvasSize: CGSize = .zero
    @State private var didAutoExpandEmptyTimeRange = false
    @State private var showContextPackSheet = false
    var chatController: ChatSessionController
    @State private var quotaService = ProviderQuotaService.shared

    init(
        dataStore: DataStore,
        aggregator: UsageAggregator?,
        accountManager: AccountManager = .shared,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil,
        chatController: ChatSessionController,
        operatingLayer: OpenBurnBarOperatingLayer
    ) {
        self._dataStore = Bindable(dataStore)
        self._operatingLayer = Bindable(operatingLayer)
        self.aggregator = aggregator
        self.accountManager = accountManager
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
        self.chatController = chatController
    }

    private var isScanning: Bool { aggregator?.isRefreshing ?? false }

    private func runScan() {
        guard let agg = aggregator else { return }
        Task { await agg.refreshAll() }
    }

    private func runRecount() {
        guard let agg = aggregator else { return }
        Task { await agg.recountAll() }
    }

    private var canGoBack: Bool {
        !routeHistory.isEmpty || mainRoute != .overview
    }

    private func navigate(to route: DashboardMainRoute) {
        guard route != mainRoute else { return }
        routeHistory.append(mainRoute)
        mainRoute = route
    }

    private func goBack() {
        if let previous = routeHistory.popLast() {
            mainRoute = previous
        } else if mainRoute != .overview {
            mainRoute = .overview
        }
    }

    private var backButtonHelpText: String {
        if let previous = routeHistory.last {
            return "Back to \(routeTitle(previous))"
        }
        return "Back to Overview"
    }

    private func routeTitle(_ route: DashboardMainRoute) -> String {
        switch route {
        case .overview: return "Overview"
        case .database: return "Database"
        case .projects: return "Projects"
        case .sessionLogs: return "Session Logs"
        case .provider(let provider): return provider.displayName
        case .model(let modelName): return modelName
        }
    }

    /// Opens Cursor’s extension install flow for OpenBurnBar (`extensions/openburnbar` package id).
    private func openBurnBarCursorExtension() {
        let id = "openburnbar.openburnbar"
        let candidates = [
            URL(string: "cursor:extension/\(id)"),
            URL(string: "vscode:extension/\(id)"),
        ].compactMap { $0 }
        for url in candidates {
            if NSWorkspace.shared.open(url) { return }
        }
    }

    var body: some View {
        @Bindable var chatController = chatController
        return NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
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
        }
        .onChange(of: dataStore.usages.count) { _, _ in
            autoExpandTimeRangeIfNeeded()
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 12) {
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
                        onClose: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                chatPanelOpen = false
                                UserDefaults.standard.set(dataStore.usages.count, forKey: "lastSeenSessionCountForChatBadge")
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
                    ChatFAB(hasNewInsights: hasNewInsightPulse) {
                        if !settingsManager.cliAssistantConsentShown {
                            showCLIConsentSheet = true
                            return
                        }
                        Task { await chatController.cliBridge.detect() }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            chatPanelOpen = true
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20))
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                settingsManager: SettingsManager.shared,
                accountManager: accountManager,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService,
                dataStore: dataStore
            )
        }
        .onAppear {
            if !settingsManager.conversationIndexingConsentShown {
                showIndexingConsent = true
            }
            refreshSessionLogJumpLookup()
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
        .onChange(of: dataStore.lastRefresh) { _, _ in
            refreshSessionLogJumpLookup()
        }
        .onChange(of: navigationCoordinator.pendingNavigation) { _, destination in
            guard let destination else { return }
            switch destination {
            case .conversationSearch, .chatPanel:
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    chatPanelOpen = true
                }
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
        .preferredColorScheme(settingsManager.preferredSwiftUIColorScheme)
    }

    private var hasNewInsightPulse: Bool {
        let n = UserDefaults.standard.integer(forKey: "lastSeenSessionCountForChatBadge")
        return dataStore.usages.count > n && !dataStore.usages.isEmpty
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Leading: flat brand mark (not grouped with trailing controls in the system glass capsule).
        ToolbarItemGroup(placement: .navigation) {
            Button {
                guard canGoBack else { return }
                withAnimation(DesignSystem.Animation.standard) {
                    goBack()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .semibold))

                    Text("Back")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(canGoBack ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(canGoBack ? 0.62 : 0.34))
                )
                .overlay(
                    Capsule()
                        .stroke(DesignSystem.Colors.borderSubtle.opacity(canGoBack ? 0.70 : 0.30), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)
            .keyboardShortcut("[", modifiers: [.command])
            .help(canGoBack ? backButtonHelpText : "Back")
            .accessibilityLabel(canGoBack ? backButtonHelpText : "Back")

            HStack(alignment: .center, spacing: 10) {
                AppLogoView(size: 22)
                Text("OpenBurnBar")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("OpenBurnBar")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            GlassSegmentedPicker(
                selection: $viewMode,
                iconViews: { mode in
                    switch mode {
                    case .agents:
                        return AnyView(
                            CyclingProviderIconView(
                                providers: [
                                    .claudeCode, .cursor, .codex, .copilot,
                                    .cline, .geminiCLI, .factory, .augment, .hermes
                                ],
                                size: 11,
                                interval: 2.2,
                                startOffset: 0
                            )
                        )
                    case .models:
                        return AnyView(
                            CyclingProviderIconView(
                                providers: [
                                    .claudeCode, .codex, .geminiCLI, .copilot, .cursor
                                ],
                                size: 11,
                                interval: 2.5,
                                startOffset: 2
                            )
                        )
                    }
                }
            )
            .frame(width: 160)
            .onChange(of: viewMode) { _, _ in
                withAnimation(DesignSystem.Animation.standard) {
                    routeHistory.removeAll()
                    mainRoute = .overview
                }
            }

            GlassPicker(
                selection: $selectedTimeRange,
                options: TimeRange.allCases
            )

            UsageModeToolbarPicker(selection: $settingsManager.usageDisplayMode)

            GlassBadge {
                Text(settingsManager.formatUsageMetric(cost: totalCostForTimeRange, tokens: totalTokensForTimeRange))
                    .font(DesignSystem.Typography.mono)
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
            }

            Button(action: runScan) {
                Group {
                    if isScanning {
                        AnimatedMiningPickView()
                            .frame(width: 17, height: 17)
                            .clipShape(.circle)
                    } else {
                        DashboardActionGlyph(kind: .importFromLogs, size: 15)
                    }
                }
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(isScanning)
            .accessibilityLabel("Import from logs")
            .help("Import new and updated sessions from your agent log folders.")

            Button(action: runRecount) {
                DashboardActionGlyph(kind: .sweepRecount, size: 15)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(isScanning || aggregator == nil)
            .accessibilityLabel("Recount totals")
            .help("Rebuild usage totals from saved sessions (clears derived numbers, then tallies again).")

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        @Bindable var ds = dataStore

        return ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    AppLogoView(size: 44)
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Command")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)

                        Text(viewMode == .agents ? "Agent providers" : "LLM Models")
                            .font(DesignSystem.Typography.title)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text(viewMode == .agents
                            ? "Scan, compare spend, and drill into model behavior from one workspace."
                            : "Track spend and token volume across every model your agents use.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: DesignSystem.Spacing.sm) {
                    SidebarItem(
                        provider: nil,
                        isSelected: mainRoute == .overview,
                        primaryMetric: settingsManager.formatUsageMetric(cost: totalCostForTimeRange, tokens: totalTokensForTimeRange),
                        totalCost: totalCostForTimeRange,
                        sessionCount: filteredUsages.count
                    ) {
                        withAnimation(DesignSystem.Animation.standard) {
                            routeHistory.removeAll()
                            mainRoute = .overview
                        }
                    }

                    if viewMode == .agents {
                        ForEach(Array(dashboardProviderSummaries.enumerated()), id: \.element.id) { index, summary in
                            SidebarItem(
                                provider: summary.provider,
                                isSelected: mainRoute == .provider(summary.provider),
                                primaryMetric: settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens),
                                totalCost: summary.totalCost,
                                sessionCount: summary.sessionCount
                            ) {
                                withAnimation(DesignSystem.Animation.standard) {
                                    navigate(to: .provider(summary.provider))
                                }
                            }
                            .focusable()
                            .opacity(sidebarAppeared ? 1 : 0)
                            .offset(y: sidebarAppeared ? 0 : 8)
                            .animation(
                                DesignSystem.Animation.standard.delay(Double(index) * 0.06),
                                value: sidebarAppeared
                            )
                        }
                    } else {
                        ForEach(Array(dashboardModelSummaries.enumerated()), id: \.element.id) { index, summary in
                            ModelSidebarItem(
                                summary: summary,
                                isSelected: mainRoute == .model(summary.modelName)
                            ) {
                                withAnimation(DesignSystem.Animation.standard) {
                                    navigate(to: .model(summary.modelName))
                                }
                            }
                            .focusable()
                            .opacity(sidebarAppeared ? 1 : 0)
                            .offset(y: sidebarAppeared ? 0 : 8)
                            .animation(
                                DesignSystem.Animation.standard.delay(Double(index) * 0.06),
                                value: sidebarAppeared
                            )
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Window")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)

                        Text(selectedTimeRange.displayName)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text("\(activeProviderCount) active providers")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Cursor")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)

                        Button(action: openBurnBarCursorExtension) {
                            HStack(spacing: DesignSystem.Spacing.md) {
                                ZStack {
                                    Circle()
                                        .fill(DesignSystem.Colors.surfaceElevated)
                                        .frame(width: 36, height: 36)

                                    ProviderLogoView(provider: .cursor, size: 24, useFallbackColor: false)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add OpenBurnBar to Cursor")
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        .multilineTextAlignment(.leading)

                                    Text("Opens the extension install page")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "arrow.up.forward.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Install OpenBurnBar in Cursor (openburnbar.openburnbar)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                }

                if accountManager.isSignedIn {
                    DeviceBreakdownCard(
                        dataStore: dataStore,
                        isSyncing: cloudSyncService?.isSyncing ?? false
                    )
                }

                if viewMode == .agents ? dashboardProviderSummaries.isEmpty : dashboardModelSummaries.isEmpty {
                    Text(viewMode == .agents ? "No providers in this window" : "No models in this window")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, DesignSystem.Spacing.xl)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background {
            ZStack {
                DesignSystem.Colors.surface.opacity(0.92)

                LinearGradient(
                    colors: [
                        DesignSystem.Colors.textPrimary.opacity(0.02),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .scrollContentBackground(.hidden)
        .focusable()
        .onMoveCommand { direction in
            let order = sidebarRouteOrder
            guard let idx = order.firstIndex(of: mainRoute) else { return }
            switch direction {
            case .up, .left:
                if idx > 0 { navigate(to: order[idx - 1]) }
            case .down, .right:
                if idx + 1 < order.count { navigate(to: order[idx + 1]) }
            default:
                break
            }
        }
        .onKeyPress(.escape) {
            withAnimation(DesignSystem.Animation.standard) {
                goBack()
            }
            return .handled
        }
        .onAppear { sidebarAppeared = true }
    }

    private var sidebarRouteOrder: [DashboardMainRoute] {
        var routes: [DashboardMainRoute] = [.overview]
        if viewMode == .agents {
            routes.append(contentsOf: dashboardProviderSummaries.map { .provider($0.provider) })
        } else {
            routes.append(contentsOf: dashboardModelSummaries.map { .model($0.modelName) })
        }
        return routes
    }

    private func autoExpandTimeRangeIfNeeded() {
        guard didAutoExpandEmptyTimeRange == false else { return }
        guard selectedTimeRange != .allTime else { return }
        guard dataStore.usages.isEmpty == false else { return }
        guard dataStore.usages(in: dashboardDateRange).isEmpty else { return }
        selectedTimeRange = .allTime
        didAutoExpandEmptyTimeRange = true
    }

    private var workspaceProjectCount: Int {
        Set(filteredUsages.map(\.projectName)).count
    }

    /// Database, Projects, Session Logs — moved from the sidebar into the main pane.
    private var dashboardWorkspaceNavStrip: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    DashboardWorkspaceNavButton(
                        title: "Database",
                        subtitle: "Corpus, search & system truth",
                        systemImage: "cylinder.split.1x2.fill",
                        accent: DesignSystem.Colors.blaze,
                        isSelected: mainRoute == .database
                    ) {
                        withAnimation(DesignSystem.Animation.standard) {
                            navigate(to: .database)
                        }
                    }

                    DashboardWorkspaceNavButton(
                        title: "Projects",
                        subtitle: "\(workspaceProjectCount) project\(workspaceProjectCount == 1 ? "" : "s")",
                        systemImage: "folder.fill",
                        accent: DesignSystem.Colors.amber,
                        isSelected: mainRoute == .projects
                    ) {
                        withAnimation(DesignSystem.Animation.standard) {
                            navigate(to: .projects)
                        }
                    }

                    DashboardWorkspaceNavButton(
                        title: "Session Logs",
                        subtitle: "Full transcripts & chat history",
                        systemImage: "scroll.fill",
                        accent: DesignSystem.Colors.ember,
                        isSelected: mainRoute == .sessionLogs
                    ) {
                        withAnimation(DesignSystem.Animation.standard) {
                            navigate(to: .sessionLogs)
                        }
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.xl)
                .padding(.vertical, DesignSystem.Spacing.md)
            }
            .background(DesignSystem.Colors.surface.opacity(0.55))

            Divider()
                .background(DesignSystem.Colors.borderSubtle)
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            dashboardWorkspaceNavStrip

            Group {
                switch mainRoute {
                case .overview:
                    overviewView
                case .database:
                    DatabaseWorkspaceView(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        accountManager: accountManager,
                        cloudSyncService: cloudSyncService
                    )
                case .projects:
                    ProjectsView(dataStore: dataStore, operatingLayer: operatingLayer)
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

    // MARK: - Overview

    private var overviewView: some View {
        ScrollView {
            if dashboardProviderSummaries.isEmpty && dashboardModelSummaries.isEmpty {
                emptyOverviewView
            } else {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    trustStatusStrip
                    if controllerQuestionShortcutCard != nil || controllerMissionShortcutCard != nil {
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                            if let controllerQuestionShortcutCard {
                                controllerQuestionShortcutCard
                            }
                            if let controllerMissionShortcutCard {
                                controllerMissionShortcutCard
                            }
                        }
                    }
                    OpenBurnBarDashboardOperatingSection(
                        layer: operatingLayer,
                        onOpenProjectSummary: openLatestProjectSessionLog,
                        onOpenEvidenceEntry: openEvidenceSessionLog
                    )
                    DashboardQuickSwitchView(
                        dataStore: dataStore,
                        onOpenSettings: { showingSettings = true }
                    )
                    NarrativeCardView(dataStore: dataStore)
                    ContextPackDashboardCard(
                        dataStore: dataStore,
                        selectedTimeRange: selectedTimeRange
                    ) {
                        showContextPackSheet = true
                    }
                    overviewHero
                    databaseCTA

                    statsRow

                    ProviderQuotaOverviewPanel(
                        quotaService: quotaService,
                        dataStore: dataStore,
                        onSelectProvider: { provider in
                            withAnimation(DesignSystem.Animation.standard) {
                                navigate(to: .provider(provider))
                            }
                        }
                    )

                    HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                        if viewMode == .agents {
                            providerLane
                        } else {
                            modelLane
                        }
                        activityLane
                    }
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .background(Color.clear)
        .scrollContentBackground(.hidden)
        .onAppear {
            overviewAppeared = true
            deviceCount = ((try? dataStore.deviceUsageSummaries()) ?? []).count
            Task { await operatingLayer.refreshControllerRuntime() }
        }
        .onChange(of: dataStore.lastRefresh) { _, _ in
            deviceCount = ((try? dataStore.deviceUsageSummaries()) ?? []).count
        }
    }

    private var controllerQuestionShortcutCard: AnyView? {
        guard let question = operatingLayer.snapshot.controllerRuntime.pendingQuestions.first else {
            return nil
        }

        return AnyView(
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if question.isUnread {
                                    Circle()
                                        .fill(DesignSystem.Colors.ember)
                                        .frame(width: 8, height: 8)
                                }
                                Text("Next Operator Question")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .textCase(.uppercase)
                            }
                            Text(question.title)
                                .font(DesignSystem.Typography.headline)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text(question.prompt)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let stageLabel = question.stageLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !stageLabel.isEmpty {
                            Text(stageLabel)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.blaze)
                                .padding(.horizontal, DesignSystem.Spacing.sm)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(DesignSystem.Colors.blaze.opacity(0.12)))
                        }
                    }

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        if let target = sessionLogJumpTarget(for: question) {
                            GlassButton(
                                title: "Open Session Log",
                                icon: "doc.text.magnifyingglass",
                                style: .regular
                            ) {
                                sessionLogJumpTarget = target
                                withAnimation(DesignSystem.Animation.standard) {
                                    navigate(to: .sessionLogs)
                                }
                            }
                        }

                        ForEach(question.suggestedOptions.prefix(2)) { option in
                            Button {
                                Task {
                                    await operatingLayer.answerPendingQuestion(
                                        id: question.id,
                                        answer: option.answer,
                                        selectedOptionID: option.id
                                    )
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .font(DesignSystem.Typography.tiny)
                                    if let detail = option.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                                       !detail.isEmpty {
                                        Text(detail)
                                            .font(DesignSystem.Typography.tiny)
                                            .foregroundStyle(DesignSystem.Colors.textMuted)
                                            .lineLimit(1)
                                    }
                                }
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .padding(.horizontal, DesignSystem.Spacing.sm)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.75))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
        )
    }

    private var controllerMissionShortcutCard: AnyView? {
        guard let mission = operatingLayer.snapshot.controllerRuntime.missions.first else {
            return nil
        }

        return AnyView(
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mission Runtime")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .textCase(.uppercase)
                            Text(mission.title)
                                .font(DesignSystem.Typography.headline)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text(trimmedValue(mission.packetSummary) ?? mission.summary)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(mission.burnCostUSD.formatAsCost())
                                .font(DesignSystem.Typography.monoSmall)
                                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            runtimeBadge(title: mission.state.label, color: mission.state.color)
                            if let takeoverState = mission.latestTakeoverState {
                                runtimeBadge(title: takeoverState.label, color: takeoverState.color)
                            }
                        }
                    }

                    if let activeRunID = mission.activeRunID?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !activeRunID.isEmpty {
                        runtimeLine(
                            icon: "point.3.filled.connected.trianglepath.dotted",
                            title: "Run",
                            value: activeRunID
                        )
                    }
                    if let latestResult = mission.latestResultSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !latestResult.isEmpty {
                        runtimeLine(
                            icon: "checklist.checked",
                            title: "Latest result",
                            value: latestResult
                        )
                    }
                    if let takeoverReason = mission.latestTakeoverReason?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !takeoverReason.isEmpty {
                        runtimeLine(
                            icon: "arrow.triangle.branch",
                            title: "Takeover",
                            value: takeoverReason,
                            accent: mission.latestTakeoverState?.color ?? DesignSystem.Colors.blaze
                        )
                    }

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        GlassButton(
                            title: "Inspect Session Logs",
                            icon: "doc.text.magnifyingglass",
                            style: .regular
                        ) {
                            withAnimation(DesignSystem.Animation.standard) {
                                navigate(to: .sessionLogs)
                            }
                        }
                        if mission.takeoverCount > 0 {
                            Text("\(mission.takeoverCount) takeover attempt\(mission.takeoverCount == 1 ? "" : "s")")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        Spacer()
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
        )
    }

    @ViewBuilder
    private func runtimeLine(icon: String, title: String, value: String, accent: Color = DesignSystem.Colors.textPrimary) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 16, alignment: .top)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
                Text(value)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func runtimeBadge(title: String, color: Color) -> some View {
        Text(title)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(color)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }

    private func trimmedValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private func openSessionLogs(_ target: ConversationJumpTarget) {
        sessionLogJumpTarget = target
        if mainRoute != .sessionLogs {
            navigate(to: .sessionLogs)
        }
    }

    private func openLatestProjectSessionLog(_ projectName: String, summary: String) {
        guard let conversation = latestConversation(for: projectName) else { return }
        let snippet = summary.nonEmpty
            ?? conversation.summary?.nonEmpty
            ?? conversation.summaryTitle?.nonEmpty
            ?? conversation.lastAssistantMessage
        openSessionLogs(
            ConversationJumpTarget(
                conversation: conversation,
                snippet: snippet,
                startOffset: 0,
                endOffset: snippet.count,
                source: .retrieval
            )
        )
    }

    private func openEvidenceSessionLog(_ entry: OpenBurnBarEvidenceEntry) {
        guard let conversation = conversationForEvidenceEntry(entry) else { return }
        openSessionLogs(
            ConversationJumpTarget(
                conversation: conversation,
                snippet: entry.summary,
                startOffset: 0,
                endOffset: entry.summary.count,
                source: .retrieval
            )
        )
    }

    private func conversationForEvidenceEntry(_ entry: OpenBurnBarEvidenceEntry) -> ConversationRecord? {
        if let conversation = sessionLogJumpLookup.values.first(where: { $0.id == entry.id }) {
            return conversation
        }
        guard let conversation = try? dataStore.fetchConversation(id: entry.id) else {
            return nil
        }
        return conversation
    }

    private func latestConversation(for projectName: String) -> ConversationRecord? {
        let trimmedProjectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedProjectName.isEmpty == false else { return nil }
        let targetKey = normalizedProjectKey(trimmedProjectName)

        return sessionLogJumpLookup.values
            .filter { conversation in
                let conversationKey = normalizedProjectKey(conversation.projectName)
                guard conversationKey.isEmpty == false else { return false }
                return conversationKey == targetKey
                    || conversationKey.contains(targetKey)
                    || targetKey.contains(conversationKey)
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.endTime ?? lhs.startTime ?? lhs.fileModifiedAt ?? lhs.indexedAt
                let rhsDate = rhs.endTime ?? rhs.startTime ?? rhs.fileModifiedAt ?? rhs.indexedAt
                return lhsDate > rhsDate
            }
            .first
    }

    private func normalizedProjectKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }

        let candidate: String
        if trimmed.contains("/") {
            candidate = URL(fileURLWithPath: trimmed).lastPathComponent
        } else {
            candidate = trimmed
        }

        return candidate
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func sessionLogJumpTarget(for question: OpenBurnBarControllerQuestion) -> ConversationJumpTarget? {
        let sessionID = question.deepLink?.targetID ?? question.sessionID
        guard let sessionID else { return nil }
        guard let conversation = sessionLogJumpLookup[sessionID] else {
            return nil
        }
        return ConversationJumpTarget(
            conversation: conversation,
            snippet: question.prompt,
            startOffset: 0,
            endOffset: question.prompt.count,
            source: .retrieval
        )
    }

    private func refreshSessionLogJumpLookup() {
        let logs = (try? dataStore.fetchSessionLogSummaries(limit: 1000)) ?? []
        var lookup: [String: ConversationRecord] = [:]
        for log in logs where lookup[log.sessionId] == nil {
            lookup[log.sessionId] = log
        }
        sessionLogJumpLookup = lookup
    }

    private var emptyOverviewView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Image(systemName: "cpu")
                .font(.system(size: 64))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text("No sessions recorded")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("OpenBurnBar will automatically import sessions from your configured agent logs.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.xxl)

            if isScanning {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    AnimatedMiningPickView()
                        .frame(width: 18, height: 18)
                        .clipShape(.circle)
                    Text("Initial scan in progress \u{2014} sessions will appear here as they're discovered. This may take a moment on the first run.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DesignSystem.Spacing.xxl)
            } else {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text("If this is your first launch, click Scan to parse your log history. Depending on log size, the initial import may take a moment and the dashboard will populate progressively.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DesignSystem.Spacing.xxl)
            }

            GlassButton(
                title: "Scan Now",
                icon: "arrow.clockwise",
                style: .prominent
            ) {
                guard let agg = aggregator else { return }
                Task { await agg.refreshAll() }
            }
            .frame(width: 160)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.xxxl)
    }

    private var overviewHero: some View {
        GlassCard {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.ember.opacity(0.14),
                                DesignSystem.Colors.amber.opacity(0.08),
                                DesignSystem.Colors.whimsy.opacity(0.05),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            Text(viewMode == .agents ? "Usage Radar" : "Model Radar")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .textCase(.uppercase)

                            Text(viewMode == .agents
                                ? "See which agents are burning tokens, shifting models, and driving cost right now."
                                : "See which LLMs are driving cost, and which agents rely on them.")
                                .font(DesignSystem.Typography.display)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(heroSubheadline)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }

                        Spacer(minLength: DesignSystem.Spacing.lg)

                        VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                            Text("Selected Window")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                            Text(selectedTimeRange.displayName)
                                .font(DesignSystem.Typography.mono)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }
                    }

                    HStack(spacing: DesignSystem.Spacing.md) {
                        metricChip(label: "Sessions", value: "\(filteredUsages.count)")
                        if viewMode == .agents {
                            metricChip(label: "Active Providers", value: "\(activeProviderCount)")
                            metricChip(label: "Top Provider", value: topProviderSummary?.provider.displayName ?? "None")
                        } else {
                            metricChip(label: "Active Models", value: "\(dashboardModelSummaries.count)")
                            metricChip(label: "Top Model", value: dashboardModelSummaries.first?.displayName ?? "None")
                        }
                    }
                }
                .padding(DesignSystem.Spacing.xl)

                Circle()
                    .fill(DesignSystem.Colors.accentGradient.opacity(0.16))
                    .frame(width: 220, height: 220)
                    .blur(radius: 50)
                    .offset(x: 40, y: 50)
            }
        }
    }

    private var databaseCTA: some View {
        Button {
            withAnimation(DesignSystem.Animation.standard) {
                navigate(to: .database)
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.blaze.opacity(0.15))
                        .frame(width: 36, height: 36)

                    Image(systemName: "cylinder.split.1x2.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.blaze)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Database")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Corpus, search coverage, and system truth")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.blaze)
            }
            .padding(DesignSystem.Spacing.md)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.blaze.opacity(0.04))
                }
            }
            .clipShape(.rect(cornerRadius: DesignSystem.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.blaze.opacity(0.2), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var trustStatusStrip: some View {
        GlassCard {
            HStack(spacing: DesignSystem.Spacing.lg) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text("Last scan: \(dataStore.lastRefresh?.formatted(date: .omitted, time: .shortened) ?? "never")")
                }

                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                    Text("\(activeProviderCount) active provider\(activeProviderCount == 1 ? "" : "s")")
                }

                if let agg = aggregator {
                    let healthy = agg.parserHealth.values.filter {
                        if case .healthy = $0 { return true }
                        return false
                    }.count
                    let total = agg.parserHealth.count
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 9))
                        Text("\(healthy)/\(total) parsers healthy")
                    }
                }

                Spacer()
            }
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
        }
    }

    private var statsRow: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            StatCard(
                title: "Today",
                value: settingsManager.formatUsageMetric(cost: dataStore.totalCostToday, tokens: dataStore.totalTokensToday),
                accent: DesignSystem.Colors.ember,
                detail: settingsManager.usageDisplayMode == .currency ? "Live spend" : "Tokens today",
                moodLabel: dataStore.moodLabel,
                moodColor: dataStore.moodColor,
                confidenceLabel: dataStore.hasEstimatedProviders ? "Includes estimates" : "Exact",
                confidenceColor: dataStore.hasEstimatedProviders ? DesignSystem.Colors.warning : DesignSystem.Colors.success
            )
            .opacity(overviewAppeared ? 1 : 0)
            .offset(y: overviewAppeared ? 0 : 8)
            .animation(DesignSystem.Animation.standard.delay(0), value: overviewAppeared)
            StatCard(
                title: "This Week",
                value: settingsManager.formatUsageMetric(cost: dataStore.totalCostThisWeek, tokens: dataStore.totalTokensThisWeek),
                accent: DesignSystem.Colors.amber,
                detail: "7-day window",
                moodLabel: nil,
                moodColor: nil
            )
            .opacity(overviewAppeared ? 1 : 0)
            .offset(y: overviewAppeared ? 0 : 8)
            .animation(DesignSystem.Animation.standard.delay(0.06), value: overviewAppeared)
            StatCard(
                title: "This Month",
                value: settingsManager.formatUsageMetric(cost: dataStore.totalCostThisMonth, tokens: dataStore.totalTokensThisMonth),
                accent: DesignSystem.Colors.blaze,
                detail: "Rolling 30 days",
                moodLabel: nil,
                moodColor: nil
            )
            .opacity(overviewAppeared ? 1 : 0)
            .offset(y: overviewAppeared ? 0 : 8)
            .animation(DesignSystem.Animation.standard.delay(0.12), value: overviewAppeared)
            StatCard(
                title: "All Time",
                value: settingsManager.formatUsageMetric(cost: dataStore.totalCostAllTime, tokens: dataStore.totalTokensAllTime),
                accent: DesignSystem.Colors.whimsy,
                detail: {
                    var parts: [String] = []
                    if deviceCount > 1 { parts.append("\(deviceCount) devices") }
                    if let refresh = dataStore.lastRefresh { parts.append("Updated \(refresh.formatted(date: .omitted, time: .shortened))") }
                    return parts.isEmpty ? "Historical total" : parts.joined(separator: " · ")
                }(),
                moodLabel: nil,
                moodColor: nil
            )
            .opacity(overviewAppeared ? 1 : 0)
            .offset(y: overviewAppeared ? 0 : 8)
            .animation(DesignSystem.Animation.standard.delay(0.18), value: overviewAppeared)
        }
    }

    private var providerLane: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Provider Ranking")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text("Cost, session volume, and token mix across all tracked agents.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }

                    Spacer()
                }

                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(Array(dashboardProviderSummaries.enumerated()), id: \.element.id) { index, summary in
                        ProviderCard(summary: summary, rank: index + 1) {
                            withAnimation(DesignSystem.Animation.standard) {
                                navigate(to: .provider(summary.provider))
                            }
                        }
                        .opacity(overviewAppeared ? 1 : 0)
                        .offset(y: overviewAppeared ? 0 : 8)
                        .animation(DesignSystem.Animation.standard.delay(Double(index) * 0.06), value: overviewAppeared)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(overviewAppeared ? 1 : 0)
        .offset(y: overviewAppeared ? 0 : 8)
        .animation(DesignSystem.Animation.standard.delay(0.24), value: overviewAppeared)
    }

    private var modelLane: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Model Ranking")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text("Cost, session volume, and agent mix across all tracked models.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }

                    Spacer()
                }

                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(Array(dashboardModelSummaries.enumerated()), id: \.element.id) { index, summary in
                        ModelCard(summary: summary, rank: index + 1) {
                            withAnimation(DesignSystem.Animation.standard) {
                                navigate(to: .model(summary.modelName))
                            }
                        }
                        .opacity(overviewAppeared ? 1 : 0)
                        .offset(y: overviewAppeared ? 0 : 8)
                        .animation(DesignSystem.Animation.standard.delay(Double(index) * 0.06), value: overviewAppeared)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(overviewAppeared ? 1 : 0)
        .offset(y: overviewAppeared ? 0 : 8)
        .animation(DesignSystem.Animation.standard.delay(0.24), value: overviewAppeared)
    }

    private var activityLane: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    Text("Recent Sessions")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    VStack(spacing: DesignSystem.Spacing.sm) {
                        ForEach(Array(filteredUsages.prefix(6))) { usage in
                            SessionPreviewRow(usage: usage, settingsManager: settingsManager)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .opacity(overviewAppeared ? 1 : 0)
            .offset(y: overviewAppeared ? 0 : 8)
            .animation(DesignSystem.Animation.standard.delay(0.28), value: overviewAppeared)

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    Text("Model Leaders")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    VStack(spacing: DesignSystem.Spacing.md) {
                        ForEach(Array(topModels.prefix(4).enumerated()), id: \.offset) { index, item in
                            HStack(spacing: DesignSystem.Spacing.md) {
                                Text("\(index + 1)")
                                    .font(DesignSystem.Typography.monoSmall)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .frame(width: 16, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.model)
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                                    Text(item.provider.displayName)
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }

                                Spacer()

                                Text(settingsManager.formatUsageMetric(cost: item.cost, tokens: item.tokens))
                                    .font(DesignSystem.Typography.monoSmall)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                            }
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .opacity(overviewAppeared ? 1 : 0)
            .offset(y: overviewAppeared ? 0 : 8)
            .animation(DesignSystem.Animation.standard.delay(0.34), value: overviewAppeared)
        }
        .frame(width: 320, alignment: .topLeading)
    }

    // MARK: - Computed

    private var dashboardDateRange: ClosedRange<Date>? {
        selectedTimeRange.dateRange()
    }

    /// Sidebar, overview rankings, and hero totals match the toolbar time window.
    private var dashboardProviderSummaries: [ProviderSummary] {
        dataStore.providerSummaries(in: dashboardDateRange)
    }

    private var dashboardModelSummaries: [ModelSummary] {
        dataStore.modelSummaries(in: dashboardDateRange)
    }

    private var totalCostForTimeRange: Double {
        dataStore.usages(in: dashboardDateRange).reduce(0) { $0 + $1.cost }
    }

    private var totalTokensForTimeRange: Int {
        dataStore.usages(in: dashboardDateRange).reduce(0) { $0 + $1.totalTokens }
    }

    private var filteredUsages: [TokenUsage] {
        dataStore.usages(in: dashboardDateRange)
    }

    private var activeProviderCount: Int {
        Set(filteredUsages.map(\.provider)).count
    }

    private var topProviderSummary: ProviderSummary? {
        dashboardProviderSummaries.max { $0.totalCost < $1.totalCost }
    }

    private var heroSubheadline: String {
        let refreshed = dataStore.lastRefresh?.formatted(date: .omitted, time: .shortened) ?? "never"
        return "\(filteredUsages.count) sessions tracked in the current window. Last refresh \(refreshed)."
    }

    private var topModels: [(model: String, provider: AgentProvider, cost: Double, tokens: Int)] {
        dashboardProviderSummaries
            .flatMap { summary in
                summary.modelBreakdown.map { model in
                    (model: model.modelName, provider: summary.provider, cost: model.cost, tokens: model.totalTokens)
                }
            }
            .sorted { $0.cost > $1.cost }
    }

    private func metricChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.45))
            }
        }
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), DesignSystem.Colors.border.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }

}
