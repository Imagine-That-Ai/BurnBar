import SwiftUI
import OpenBurnBarCore

struct CommunityView: View {
    let dataStore: DataStoreCoordinator
    let settingsManager: SettingsManager
    let accountManager: AccountManager
    let selectedTimeRange: TimeRange
    let usageWindow: DashboardUsageWindowSummary
    let topModels: [(model: String, provider: AgentProvider, cost: Double, tokens: Int)]

    @StateObject private var consentStore = CommunityConsentStore()
    @StateObject private var service = CommunityService()
    @StateObject private var viewModel: CommunityViewModel

    init(
        dataStore: DataStoreCoordinator,
        settingsManager: SettingsManager,
        accountManager: AccountManager,
        selectedTimeRange: TimeRange,
        usageWindow: DashboardUsageWindowSummary,
        topModels: [(model: String, provider: AgentProvider, cost: Double, tokens: Int)]
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.accountManager = accountManager
        self.selectedTimeRange = selectedTimeRange
        self.usageWindow = usageWindow
        self.topModels = topModels
        let consent = CommunityConsentStore()
        let svc = CommunityService()
        _consentStore = StateObject(wrappedValue: consent)
        _service = StateObject(wrappedValue: svc)
        _viewModel = StateObject(wrappedValue: CommunityViewModel(consentStore: consent, service: svc))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                personalHero
                leaderboardSection
                percentileStrip
                timeFilter
                peerComparisonChart
                purposeBreakdownSection
                CommunityConsentCenter(consentStore: consentStore, service: service)
            }
            .padding(DesignSystem.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.background)
        .task(id: taskRefreshKey) {
            await viewModel.refreshAll(usages: usageWindow.usages)
        }
    }

    private var taskRefreshKey: String {
        [
            selectedTimeRange.rawValue,
            String(accountManager.isSignedIn),
            service.remoteConsent?.updatedAt ?? "no-consent",
            service.profile?.updatedAt ?? "no-profile"
        ].joined(separator: "|")
    }

    // MARK: - Personal hero

    private var personalHero: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("Your burn")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settingsManager.formatUsageMetric(cost: usageWindow.totalCost, tokens: usageWindow.totalTokens))
                            .font(DesignSystem.Typography.title)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text(selectedTimeRange.displayName)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    Spacer()
                    modelMixColumn
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var modelMixColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("Model mix")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            ForEach(Array(topModels.prefix(3).enumerated()), id: \.offset) { _, row in
                Text("\(row.model) · \(row.cost.formatAsCost())")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Leaderboards

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Leaderboards")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            if !accountManager.isSignedIn {
                inviteOptInCard
            } else {
                ForEach(viewModel.tierBoards) { entry in
                    CommunityLeaderboardCard(
                        tier: entry.tier,
                        geoLabel: entry.geoLabel,
                        board: entry.board,
                        pinnedAnonId: viewModel.pinnedAnonId,
                        isLoading: viewModel.isLoadingBoards && entry.board == nil
                    )
                }
            }
        }
    }

    private var inviteOptInCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Compare with other burners")
                    .font(DesignSystem.Typography.headline)
                Text("Sign in and opt in below to see anonymized rankings. No pressure — everything stays off until you grant consent.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    // MARK: - Percentile strip

    private var percentileStrip: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Percentile strip")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                if let bands = viewModel.percentileBands(from: viewModel.tierBoards) {
                    HStack(spacing: DesignSystem.Spacing.md) {
                        percentileChip("p50", bands.p50)
                        percentileChip("p75", bands.p75)
                        percentileChip("p90", bands.p90)
                        percentileChip("p99", bands.p99)
                    }
                } else {
                    Text("Percentiles appear once your geography tier clears the privacy threshold.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func percentileChip(_ label: String, _ value: Double) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(formatTokenBand(value))
                .font(DesignSystem.Typography.caption.monospacedDigit())
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Time filter

    private var timeFilter: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Time window")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Picker("Window", selection: $viewModel.selectedWindow) {
                ForEach(CommunityLeaderboardWindow.allCases) { window in
                    Text(window.displayName).tag(window)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: viewModel.selectedWindow) { _, _ in
                Task { await viewModel.reloadBoards() }
            }
        }
    }

    // MARK: - Peer chart

    private var peerComparisonChart: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Peer comparison")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                let cohort = viewModel.cohortTokens(from: viewModel.tierBoards)
                if cohort.isEmpty {
                    Text("Anonymized cohort chart unlocks with a world leaderboard above the k-anonymity floor.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    let userTokens = usageWindow.totalTokens
                    let maxVal = max(cohort.max() ?? 1, userTokens, 1)
                    HStack(alignment: .bottom, spacing: 4) {
                        bar(height: barHeight(userTokens, max: maxVal), label: "You", highlight: true)
                        ForEach(Array(cohort.prefix(12).enumerated()), id: \.offset) { idx, value in
                            bar(height: barHeight(value, max: maxVal), label: "•", highlight: false)
                                .accessibilityLabel("Peer \(idx + 1)")
                        }
                    }
                    .frame(height: 80, alignment: .bottom)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func bar(height: CGFloat, label: String, highlight: Bool) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(highlight ? DesignSystem.Colors.ember : DesignSystem.Colors.whimsy.opacity(0.45))
                .frame(width: highlight ? 14 : 8, height: max(height, 4))
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func barHeight(_ value: Int, max: Int) -> CGFloat {
        CGFloat(value) / CGFloat(max) * 64
    }

    // MARK: - Purpose breakdown

    private var purposeBreakdownSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Purpose breakdown")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                if viewModel.purposeBreakdown.isEmpty {
                    Text("Run more sessions to infer how you use models (metadata only).")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    ForEach(viewModel.purposeBreakdown, id: \.category) { row in
                        HStack {
                            Text(row.category.rawValue.capitalized)
                                .font(DesignSystem.Typography.body)
                            Spacer()
                            Text("\(Int(row.share * 100))%")
                                .font(DesignSystem.Typography.caption.monospacedDigit())
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func formatTokenBand(_ value: Double) -> String {
        let n = Int(value)
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
