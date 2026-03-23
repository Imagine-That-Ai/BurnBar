import SwiftUI

// MARK: - Dashboard Main Route

private enum DashboardMainRoute: Hashable {
    case overview
    case projects
    case provider(AgentProvider)
}

// MARK: - Dashboard View

struct DashboardView: View {
    @Bindable var dataStore: DataStore
    @Bindable private var settingsManager = SettingsManager.shared
    var aggregator: UsageAggregator?
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    @State private var mainRoute: DashboardMainRoute = .overview
    @State private var selectedTimeRange: TimeRange = .today
    @State private var showingSettings = false
    @State private var overviewAppeared = false
    @State private var sidebarAppeared = false
    @State private var chatPanelOpen = false
    @State private var showIndexingConsent = false
    @State private var showCLIConsentSheet = false
    @State private var chatController: ChatSessionController

    init(
        dataStore: DataStore,
        aggregator: UsageAggregator?,
        accountManager: AccountManager = .shared,
        cloudSyncService: CloudSyncService? = nil
    ) {
        self._dataStore = Bindable(dataStore)
        self.aggregator = aggregator
        self.accountManager = accountManager
        self.cloudSyncService = cloudSyncService
        _chatController = State(initialValue: ChatSessionController(dataStore: dataStore, settingsManager: SettingsManager.shared))
    }

