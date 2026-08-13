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
    @Bindable private var settingsManager = SettingsManager.shared
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
    @State private var sidebarAppeared = false
    @State private var chatPanelOpen = false
    @State private var showIndexingConsent = false
    @State private var showCLIConsentSheet = false
    @State private var showSessionLogCloudConsent = false
    @State private var chatController: ChatSessionController
    @State private var quotaService = ProviderQuotaService.shared

    init(
        dataStore: DataStore,
        aggregator: UsageAggregator?,
        accountManager: AccountManager = .shared,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil
    ) {
        self._dataStore = Bindable(dataStore)
        self.aggregator = aggregator
        self.accountManager = accountManager
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
        _chatController = State(initialValue: ChatSessionController(dataStore: dataStore, settingsManager: SettingsManager.shared))
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

    /// Opens Cursor’s extension install flow for BurnBar (`extensions/burnbar` package id).
    private func openBurnBarCursorExtension() {
        let id = "burnbar.burnbar"
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
        .overlay {
            GeometryReader { geo in
                VStack(spacing: 12) {
                    if chatPanelOpen {
                        ChatPanel(
                            controller: chatController,
                            dataStore: dataStore,
                            settingsManager: settingsManager,
                            sharedFeaturesAvailable: accountManager.isSignedIn,
                            containerSize: geo.size,
                            edgePadding: 20,
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20))
            }
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
            Text("BurnBar can index your conversation history for search and chat. This data stays on your Mac.")
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
        .onReceive(NotificationCenter.default.publisher(for: .burnBarOpenConversationSearch)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                chatPanelOpen = true
            }
        }
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
                Text("BurnBar")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("BurnBar")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("", selection: $viewMode) {
                ForEach(DashboardViewMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
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
                        ProgressView()
                            .controlSize(.mini)
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
                        sessionCount: filteredUsages.count
                    ) {
                        withAnimation(DesignSystem.Animation.standard) {
                            routeHistory.removeAll()
                            mainRoute = .overview
                        }
                    }

                    if viewMode == .agents {
                        ForEach(Array(dashboardSidebarProviderSummaries.enumerated()), id: \.element.id) { index, summary in
                            SidebarItem(
                                provider: summary.provider,
                                isSelected: mainRoute == .provider(summary.provider),
                                primaryMetric: settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens),
                                sessionCount: summary.sessionCount,
                                hasUsageData: summary.hasUsageData
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

                    SidebarDatabaseRow(isSelected: mainRoute == .database) {
                        withAnimation(DesignSystem.Animation.standard) {
                            navigate(to: .database)
                        }
                    }
                    .focusable()

                    SidebarProjectsRow(
                        isSelected: mainRoute == .projects,
                        projectCount: Set(filteredUsages.map(\.projectName)).count
                    ) {
                        withAnimation(DesignSystem.Animation.standard) {
                            navigate(to: .projects)
                        }
                    }
                    .focusable()

                    SidebarSessionLogsRow(isSelected: mainRoute == .sessionLogs) {
                        withAnimation(DesignSystem.Animation.standard) {
                            navigate(to: .sessionLogs)
                        }
                    }
                    .focusable()
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
                                    Text("Add BurnBar to Cursor")
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
                        .help("Install BurnBar in Cursor (burnbar.burnbar)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                }

                if accountManager.isSignedIn, let cloudTotal = cloudSyncService?.cloudTotalCost {
                    CloudTotalCard(
                        localTotal: dataStore.totalCostAllTime,
                        cloudTotal: cloudTotal,
                        isSyncing: cloudSyncService?.isSyncing ?? false
                    )
                }

                if viewMode == .agents ? dashboardSidebarProviderSummaries.isEmpty : dashboardModelSummaries.isEmpty {
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
            routes.append(contentsOf: dashboardSidebarProviderSummaries.map { .provider($0.provider) })
        } else {
            routes.append(contentsOf: dashboardModelSummaries.map { .model($0.modelName) })
        }
        routes.append(.database)
        routes.append(.projects)
        routes.append(.sessionLogs)
        return routes
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
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
                ProjectsView(dataStore: dataStore)
            case .sessionLogs:
                SessionLogsView(
                    dataStore: dataStore,
                    accountManager: accountManager,
                    settingsManager: settingsManager,
                    cloudSyncService: cloudSyncService,
                    iCloudMirrorService: iCloudSessionMirrorService
                )
            case .provider(let provider):
                ProviderDashboardView(
                    provider: provider,
                    dataStore: dataStore,
                    timeRange: selectedTimeRange
                )
            case .model(let modelName):
                ModelDashboardView(
                    modelName: modelName,
                    dataStore: dataStore,
                    timeRange: selectedTimeRange
                )
            }
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
    }

    // MARK: - Overview

    private var overviewView: some View {
        ScrollView {
            if dashboardProviderSummaries.isEmpty && dashboardModelSummaries.isEmpty {
                emptyOverviewView
            } else {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    trustStatusStrip
                    NarrativeCardView(dataStore: dataStore)
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
        .onAppear { overviewAppeared = true }
    }

    private var emptyOverviewView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Image(systemName: "cpu")
                .font(.system(size: 64))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text("No sessions recorded")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("BurnBar will automatically import sessions from your configured agent logs.\nClick Scan to import now.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.xxl)

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
                moodColor: dataStore.moodColor
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
                detail: dataStore.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Historical total",
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
    /// Agents-mode sidebar entries: data-bearing providers plus explicit
    /// zero-data entries so honest no-op providers (grokBot) stay reachable
    /// and labeled — never hidden, never fabricated (VAL-PROV-019).
    private var dashboardSidebarProviderSummaries: [ProviderSummary] {
        dataStore.providerSummariesIncludingZeroData(in: dashboardDateRange)
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

// MARK: - Cloud Total Card

private struct CloudTotalCard: View {
    let localTotal: Double
    let cloudTotal: Double
    let isSyncing: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.whimsy)
                    Text("All devices (90 days)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .textCase(.uppercase)

                    Spacer()

                    if isSyncing {
                        ProgressView().controlSize(.mini)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
                    Text(cloudTotal.formatAsCost())
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.whimsy)

                    Text("vs \(localTotal.formatAsCost()) local")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

}

// MARK: - Sidebar Item

private struct SidebarItem: View {
    let provider: AgentProvider?
    let isSelected: Bool
    let primaryMetric: String
    let sessionCount: Int
    /// False for explicit zero-data entries (no usage rows in the window):
    /// those render typed support/confidence copy, never bare zeros
    /// (VAL-PROV-010, round-2 scrutiny).
    var hasUsageData: Bool = true
    let action: () -> Void

    private var theme: ProviderTheme {
        provider.map { ProviderTheme.theme(for: $0) } ?? ProviderTheme.theme(for: .factory)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(isSelected ? theme.primaryColor.opacity(0.18) : DesignSystem.Colors.surfaceElevated)
                        .frame(width: 34, height: 34)

                    if let provider {
                        ProviderLogoView(provider: provider, size: 22, useFallbackColor: false)
                    } else {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider?.displayName ?? "All Providers")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)

                    Text("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if !hasUsageData, let provider {
                        Text(ProviderSidebarLabel.metricLabel(provider: provider, hasUsageData: hasUsageData, primaryMetric: primaryMetric))
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(isSelected ? theme.primaryColor : DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                    } else {
                        Text(primaryMetric)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(isSelected ? theme.primaryColor : DesignSystem.Colors.textMuted)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.primaryColor.opacity(0.8) : DesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(isSelected ? theme.primaryColor.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? theme.primaryColor.opacity(0.3) : DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model Sidebar Item

private struct ModelSidebarItem: View {
    let summary: ModelSummary
    let isSelected: Bool
    let action: () -> Void

    @Bindable private var settingsManager = SettingsManager.shared

    private var theme: ProviderTheme { ProviderTheme.theme(forModel: summary.modelName) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(isSelected ? theme.primaryColor.opacity(0.18) : DesignSystem.Colors.surfaceElevated)
                        .frame(width: 34, height: 34)

                    ModelProviderLogoView(
                        modelKey: summary.modelName,
                        size: 22,
                        fallbackSymbolColor: isSelected ? theme.primaryColor : DesignSystem.Colors.textSecondary
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                        .lineLimit(1)

                    Text("\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens))
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(isSelected ? theme.primaryColor : DesignSystem.Colors.textMuted)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.primaryColor.opacity(0.8) : DesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(isSelected ? theme.primaryColor.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? theme.primaryColor.opacity(0.3) : DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sidebar Database Row

private struct SidebarDatabaseRow: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(isSelected ? DesignSystem.Colors.blaze.opacity(0.18) : DesignSystem.Colors.surfaceElevated)
                        .frame(width: 34, height: 34)

                    Image(systemName: "cylinder.split.1x2.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? DesignSystem.Colors.blaze : DesignSystem.Colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Database")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)

                    Text("Corpus, search & system truth")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? DesignSystem.Colors.blaze.opacity(0.8) : DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(isSelected ? DesignSystem.Colors.blaze.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? DesignSystem.Colors.blaze.opacity(0.3) : DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sidebar Projects Row

private struct SidebarProjectsRow: View {
    let isSelected: Bool
    let projectCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(isSelected ? DesignSystem.Colors.amber.opacity(0.18) : DesignSystem.Colors.surfaceElevated)
                        .frame(width: 34, height: 34)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? DesignSystem.Colors.amber : DesignSystem.Colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Projects")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)

                    Text("\(projectCount) project\(projectCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? DesignSystem.Colors.amber.opacity(0.8) : DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(isSelected ? DesignSystem.Colors.amber.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? DesignSystem.Colors.amber.opacity(0.3) : DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sidebar Session Logs Row

private struct SidebarSessionLogsRow: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(isSelected ? DesignSystem.Colors.ember.opacity(0.18) : DesignSystem.Colors.surfaceElevated)
                        .frame(width: 34, height: 34)

                    Image(systemName: "scroll.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? DesignSystem.Colors.ember : DesignSystem.Colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Session Logs")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)

                    Text("Full transcripts & chat history")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? DesignSystem.Colors.ember.opacity(0.8) : DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(isSelected ? DesignSystem.Colors.ember.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? DesignSystem.Colors.ember.opacity(0.3) : DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let title: String
    let value: String
    let accent: Color
    let detail: String
    var moodLabel: String?
    var moodColor: Color?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(title)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                Text(value)
                    .font(DesignSystem.Typography.monoLarge)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.gentle, value: value)

                if let moodLabel, let moodColor {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Circle()
                            .fill(moodColor)
                            .frame(width: 6, height: 6)
                        Text(moodLabel)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(moodColor)
                    }
                }

                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.lg)
        }
    }
}

// MARK: - Glass Picker

private struct GlassPicker<Option: Identifiable & Hashable>: View {
    @Binding var selection: Option
    let options: [Option]

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option
                } label: {
                    HStack {
                        Text(optionLabel(option))
                        if optionLabel(option) == selectionLabel(selection) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(selectionLabel(selection))
                    .font(DesignSystem.Typography.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.5))
                }
            }
            .foregroundStyle(DesignSystem.Colors.textPrimary)
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
        .menuStyle(.borderlessButton)
    }

    private func selectionLabel(_ option: Option) -> String {
        if let tr = option as? TimeRange { return tr.displayName }
        return "\(option)"
    }

    private func optionLabel(_ option: Option) -> String {
        if let tr = option as? TimeRange { return tr.displayName }
        return "\(option)"
    }
}

// MARK: - Glass Badge

struct GlassBadge<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.5))
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

#Preview {
    DashboardView(dataStore: DataStore(), aggregator: nil)
}

private struct SessionPreviewRow: View {
    let usage: TokenUsage
    @Bindable var settingsManager: SettingsManager

    private var theme: ProviderTheme { .theme(for: usage.provider) }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(usage.projectName)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)

                Text("\(usage.provider.displayName) • \(usage.model)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(formatTime(usage.startTime))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(theme.primaryColor)

                Text(settingsManager.formatUsageMetric(cost: usage.cost, tokens: usage.totalTokens))
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.gentle, value: usage.id)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
            }
        }
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.1), DesignSystem.Colors.border.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }

    private func formatTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Summarizing Status Strip

// MARK: - Mining Pick Animation

/// Renders the animated_mining_pick.svg using WKWebView so CSS @keyframes play natively.
struct AnimatedMiningPickView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.loadHTMLString(Self.html, baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    // swiftlint:disable line_length
    private static let html = """
    <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden;width:100%;height:100%;}svg{display:block;width:100%;height:100%;}</style>
    </head><body>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 250 250">
    <style>
    @keyframes swing{0%{transform:rotate(-20deg)}30%{transform:rotate(35deg)}35%{transform:rotate(30deg)}40%{transform:rotate(35deg)}60%{transform:rotate(-20deg)}100%{transform:rotate(-20deg)}}
    @keyframes impact{0%,29%{transform:scale(1) translate(0,0)}30%{transform:scale(1.05) translate(5px,2px)}35%{transform:scale(.98) translate(-1px,-1px)}40%{transform:scale(1) translate(0,0)}}
    #pickaxe{transform-origin:20px 180px;animation:swing 2s ease-in-out infinite}
    #ore{transform-origin:180px 150px;animation:impact 2s ease-in-out infinite}
    .spark{opacity:0;transform-origin:175px 130px}
    .s1{animation:spark1 2s ease-out infinite}.s2{animation:spark2 2s ease-out infinite}.s3{animation:spark3 2s ease-out infinite}.s4{animation:spark4 2s ease-out infinite}
    .s5{animation:spark5 2s ease-out infinite}.s6{animation:spark6 2s ease-out infinite}.s7{animation:spark7 2s ease-out infinite}.s8{animation:spark8 2s ease-out infinite}
    @keyframes spark1{0%,29%{opacity:0;transform:translate(0,0) scale(0)}30%{opacity:1;transform:translate(0,0) scale(2)}50%,100%{opacity:0;transform:translate(-70px,-80px) scale(0)}}
    @keyframes spark2{0%,29%{opacity:0;transform:translate(0,0) scale(0)}30%{opacity:1;transform:translate(0,0) scale(1.5)}48%,100%{opacity:0;transform:translate(-40px,-100px) scale(0)}}
    @keyframes spark3{0%,29%{opacity:0;transform:translate(0,0) scale(0)}30%{opacity:1;transform:translate(0,0) scale(2.5)}52%,100%{opacity:0;transform:translate(-10px,-110px) scale(0)}}
    @keyframes spark4{0%,29%{opacity:0;transform:translate(0,0) scale(0)}30%{opacity:1;transform:translate(0,0) scale(1.8)}47%,100%{opacity:0;transform:translate(40px,-90px) scale(0)}}
    @keyframes spark5{0%,29%{opacity:0;transform:translate(0,0) scale(0)}30%{opacity:1;transform:translate(0,0) scale(2.2)}50%,100%{opacity:0;transform:translate(-90px,-50px) scale(0)}}
    @keyframes spark6{0%,29%{opacity:0;transform:translate(0,0) scale(0)}30%{opacity:1;transform:translate(0,0) scale(2)}49%,100%{opacity:0;transform:translate(-110px,-20px) scale(0)}}
    @keyframes spark7{0%,29%{opacity:0;transform:translate(0,0) scale(0)}30%{opacity:1;transform:translate(0,0) scale(1.9)}51%,100%{opacity:0;transform:translate(-60px,-120px) scale(0)}}
    @keyframes spark8{0%,29%{opacity:0;transform:translate(0,0) scale(0)}30%{opacity:1;transform:translate(0,0) scale(1.6)}46%,100%{opacity:0;transform:translate(20px,-70px) scale(0)}}
    </style>
    <g id="ore">
    <path d="m136.6 110-1.13 5.56 12.24 6.29-11.11-11.85z" fill="#D14200"/>
    <path d="m127.7 120.8 26.69 10.3-25.31-3.59-1.38-6.71z" fill="#E79600"/>
    <path d="m162.8 102.1 5.1 4.06-1.82 15.92-3.28-19.98z" fill="#F4A916"/>
    <path d="m178 80.58 3.7 4.54-10.07 26.21 6.37-30.75z" fill="#D14200"/>
    <path d="m182.4 100.8 5.23 0.7-12.48 12.28 7.25-12.98z" fill="#E8492A"/>
    <path d="m231.2 127.9 2.33 4.53-10.86 7.21 5.7-11.74h2.83z" fill="#7A68D1"/>
    <path d="m247.4 156.2-2.36 7.31-17.33 6.57 19.69-13.88z" fill="#D14200"/>
    <path d="m233.4 175 2.1 2.84-3.02 2.56-8.87-3.04 9.79-2.36z" fill="#7A68D1"/>
    <path d="m127.3 137.1 3.39 7.62-4.81-2.08 1.42-5.54z" fill="#F4A916"/>
    <path d="m113.4 140.3 15.03 12.9-23.92-12.2 8.89-0.7z" fill="#7A68D1"/>
    <path d="m165.5 130.7 4.09 3.43-3.01 11.83-4.24-11.13 3.16-4.13z" fill="#D14200"/>
    <path d="m182.6 114.1 22.49-13.11 11.42 25.71-9.11 28.47 6.9-8.46 14.04 0.7 0.55 12.99-21.4 22.42 9.65 0.08 7.99 14.51-8.87 9.17h-17.1l-16.56 8.41-19.06-7.82-25.22 1.81-9.89-11.27 4.88-12.82 8.52-7.58-6.75-27.76 8.25-15.75 17.1 5.47 6.86 19.71 15.31-44.88z" fill="#7A68D1"/>
    <path d="m182.6 114.1 12.71 17.5 9.63-30.61-22.34 13.11z" fill="#D14200"/>
    <path d="m195.6 132 20.97-5.24-8.87 27.42-26.39 17.24 14.29-39.42z" fill="#C64800"/>
    <path d="m181.8 171.4 0.82-56.39 12.78 17.24-13.6 39.15z" fill="#8A78E0"/>
    <path d="m181.3 171.4-13.96-11.76 2.87-8.6 12.07-35.88-0.98 56.24z" fill="#7059C2"/>
    <path d="m143.2 134 15.81 5.64-9.25 14.81-14.42-5.24 7.86-15.21z" fill="#8A78E0"/>
    <path d="m135.1 149.6 15.11 5 11.04 27.14-17.02-5.31-9.13-26.83z" fill="#C64800"/>
    <path d="m159.4 139.7 8.19 19.93-6.4 22.16-11.34-27.43 9.55-14.66z" fill="#6A56BA"/>
    <path d="m181.3 171.4 24.86-16.74-7.85 28.2-17.01-11.46z" fill="#6752BA"/>
    <path d="m198.4 182.8 16.27-22.49 13.66-12.92 0.32 12.61-11.52 22.73-18.73 0.07z" fill="#6752BA"/>
    <path d="m214.7 160.3 0.39-13.62 13.27 0.7-13.66 12.92z" fill="#D14200"/>
    <path d="m198.3 182.8 8.44-22.8 8.37-13.23 3.85 12.89-20.66 23.14z" fill="#8A6FD3"/>
    <path d="m173.8 193.7 24.55-10.89-11.68 15.2-4.35 16.97-18.61-7.97 10.09-13.31z" fill="#D14F00"/>
    <path d="m198.3 182.8 9.88 11.61 16.92 2.98-8.95 9.25-17.1-0.7-0.75-23.14z" fill="#7059C2"/>
    <path d="m208.3 194.4 8.79-11.76 7.98 14.73-16.77-2.97z" fill="#9E88E5"/>
    <path d="m186.6 198 12.13 8.09-16.25 8.88 4.12-16.97z" fill="#7059C2"/>
    <path d="m173.8 193.7 24.55-11.26-7.4 10.38-3.85 5.79-13.3-4.91z" fill="#7A68D1"/>
    <path d="m161.2 181.8 20.09-10.4-7.54 22.12-10.24 13.69-2.31-25.41z" fill="#D15400"/>
    <path d="m132.9 185.4 12-7.71 4.96 13.88-21.46 6.42 4.5-12.59z" fill="#7A68D1"/>
    <path d="m138.3 208.9 11.64-17.46 13.73 14.99-25.37 2.47z" fill="#D15400"/>
    <path d="m149.9 191.5 13.66 14.68-2.39-24.37-11.27 9.69z" fill="#674799"/>
    <path d="m144.3 178-26.01-16.59 8.79-0.8 16.69 12.74 0.53 4.65z" fill="#7059C2"/>
    <path d="m118.6 162.1 7.35 4.37 0.15-5.42-7.5 1.05z" fill="#9081D9"/>
    <path d="m120.1 171.1 4.02-3.99 17.66 10.66-6.68 5.25-15-11.92z" fill="#D14F00"/>
    <path d="m115.2 181.1 9.25 0.5-6.32 2.84-2.93-3.34z" fill="#D14F00"/>
    </g>
    <g id="pickaxe">
    <path d="m52.34 35.95c19.41-3.43 37.71-1 64.02 11.76l2.36-1.47 3.44 0.46c2.51-1.13 5.87-0.54 7.87 2.12l4.82 4.62c2.21 2.28 1.91 5.87-0.6 7.83l2.28 3.8-0.89 1.88c17.32 19.27 24.77 35.23 23.81 61.29-5.27-18.65-17.72-36.63-32.23-47.29l-10.56 3.87-1.54-1.29c-13.37 14.18-26.5 26.41-35.09 39.91l-1.21 0.87-12.53-10.59 34.93-41.68 1.13-4.34 1.21-9.61c-14.21-10.9-29.24-17.99-51.22-22.14z" fill="#424A52"/>
    <path d="m54.05 35.8c18.93-0.62 39.67 3.53 59.87 14.43l-3.28 4.53c-13.37-8.98-30.98-15.74-56.59-18.96z" fill="#5A6470"/>
    <path d="m122.7 47.01c2.66-0.85 5.46 0.1 6.9 2.25l5.16 5.1c1.53 2.02 0.98 5.25-0.84 6.25l-9.45-7.89-1.77-5.71z" fill="#2B3036"/>
    <path d="m125.1 47.01c2 0 4.01 1.13 4.83 2.67l0.38 2.35-3.52 2.28-3.36-3.8 0.23-3.1c0.38-0.3 0.96-0.4 1.44-0.4z" fill="#424A52"/>
    <path d="m117.8 51.09 18.93 12.22-1.7 4.91c13.13 14.18 23.09 28.06 24.14 55.84-6.18-19.89-17.39-35.27-30.08-47.78l-11.94 8.13-14.98-13.88 15.63-19.44z" fill="#2B3036"/>
    <path d="m118.1 51.01 18.63 11.85-20.44 21.55-13.97-13.88 15.78-19.52z" fill="#3E4652"/>
    <path d="m63.34 114.1 14.6 9.64c1.21 0.86 0.83 2.12-0.15 3.04l-47.64 52.01c-0.89 0.95-2.02 0.65-3.01-0.48l-14.69 0.23-1.21-3.24c-0.38-1.54 0.38-2.86 1.51-4.1l49.33-56.23c0.56-0.67 0.63-1.19 1.26-0.87z" fill="#353A3D"/>
    <path d="m16.03 168.1 12.99 9.58-6.3 7.06c-2.93 1.88-6.01 1.03-7.7-0.84l-3.17-3.15c-1.54-1.96-1.84-5.65 0.6-7.22l3.58-5.43z" fill="#2B3036"/>
    <path d="m63.72 113.7 13.89 10.1c0.96 0.79 0.96 1.74 0 2.36l-47.23 51.06c-0.77 0.93-1.52 0.85-2.56-0.3l-11.49-9.24c-1.06-0.95-1.06-2.01 0.15-3.4l45.3-49.7c0.55-0.72 1.18-1.26 1.94-0.88z" fill="#E84953"/>
    <path d="m22.26 159.9 10.61 17.55-2.88 0.54-9.97-10.86c-1.2-1.31-1.51-2.09-0.62-3.39l2.86-3.84z" fill="#D82836"/>
    <path d="m27.74 149.9 18.86 1.79-1.75 11.61-22.44-4.04 5.33-9.36z" fill="#D14200"/>
    <path d="m37.81 140.2 8.66-1.13 2.14 16.96-20.24-3.97 9.44-11.86z" fill="#D14200"/>
    <path d="m45.26 133.1 5.09-4.86 8.94 5.57-1.13 13.96-6.51 6.79-10.48-16.55 4.09-4.91z" fill="#D14200"/>
    <path d="m50.16 127.5 6.4-5.46 20.6 2.9c1.41 0.3 1.11 1.15 0 2.28l-7.02 7.43-19.98-7.15z" fill="#D14200"/>
    <path d="m56.41 121.9 6.23-7.98 14.75 9.56c1.13 0.87 1.43 2.12 0.22 2.42l-21.2-4z" fill="#F0545B"/>
    <path d="m50.12 128 3.63 2 13.37 2.66 2.94 1.8-9.7 11.54-3.65-14.19-6.59-3.81z" fill="#C64800"/>
    <path d="m47.76 130.6 8.87 3.41 2.58 13.58-5.27 6.1-6.18-23.09z" fill="#D82836"/>
    <path d="m41.48 137.3 4.58 2.26 2 14.11-3.75-1.41-4.89-11.78 2.06-3.18z" fill="#E79600"/>
    <path d="m27.66 150.7 18.94 1.72-2.66 3.8-18.49-2.97 2.21-2.55z" fill="#E79600"/>
    <path d="m23.32 159.2 18.86 2.89-3.09 5.59-4.82-4.09-11.56-3.69 0.61-0.7z" fill="#E79600"/>
    </g>
    <g id="sparks">
    <circle class="spark s1" cx="175" cy="130" r="5" fill="#F45B69"/>
    <circle class="spark s2" cx="175" cy="130" r="7" fill="#FA5053"/>
    <circle class="spark s3" cx="175" cy="130" r="6" fill="#D49000"/>
    <circle class="spark s4" cx="175" cy="130" r="8" fill="#FFA800"/>
    <circle class="spark s5" cx="175" cy="130" r="5" fill="#D45800"/>
    <circle class="spark s6" cx="175" cy="130" r="6" fill="#E86100"/>
    <circle class="spark s7" cx="175" cy="130" r="5" fill="#6A5ACD"/>
    <circle class="spark s8" cx="175" cy="130" r="7" fill="#8B7FE8"/>
    </g>
    </svg>
    </body></html>
    """
    // swiftlint:enable line_length
}

// MARK: - Summarizing Status Strip

private struct SummarizingStatusStrip: View {
    let done: Int
    let total: Int
    let currentTitle: String
    /// Provider raw values that have completed at least one session this sweep.
    let completedProviders: [String]
    let onTap: () -> Void

    // Ore palette — matches the SVG's #D14200, #E79600, #7A68D1
    private static let oreColors: [Color] = [
        Color(red: 0.820, green: 0.259, blue: 0),
        Color(red: 0.906, green: 0.588, blue: 0.086),
        Color(red: 0.478, green: 0.408, blue: 0.820),
    ]

    private var progress: Double {
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // Animated pick
                    AnimatedMiningPickView()
                        .frame(width: 36, height: 36)

                    // Title + current session
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Mining sessions")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                            if total > 0 {
                                Text("·  \(done) of \(total)")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        if !currentTitle.isEmpty {
                            Text(currentTitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer()

                    // Provider logos for completed providers
                    if !completedProviders.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(Array(completedProviders.prefix(3)), id: \.self) { raw in
                                providerBadge(raw)
                            }
                        }
                    }

                    // Percentage
                    if total > 0 {
                        Text(String(format: "%.0f%%", progress * 100))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.906, green: 0.588, blue: 0.086))
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Ore-gradient progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.07))
                        LinearGradient(
                            colors: Self.oreColors,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: total > 0 ? geo.size.width * progress : 0)
                        .animation(.easeOut(duration: 0.35), value: done)
                    }
                }
                .frame(height: 3)
            }
        }
        .buttonStyle(.plain)
        .background(
            ZStack {
                Color.black.opacity(0.78)
                LinearGradient(
                    colors: [
                        Color(red: 0.820, green: 0.259, blue: 0).opacity(0.18),
                        Color(red: 0.478, green: 0.408, blue: 0.820).opacity(0.12),
                        Color.clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        )
        .overlay(alignment: .bottom) {
            // Ore-glow bottom border
            LinearGradient(
                colors: [
                    Color(red: 0.820, green: 0.259, blue: 0).opacity(0.7),
                    Color(red: 0.906, green: 0.588, blue: 0.086).opacity(0.5),
                    Color(red: 0.478, green: 0.408, blue: 0.820).opacity(0.6),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
    }

    @ViewBuilder
    private func providerBadge(_ rawValue: String) -> some View {
        let brand: LLMModelBrand = {
            switch SummaryProviderID(rawValue: rawValue) {
            case .openrouter: return .openAI
            case .minimax: return .miniMax
            case .zai: return .qwen
            case .mlx: return .apple
            case .local, nil: return .unknown
            }
        }()

        if let url = brand.logoURL {
            AsyncImage(url: url) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fit)
                } else {
                    Circle().fill(.white.opacity(0.15))
                }
            }
            .frame(width: 20, height: 20)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
        }
    }
}

// MARK: - Summary Progress Panel

private struct SummaryProgressPanel: View {
    let aggregator: UsageAggregator
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = SettingsManager.shared

    private static let oreGradient: [Color] = [
        Color(red: 0.820, green: 0.259, blue: 0),
        Color(red: 0.906, green: 0.588, blue: 0.086),
        Color(red: 0.478, green: 0.408, blue: 0.820),
    ]

    private var progress: Double {
        guard aggregator.summaryProgressTotal > 0 else { return 0 }
        return Double(aggregator.summaryProgressDone) / Double(aggregator.summaryProgressTotal)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────
            ZStack {
                Color.black.opacity(0.72)
                LinearGradient(
                    colors: [
                        Color(red: 0.820, green: 0.259, blue: 0).opacity(0.2),
                        Color(red: 0.478, green: 0.408, blue: 0.820).opacity(0.15),
                        Color.clear,
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: Self.oreGradient.map { $0.opacity(0.55) },
                               startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
            }
            .overlay {
                HStack(spacing: 10) {
                    AnimatedMiningPickView().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mining Sessions")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                        if aggregator.summaryProgressTotal > 0 {
                            Text("\(aggregator.summaryProgressDone) of \(aggregator.summaryProgressTotal) complete")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Spacer()
                    // Time remaining pill
                    if let remaining = aggregator.summaryTimeRemaining {
                        timePill(remaining)
                    }
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .frame(height: 64)

            // ── Ore-gradient progress bar ────────────────────────────────
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.07))
                    if aggregator.summaryProgressTotal > 0 {
                        LinearGradient(colors: Self.oreGradient, startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * progress)
                            .animation(.easeOut(duration: 0.35), value: aggregator.summaryProgressDone)
                    }
                }
            }
            .frame(height: 3)

            // ── Controls bar ─────────────────────────────────────────────
            HStack(spacing: 16) {
                // Concurrency stepper
                HStack(spacing: 0) {
                    stepButton(systemImage: "minus") {
                        settings.summaryMaxConcurrency = max(settings.summaryMaxConcurrency - 1, 1)
                    }
                    Text("\(settings.summaryMaxConcurrency)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 28)
                    stepButton(systemImage: "plus") {
                        settings.summaryMaxConcurrency = min(settings.summaryMaxConcurrency + 1, 32)
                    }
                }
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))

                Text("concurrent")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))

                Spacer()

                // Time limit stepper (0 = ∞)
                HStack(spacing: 0) {
                    stepButton(systemImage: "minus") {
                        settings.summaryTimeLimitMinutes = max(settings.summaryTimeLimitMinutes - 1, 0)
                    }
                    Group {
                        if settings.summaryTimeLimitMinutes == 0 {
                            Text("∞")
                        } else {
                            Text("\(settings.summaryTimeLimitMinutes)m")
                        }
                    }
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 32)
                    stepButton(systemImage: "plus") {
                        settings.summaryTimeLimitMinutes = min(settings.summaryTimeLimitMinutes + 1, 60)
                    }
                }
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))

                Text("time limit")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.45))

            Divider().background(.white.opacity(0.08))

            // ── Queue list ───────────────────────────────────────────────
            if aggregator.summaryQueue.isEmpty {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    AnimatedMiningPickView().frame(width: 48, height: 48)
                    Text("Building queue…")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(DesignSystem.Spacing.xl)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(aggregator.summaryQueue) { item in
                            queueRow(item)
                            Divider().background(.white.opacity(0.06))
                        }
                    }
                }
            }
        }
        .frame(width: 480)
        .frame(minHeight: 440)
        .background(Color.black.opacity(0.88))
    }

    // Countdown pill shown in the header when a time limit is active
    @ViewBuilder
    private func timePill(_ remaining: TimeInterval) -> some View {
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        let label = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(remaining < 30 ? Color(red: 0.906, green: 0.588, blue: 0.086) : .white.opacity(0.6))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.white.opacity(0.1), in: Capsule())
    }

    @ViewBuilder
    private func stepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
    }

    private static let oreAmber = Color(red: 0.906, green: 0.588, blue: 0.086)
    private static let oreOrange = Color(red: 0.820, green: 0.259, blue: 0)

    @ViewBuilder
    private func queueRow(_ item: SummaryQueueItem) -> some View {
        HStack(spacing: 12) {
            statusIcon(item.status).frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(item.status == .pending ? 0.4 : 0.85))
                    .lineLimit(1)
                if let provider = item.provider {
                    Text(provider)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                } else if item.status == .processing {
                    Text("processing…")
                        .font(.system(size: 10))
                        .foregroundStyle(Self.oreAmber)
                }
            }

            Spacer()
            statusBadge(item.status)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            item.status == .processing
                ? LinearGradient(
                    colors: [Self.oreOrange.opacity(0.12), Self.oreAmber.opacity(0.06)],
                    startPoint: .leading, endPoint: .trailing
                  )
                : LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing)
        )
    }

    @ViewBuilder
    private func statusIcon(_ status: SummaryQueueItem.Status) -> some View {
        switch status {
        case .pending:
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: 1.5)
                .frame(width: 16, height: 16)
        case .processing:
            // Mini animated pick
            Image("MiningPickIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color(red: 0.3, green: 0.8, blue: 0.4))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color(red: 0.9, green: 0.3, blue: 0.3))
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: SummaryQueueItem.Status) -> some View {
        switch status {
        case .pending:
            EmptyView()
        case .processing:
            Text("mining")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Self.oreOrange.opacity(0.25))
                .foregroundStyle(Self.oreAmber)
                .clipShape(Capsule())
        case .done:
            Text("done")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
        case .failed:
            Text("failed")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(red: 0.9, green: 0.3, blue: 0.3).opacity(0.7))
        }
    }
}

// MARK: - Usage mode (toolbar)

private struct UsageModeToolbarPicker: View {
    @Binding var selection: UsageDisplayMode

    var body: some View {
        Menu {
            ForEach(UsageDisplayMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    HStack {
                        Text(mode.label)
                        if selection == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(selection.label)
                    .font(DesignSystem.Typography.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.5))
                }
            }
            .foregroundStyle(DesignSystem.Colors.textPrimary)
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
        .menuStyle(.borderlessButton)
        .help("Show totals in USD or token volume")
    }
}

private struct DashboardBackdrop: View {
    let moodBand: MoodBand

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            BracketSwarmBackground(moodBand: moodBand)
                .ignoresSafeArea()
                .opacity(0.68)
                .allowsHitTesting(false)

            RadialGradient(
                colors: [
                    DesignSystem.Colors.ember.opacity(0.09),
                    DesignSystem.Colors.amber.opacity(0.04),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 40,
                endRadius: 520
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    DesignSystem.Colors.whimsy.opacity(0.06),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 80,
                endRadius: 560
            )
            .ignoresSafeArea()
        }
    }
}

struct BracketSwarmBackground: View {
    private static let braceSizes: [CGFloat] = [12, 14, 16, 18, 20, 22]
    private static let animationCadence: TimeInterval = 1.0 / 12.0