    private var isScanning: Bool { aggregator?.isRefreshing ?? false }

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
                dataStore: dataStore
            )
        }
        .overlay(alignment: chatDockAlignment) {
            VStack(spacing: 12) {
                if chatPanelOpen {
                    ChatPanel(
                        controller: chatController,
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        onClose: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                chatPanelOpen = false
                                UserDefaults.standard.set(dataStore.usages.count, forKey: "lastSeenSessionCountForChatBadge")
                            }
                        }
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: chatController.dock == .bottom ? .bottom : (chatController.dock == .leading ? .leading : .trailing)).combined(with: .opacity),
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
            .padding(chatController.dock == .bottom ? EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20) : EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20))
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
    }

    private var chatDockAlignment: Alignment {
        switch chatController.dock {
        case .bottom: return .bottom
        case .leading: return .bottomLeading
        case .trailing: return .bottomTrailing
        }
    }

    private var hasNewInsightPulse: Bool {
        let n = UserDefaults.standard.integer(forKey: "lastSeenSessionCountForChatBadge")
        return dataStore.usages.count > n && !dataStore.usages.isEmpty
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                AppLogoView(size: 26)

                Text("BurnBar")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: DesignSystem.Spacing.md) {
                // Time range picker
                GlassPicker(
                    selection: $selectedTimeRange,
                    options: TimeRange.allCases
                )

                UsageModeToolbarPicker(selection: $settingsManager.usageDisplayMode)

                // Total for selected window (cost or tokens)
                GlassBadge {
                    Text(settingsManager.formatUsageMetric(cost: totalCostForTimeRange, tokens: totalTokensForTimeRange))
                        .font(DesignSystem.Typography.mono)
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                }

                // Scan button
                GlassToolbarButton(
                    icon: isScanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                    isLoading: isScanning,
                    label: "Scan",
                    action: {
                        guard let agg = aggregator else { return }
                        Task { await agg.refreshAll() }
                    }
                )

                // Settings
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
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

                        Text("Agent providers")
                            .font(DesignSystem.Typography.title)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text("Scan, compare spend, and drill into model behavior from one workspace.")
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
                            mainRoute = .overview
                        }
                    }

                    ForEach(Array(dataStore.providerSummaries.enumerated()), id: \.element.id) { index, summary in
                        SidebarItem(
                            provider: summary.provider,
                            isSelected: mainRoute == .provider(summary.provider),
                            primaryMetric: settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens),
                            totalCost: summary.totalCost,
                            sessionCount: summary.sessionCount
                        ) {
                            withAnimation(DesignSystem.Animation.standard) {
                                mainRoute = .provider(summary.provider)
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

                    SidebarProjectsRow(
                        isSelected: mainRoute == .projects,
                        projectCount: Set(dataStore.usages.map(\.projectName)).count
                    ) {
                        withAnimation(DesignSystem.Animation.standard) {
                            mainRoute = .projects
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

                if accountManager.isSignedIn, let cloudTotal = cloudSyncService?.cloudTotalCost {
                    CloudTotalCard(
                        localTotal: dataStore.totalCostAllTime,
                        cloudTotal: cloudTotal,
                        isSyncing: cloudSyncService?.isSyncing ?? false
                    )
                }

                if dataStore.providerSummaries.isEmpty {
                    Text("No providers found")
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
                if idx > 0 { mainRoute = order[idx - 1] }
            case .down, .right:
                if idx + 1 < order.count { mainRoute = order[idx + 1] }
            default:
                break
            }
        }
        .onKeyPress(.escape) {
            mainRoute = .overview
            return .handled
        }
        .onAppear { sidebarAppeared = true }
    }

    private var sidebarRouteOrder: [DashboardMainRoute] {
        var routes: [DashboardMainRoute] = [.overview]
        routes.append(contentsOf: dataStore.providerSummaries.map { .provider($0.provider) })
        routes.append(.projects)
        return routes
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch mainRoute {
        case .overview:
            overviewView
        case .projects:
            ProjectsView(dataStore: dataStore)
        case .provider(let provider):
            ProviderDashboardView(
                provider: provider,
                dataStore: dataStore,
                timeRange: selectedTimeRange
            )
        }
    }

    // MARK: - Overview

    private var overviewView: some View {
        ScrollView {
            if dataStore.providerSummaries.isEmpty {
                emptyOverviewView
            } else {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    trustStatusStrip
                    NarrativeCardView(dataStore: dataStore)
                    overviewHero

                    statsRow

                    HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                        providerLane
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
                                DesignSystem.Colors.coral.opacity(0.18),
                                DesignSystem.Colors.purple.opacity(0.12),
                                DesignSystem.Colors.teal.opacity(0.08),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            Text("Usage Radar")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .textCase(.uppercase)

                            Text("See which agents are burning tokens, shifting models, and driving cost right now.")
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
                        metricChip(label: "Active Providers", value: "\(activeProviderCount)")
                        metricChip(label: "Top Provider", value: topProviderSummary?.provider.displayName ?? "None")
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
                accent: DesignSystem.Colors.coral,
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
                accent: DesignSystem.Colors.purple,
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
                accent: DesignSystem.Colors.teal,
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
                accent: DesignSystem.Colors.gold,
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
                    ForEach(Array(dataStore.providerSummaries.enumerated()), id: \.element.id) { index, summary in
                        ProviderCard(summary: summary, rank: index + 1) {
                            withAnimation(DesignSystem.Animation.standard) {
                                mainRoute = .provider(summary.provider)
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

    private var totalCostForTimeRange: Double {
        guard let range = selectedTimeRange.dateRange() else {
            return dataStore.totalCostAllTime
        }
        return dataStore.usages
            .filter { range.contains($0.startTime) }
            .reduce(0) { $0 + $1.cost }
    }

    private var totalTokensForTimeRange: Int {
        guard let range = selectedTimeRange.dateRange() else {
            return dataStore.totalTokensAllTime
        }
        return dataStore.usages
            .filter { range.contains($0.startTime) }
            .reduce(0) { $0 + $1.totalTokens }
    }

    private var filteredUsages: [TokenUsage] {
        guard let range = selectedTimeRange.dateRange() else {
            return dataStore.usages
        }
        return dataStore.usages.filter { range.contains($0.startTime) }
    }

    private var activeProviderCount: Int {
        Set(filteredUsages.map(\.provider)).count
    }

    private var topProviderSummary: ProviderSummary? {
        dataStore.providerSummaries.max { $0.totalCost < $1.totalCost }
    }

    private var heroSubheadline: String {
        let refreshed = dataStore.lastRefresh?.formatted(date: .omitted, time: .shortened) ?? "never"
        return "\(filteredUsages.count) sessions tracked in the current window. Last refresh \(refreshed)."
    }

    private var topModels: [(model: String, provider: AgentProvider, cost: Double, tokens: Int)] {
        dataStore.providerSummaries
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
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.82))
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.7), lineWidth: 0.5)
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
                        .foregroundStyle(DesignSystem.Colors.teal)
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
                        .foregroundStyle(DesignSystem.Colors.teal)

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
    let totalCost: Double
    let sessionCount: Int
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
                    if provider?.supportLevel == .unsupported && totalCost == 0 {
                        Text("Not tracked")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
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
                        .fill(isSelected ? DesignSystem.Colors.teal.opacity(0.18) : DesignSystem.Colors.surfaceElevated)
                        .frame(width: 34, height: 34)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? DesignSystem.Colors.teal : DesignSystem.Colors.textSecondary)
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
                    .foregroundStyle(isSelected ? DesignSystem.Colors.teal.opacity(0.8) : DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(isSelected ? DesignSystem.Colors.teal.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? DesignSystem.Colors.teal.opacity(0.3) : DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
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
            .background(DesignSystem.Colors.surface)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
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
            .background(DesignSystem.Colors.surfaceElevated)
            .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
            )
    }
}

// MARK: - Glass Toolbar Button

private struct GlassToolbarButton: View {
    let icon: String
    var isLoading: Bool = false
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(label)
                    .font(DesignSystem.Typography.caption)
            }
            .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.75))
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(DesignSystem.Colors.surfaceElevated)
            .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .help("Scan agent logs for new sessions")
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
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.7))
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func formatTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
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
            .background(DesignSystem.Colors.surface)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
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
            LinearGradient(
                colors: [
                    DesignSystem.Colors.background,
                    DesignSystem.Colors.background,
                    DesignSystem.Colors.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            BracketSwarmBackground(moodBand: moodBand)
                .ignoresSafeArea()
                .opacity(0.68)
                .allowsHitTesting(false)

            RadialGradient(
                colors: [
                    DesignSystem.Colors.coral.opacity(0.08),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 40,
                endRadius: 520
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    DesignSystem.Colors.teal.opacity(0.07),
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
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    guard !swarms.isEmpty else { return }
                    let time = timeline.date.timeIntervalSinceReferenceDate * speedMultiplier
                    let palettes = bracePalettes

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
                            let palette = palettes[brace.paletteIndex % palettes.count]
                            let point = CGPoint(
                                x: swarm.radius + brace.x,
                                y: swarm.radius + brace.y
                            )
                            let glyph = Text(brace.isOpen ? "{" : "}")
                                .font(.system(size: brace.size, weight: .ultraLight, design: .rounded))

                            var glowContext = swarmContext
                            glowContext.opacity = brace.opacity * 0.5
                            glowContext.addFilter(.shadow(color: palette.glow, radius: 6, x: 0, y: 0))
                            glowContext.draw(glyph.foregroundStyle(palette.glow), at: point, anchor: .center)

                            var primaryContext = swarmContext
                            primaryContext.opacity = brace.opacity
                            primaryContext.draw(glyph.foregroundStyle(palette.primary), at: point, anchor: .center)
                        }
                    }
                }
            }
            .onAppear {
                regenerateSwarmsIfNeeded(size: proxy.size)
            }
            .onChange(of: proxy.size) { _, newSize in
                regenerateSwarmsIfNeeded(size: newSize)
            }
            .onChange(of: moodBand) { _, _ in
                regenerateSwarmsIfNeeded(size: proxy.size, force: true)
            }
        }
    }

    private var bracePalettes: [DashboardBracePalette] {
        [
            DashboardBracePalette(
                primary: DesignSystem.Colors.purple.opacity(0.64),
                glow: DesignSystem.Colors.purple.opacity(0.28)
            ),
            DashboardBracePalette(
                primary: DesignSystem.Colors.coral.opacity(0.58),
                glow: DesignSystem.Colors.coral.opacity(0.24)
            ),
            DashboardBracePalette(
                primary: DesignSystem.Colors.teal.opacity(0.54),
                glow: DesignSystem.Colors.teal.opacity(0.22)
            ),
            DashboardBracePalette(
                primary: DesignSystem.Colors.gold.opacity(0.50),
                glow: DesignSystem.Colors.gold.opacity(0.18)
            ),
        ]
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
        let swarmCount = max(2, Int(4 * densityMultiplier))
        let bracesPerSwarm = max(12, Int(42 * densityMultiplier))
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

                braces.append(
                    DashboardBraceSpec(
                        x: x,
                        y: y,
                        size: CGFloat.random(in: 12...24),
                        paletteIndex: Int.random(in: 0..<bracePalettes.count),
                        isOpen: Bool.random(),
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
    let size: CGFloat
    let paletteIndex: Int
    let isOpen: Bool
    let opacity: Double
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