    var moodBand: MoodBand = .onPace

    @State private var swarms: [DashboardBraceSwarm] = []
    @State private var lastSize: CGSize = .zero

    private var densityMultiplier: Double {
        switch moodBand {
        case .light: return 0.5
        case .onPace: return 1.0
        case .heavy: return 1.8
        case .baseline, .quiet: return 0.7
        }
    }

    private var speedMultiplier: Double {
        switch moodBand {
        case .light: return 0.6
        case .onPace: return 1.0
        case .heavy: return 1.5
        case .baseline, .quiet: return 0.8
        }
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: Self.animationCadence)) { timeline in
                Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
                    guard !swarms.isEmpty else { return }
                    let time = timeline.date.timeIntervalSinceReferenceDate * speedMultiplier

                    for swarm in swarms {
                        let orbitPhase = (time / swarm.orbitDuration + swarm.orbitPhase) * .pi * 2
                        let breathePhase = (time / swarm.breatheDuration + swarm.breathePhase) * .pi * 2

                        let orbitX = sin(orbitPhase) * swarm.radius * 0.06
                        let orbitY = cos(orbitPhase) * swarm.radius * 0.05
                        let scale = 0.985 + 0.025 * sin(breathePhase)

                        var swarmContext = context
                        swarmContext.translateBy(
                            x: swarm.center.x + orbitX - swarm.radius,
                            y: swarm.center.y + orbitY - swarm.radius
                        )
                        swarmContext.scaleBy(x: scale, y: scale)

                        for brace in swarm.braces {
                            let point = CGPoint(
                                x: swarm.radius + brace.x,
                                y: swarm.radius + brace.y
                            )
                            guard let symbol = context.resolveSymbol(id: brace.symbolKey) else { continue }

                            var primaryContext = swarmContext
                            primaryContext.opacity = brace.opacity
                            primaryContext.draw(symbol, at: point, anchor: .center)
                        }
                    }
                } symbols: {
                    // Reuse a small set of brace glyph variants instead of re-resolving text every frame.
                    ForEach(braceSymbolKeys, id: \.self) { symbolKey in
                        braceSymbolView(for: symbolKey)
                            .tag(symbolKey)
                    }
                }
            }
            .onAppear {
                Task { @MainActor in
                    regenerateSwarmsIfNeeded(size: proxy.size)
                }
            }
            .onChange(of: proxy.size) { _, newSize in
                Task { @MainActor in
                    regenerateSwarmsIfNeeded(size: newSize)
                }
            }
            .onChange(of: moodBand) { _, _ in
                let size = proxy.size
                Task { @MainActor in
                    regenerateSwarmsIfNeeded(size: size, force: true)
                }
            }
        }
    }

    private var bracePalettes: [DashboardBracePalette] {
        [
            DashboardBracePalette(
                primary: DesignSystem.Colors.ember.opacity(0.58),
                glow: DesignSystem.Colors.ember.opacity(0.24)
            ),
            DashboardBracePalette(
                primary: DesignSystem.Colors.amber.opacity(0.54),
                glow: DesignSystem.Colors.amber.opacity(0.22)
            ),
            DashboardBracePalette(
                primary: DesignSystem.Colors.blaze.opacity(0.50),
                glow: DesignSystem.Colors.blaze.opacity(0.20)
            ),
            DashboardBracePalette(
                primary: DesignSystem.Colors.whimsy.opacity(0.48),
                glow: DesignSystem.Colors.whimsy.opacity(0.18)
            ),
        ]
    }

    private var braceSymbolKeys: [DashboardBraceSymbolKey] {
        bracePalettes.indices.flatMap { paletteIndex in
            Self.braceSizes.flatMap { size in
                [
                    DashboardBraceSymbolKey(size: Int(size.rounded()), paletteIndex: paletteIndex, isOpen: true),
                    DashboardBraceSymbolKey(size: Int(size.rounded()), paletteIndex: paletteIndex, isOpen: false)
                ]
            }
        }
    }

    @ViewBuilder
    private func braceSymbolView(for key: DashboardBraceSymbolKey) -> some View {
        let palette = bracePalettes[key.paletteIndex % bracePalettes.count]

        Text(key.isOpen ? "{" : "}")
            .font(.system(size: CGFloat(key.size), weight: .ultraLight, design: .rounded))
            .foregroundStyle(palette.primary.opacity(0.92))
            .shadow(color: palette.glow, radius: 3, x: 0, y: 0)
    }

    private func regenerateSwarmsIfNeeded(size: CGSize, force: Bool = false) {
        guard size != .zero else { return }
        if !force,
           abs(size.width - lastSize.width) < 1,
           abs(size.height - lastSize.height) < 1,
           !swarms.isEmpty {
            return
        }

        lastSize = size
        swarms = buildSwarms(size: size)
    }

    private func buildSwarms(size: CGSize) -> [DashboardBraceSwarm] {
        let swarmCount = max(2, Int(3 * densityMultiplier))
        let bracesPerSwarm = max(8, Int(18 * densityMultiplier))
        let padding: CGFloat = 80
        let width = max(size.width, padding * 2 + 1)
        let height = max(size.height, padding * 2 + 1)

        var result: [DashboardBraceSwarm] = []
        result.reserveCapacity(swarmCount)

        for _ in 0..<swarmCount {
            let radius = CGFloat.random(in: 90...190)
            let center = CGPoint(
                x: padding + CGFloat.random(in: 0...(width - padding * 2)),
                y: padding + CGFloat.random(in: 0...(height - padding * 2))
            )

            var braces: [DashboardBraceSpec] = []
            braces.reserveCapacity(bracesPerSwarm)

            for _ in 0..<bracesPerSwarm {
                let normalized = clampedGaussian()
                let angle = CGFloat.random(in: 0...(2 * .pi))
                let distance = radius * abs(normalized)
                let x = cos(angle) * distance
                let y = sin(angle) * distance * CGFloat.random(in: 0.8...1.2)
                let symbolSize = Self.braceSizes.randomElement() ?? 16
                let paletteIndex = Int.random(in: 0..<bracePalettes.count)

                braces.append(
                    DashboardBraceSpec(
                        x: x,
                        y: y,
                        symbolKey: DashboardBraceSymbolKey(
                            size: Int(symbolSize.rounded()),
                            paletteIndex: paletteIndex,
                            isOpen: Bool.random()
                        ),
                        opacity: Double.random(in: 0.14...0.32)
                    )
                )
            }

            result.append(
                DashboardBraceSwarm(
                    center: center,
                    radius: radius,
                    braces: braces,
                    orbitPhase: Double.random(in: 0...1),
                    orbitDuration: Double.random(in: 70...130),
                    breathePhase: Double.random(in: 0...1),
                    breatheDuration: Double.random(in: 10...18)
                )
            )
        }

        return result
    }

    private func clampedGaussian() -> CGFloat {
        var u: Double = 0
        var v: Double = 0
        while u == 0 { u = Double.random(in: 0...1) }
        while v == 0 { v = Double.random(in: 0...1) }
        return max(-1.15, min(1.15, CGFloat(sqrt(-2.0 * log(u)) * cos(2.0 * .pi * v)) / 3))
    }
}

private struct DashboardBracePalette {
    let primary: Color
    let glow: Color
}

private struct DashboardBraceSpec: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let symbolKey: DashboardBraceSymbolKey
    let opacity: Double
}

private struct DashboardBraceSymbolKey: Hashable {
    let size: Int
    let paletteIndex: Int
    let isOpen: Bool
}

private struct DashboardBraceSwarm: Identifiable {
    let id = UUID()
    let center: CGPoint
    let radius: CGFloat
    let braces: [DashboardBraceSpec]
    let orbitPhase: Double
    let orbitDuration: Double
    let breathePhase: Double
    let breatheDuration: Double
}
