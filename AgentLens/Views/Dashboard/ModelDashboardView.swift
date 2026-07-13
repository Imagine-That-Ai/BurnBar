import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Model Card

struct ModelCard: View {
    let summary: ModelSummary
    let rank: Int
    let onTap: () -> Void

    @Environment(SettingsManager.self) private var settingsManager

    private var theme: ProviderTheme { ProviderTheme.theme(forModel: summary.modelName) }

    var body: some View {
        UnifiedGlassCard(interactive: true) {
            HStack(spacing: UnifiedDesignSystem.Spacing.lg) {
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                    Text(String(format: "%02d", rank))
                            .font(UnifiedDesignSystem.Typography.mono)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

                        ZStack {
                            Circle()
                                .fill(theme.primaryColor.opacity(0.15))
                                .frame(width: 46, height: 46)

                            ModelProviderLogoView(
                                modelKey: summary.modelName,
                                size: 30,
                                fallbackSymbolColor: theme.primaryColor
                            )
                        }
                    }
                    .frame(width: 54, alignment: .leading)

                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
                        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                                    Text(summary.displayName)
                                        .font(UnifiedDesignSystem.Typography.headline)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                                        .lineLimit(1)

                                    UnifiedCacheHitRateBadge(efficiency: summary.cacheEfficiency)
                                }

                                Text("\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")")
                                    .font(UnifiedDesignSystem.Typography.caption)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens))
                                    .font(UnifiedDesignSystem.Typography.monoLarge)
                                    .foregroundStyle(theme.gradient)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                                    .allowsTightening(true)

                                Text(settingsManager.usageDisplayMode == .currency ? "total spend" : "total tokens")
                                    .font(UnifiedDesignSystem.Typography.tiny)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                            }
                        }

                        HStack(spacing: UnifiedDesignSystem.Spacing.xl) {
                            UnifiedMiniStat(label: "Input", value: formatTokens(summary.totalInputTokens))
                            UnifiedMiniStat(label: "Output", value: formatTokens(summary.totalOutputTokens))
                            UnifiedMiniStat(label: "Cache Hit", value: summary.cacheEfficiency.formattedHitRate)
                        }

                        if !rankedProviderBreakdown.isEmpty {
                            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                                Text("Used By")
                                    .font(UnifiedDesignSystem.Typography.tiny)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                    .textCase(.uppercase)

                                ForEach(Array(rankedProviderBreakdown.prefix(3).enumerated()), id: \.element.id) { _, pu in
                                    HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                                        Capsule()
                                            .fill(UnifiedDesignSystem.Colors.primary(for: pu.provider))
                                            .frame(width: 14, height: 5)

                                        Text(pu.provider.displayName)
                                            .font(UnifiedDesignSystem.Typography.caption)
                                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                            .lineLimit(1)

                                        Spacer()

                                        Text("\(providerSharePercentage(pu), specifier: "%.0f")%")
                                            .font(UnifiedDesignSystem.Typography.monoTiny)
                                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

                                        Text(pu.cacheEfficiency.formattedHitRate)
                                            .font(UnifiedDesignSystem.Typography.monoTiny)
                                            .foregroundStyle(CacheHitRateTier(pu.cacheEfficiency).color)
                                            .help("Cache hit rate when \(pu.provider.displayName) uses this model")

                                        Text("\(pu.sessionCount) sess.")
                                            .font(UnifiedDesignSystem.Typography.monoTiny)
                                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(UnifiedDesignSystem.Spacing.lg)
        }
        .onTapGesture(perform: onTap)
    }

    private var rankedProviderBreakdown: [ProviderUsage] {
        DashboardUsageRanking.sortedProviderUsages(
            summary.providerBreakdown,
            displayMode: settingsManager.usageDisplayMode
        )
    }

    private func providerSharePercentage(_ provider: ProviderUsage) -> Double {
        DashboardUsageRanking.providerUsagePercentage(
            provider,
            in: summary,
            displayMode: settingsManager.usageDisplayMode
        )
    }

    private func formatTokens(_ tokens: Int) -> String {
        tokens.formatAsTokens()
    }
}

// MARK: - Model Dashboard View

struct ModelDashboardView: View {
    let modelName: String
    let dataStore: DataStore
    let timeRange: TimeRange
    var onOpenSessionLog: ((ConversationJumpTarget) -> Void)?

    @Environment(SettingsManager.self) private var settingsManager
    @State private var selectedSession: TokenUsage?
    @State private var didLogScreenView = false
    @State private var contentVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: ProviderTheme { ProviderTheme.theme(forModel: modelName) }

    private var displayName: String {
        OpenBurnBarCore.TokenExtractionUtility.displayNameForModel(usages.first?.model ?? modelName)
    }

    var body: some View {
        ZStack {
            DetailLiquidGlassBackdrop(
                accent: theme.primaryColor,
                secondaryAccent: theme.accentColor
            )

            ScrollView {
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xl) {
                    modelHeader

                    if !usages.isEmpty {
                        analyticsDeck
                            .opacity(contentVisible ? 1 : 0)
                            .offset(y: contentVisible ? 0 : (reduceMotion ? 0 : 12))
                    }

                    sessionsSection
                        .opacity(contentVisible ? 1 : 0)
                        .offset(y: contentVisible ? 0 : (reduceMotion ? 0 : 18))
                }
                .frame(maxWidth: 1440)
                .padding(.horizontal, UnifiedDesignSystem.Spacing.xl)
                .padding(.top, UnifiedDesignSystem.Spacing.lg)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            if !didLogScreenView {
                didLogScreenView = true
                Analytics.shared.track(.screenViewed, ["surface": "dashboard_model", "is_first_view": .bool(true)])
            }

            if reduceMotion {
                contentVisible = true
            } else {
                withAnimation(.easeOut(duration: 0.42).delay(0.12)) {
                    contentVisible = true
                }
            }
        }
        .sheet(item: $selectedSession) { session in
            SessionDetailView(session: session, theme: theme, dataStore: dataStore, onOpenSessionLog: onOpenSessionLog)
        }
    }

    private var modelHeader: some View {
        DetailEntityHero(
            eyebrow: "Model",
            title: displayName,
            subtitle: "\(usages.count) sessions in the selected range",
            accent: theme.primaryColor,
            secondaryAccent: theme.accentColor,
            metrics: [
                DetailHeroMetric(
                    label: settingsManager.usageDisplayMode == .currency ? "Spend" : "Volume",
                    value: primaryMetric
                ),
                DetailHeroMetric(
                    label: settingsManager.usageDisplayMode == .currency ? "Avg session" : "Avg tokens",
                    value: averageSessionMetric
                ),
                DetailHeroMetric(label: "Top agent", value: topAgentName),
                DetailHeroMetric(label: "Cache hit", value: modelCacheEfficiency.formattedHitRate)
            ]
        ) {
            ModelProviderLogoView(
                modelKey: modelName,
                size: 48,
                fallbackSymbolColor: theme.primaryColor
            )
        }
        .id(modelName)
    }

    private var analyticsDeck: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.lg) {
                TokenBreakdownChart(usages: usages, theme: theme)
                    .frame(minWidth: 320, minHeight: 290)

                DailyTrendChart(
                    usages: usages,
                    theme: theme,
                    days: 30,
                    displayMode: settingsManager.usageDisplayMode
                )
                .frame(minWidth: 380, minHeight: 290)

                agentStackPanel
                    .frame(minWidth: 260, idealWidth: 290, maxWidth: 330, alignment: .topLeading)
            }

            VStack(spacing: UnifiedDesignSystem.Spacing.lg) {
                DailyTrendChart(
                    usages: usages,
                    theme: theme,
                    days: 30,
                    displayMode: settingsManager.usageDisplayMode
                )

                HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.lg) {
                    TokenBreakdownChart(usages: usages, theme: theme)
                    agentStackPanel
                }
            }
        }
    }

    private var agentStackPanel: some View {
        DetailLiquidGlassSurface(accent: theme.primaryColor) {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                DetailSectionHeader(
                    eyebrow: "Runtime",
                    title: "Agent mix",
                    subtitle: "Agents using this model now.",
                    accent: theme.primaryColor
                )

                if topAgents.isEmpty {
                    Text("No agent data")
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(topAgents.enumerated()), id: \.element.id) { index, usage in
                            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                                HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                                    Circle()
                                        .fill(UnifiedDesignSystem.Colors.primary(for: usage.provider))
                                        .frame(width: 7, height: 7)

                                    Text(usage.provider.displayName)
                                        .font(UnifiedDesignSystem.Typography.body)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(settingsManager.formatUsageMetric(cost: usage.cost, tokens: usage.totalTokens))
                                        .font(UnifiedDesignSystem.Typography.monoSmall)
                                        .foregroundStyle(theme.primaryColor)
                                }

                                HStack {
                                    Text("\(agentSharePercentage(usage), specifier: "%.0f")% of model usage")
                                        .font(UnifiedDesignSystem.Typography.tiny)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

                                    Spacer()

                                    Text("\(usage.sessionCount) sessions")
                                        .font(UnifiedDesignSystem.Typography.monoTiny)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                }
                            }
                            .padding(.vertical, UnifiedDesignSystem.Spacing.md)

                            if index < topAgents.count - 1 {
                                Divider().overlay(Color.white.opacity(0.08))
                            }
                        }
                    }
                }
            }
        }
    }

    private var sessionsSection: some View {
        DetailLiquidGlassSurface(accent: theme.primaryColor) {
            SessionLedgerSection(
                usages: usages,
                theme: theme,
                selectedSession: $selectedSession,
                onOpenUsage: { usage in
                    Task { @MainActor in
                        await openUsage(usage)
                    }
                },
                displayMode: settingsManager.usageDisplayMode,
                showsAgentBadge: true,
                footerCaption: "Search paths, models, and session ids for \(displayName). Groups use session start time within the selected range.",
                emptyLedger: {
                    VStack(spacing: UnifiedDesignSystem.Spacing.md) {
                        Image(systemName: "clock")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(theme.primaryColor.opacity(0.7))

                        Text("No sessions for this model in the selected range.")
                            .font(UnifiedDesignSystem.Typography.body)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, UnifiedDesignSystem.Spacing.xxl)
                }
            )
        }
    }

    // MARK: - Data

    private var usages: [TokenUsage] {
        if let range = timeRange.dateRange() {
            return dataStore.usages(forModel: modelName, in: range)
        }
        return dataStore.usages(forModel: modelName)
    }

    private var primaryMetric: String {
        let cost = modelSummary?.totalCost ?? usages.reduce(0) { $0 + $1.cost }
        let tokens = modelSummary?.totalTokens ?? usages.reduce(0) { $0 + $1.totalTokens }
        return settingsManager.formatUsageMetric(cost: cost, tokens: tokens)
    }

    private func openUsage(_ usage: TokenUsage) async {
        guard let target = await jumpTarget(for: usage) else {
            Analytics.shared.track(.dashboardSessionOpened, ["surface": "dashboard_model"])
            selectedSession = usage
            return
        }
        if let onOpenSessionLog {
            Analytics.shared.track(.dashboardSessionOpened, ["surface": "dashboard_model"])
            onOpenSessionLog(target)
        } else {
            Analytics.shared.track(.dashboardSessionOpened, ["surface": "dashboard_model"])
            selectedSession = usage
        }
    }

    private func jumpTarget(for usage: TokenUsage) async -> ConversationJumpTarget? {
        guard let conversation = await conversationForUsage(usage) else {
            return nil
        }
        let snippet = conversation.summary?.nonEmpty
            ?? conversation.summaryTitle?.nonEmpty
            ?? conversation.lastAssistantMessage
        return ConversationJumpTarget(
            conversation: conversation,
            snippet: snippet,
            startOffset: 0,
            endOffset: snippet.count,
            source: .retrieval
        )
    }

    private func conversationForUsage(_ usage: TokenUsage) async -> OpenBurnBarCore.ConversationRecord? {
        let conversationID = OpenBurnBarCore.ConversationRecord.stableId(provider: usage.provider, sessionId: usage.sessionId)
        if let conversation = try? await dataStore.fetchConversation(id: conversationID) {
            return conversation
        }

        return (try? await dataStore.fetchSessionLogSummaries(limit: 1000))?
            .first(where: { $0.sessionId == usage.sessionId && $0.provider == usage.provider })
    }

    private var averageSessionMetric: String {
        let count = modelSummary?.sessionCount ?? usages.count
        guard count > 0 else {
            return settingsManager.usageDisplayMode == .currency ? "$0.00" : "0"
        }
        if settingsManager.usageDisplayMode == .currency {
            return ((modelSummary?.totalCost ?? usages.reduce(0) { $0 + $1.cost }) / Double(count)).formatAsCost()
        }
        return ((modelSummary?.totalTokens ?? usages.reduce(0) { $0 + $1.totalTokens }) / count).formatAsTokenVolume()
    }

    private var topAgents: [ProviderUsage] {
        return Array(
            DashboardUsageRanking.sortedProviderUsages(
                modelSummary?.providerBreakdown ?? [],
                displayMode: settingsManager.usageDisplayMode
            )
            .prefix(5)
        )
    }

    private var topAgentName: String {
        topAgents.first?.provider.displayName ?? "None"
    }

    private func agentSharePercentage(_ provider: ProviderUsage) -> Double {
        guard let summary = modelSummary else { return 0 }
        return DashboardUsageRanking.providerUsagePercentage(
            provider,
            in: summary,
            displayMode: settingsManager.usageDisplayMode
        )
    }

    /// Aggregate cache reuse for this model in the active window.
    private var modelCacheEfficiency: CacheEfficiency {
        if let summary = modelSummary {
            return summary.cacheEfficiency
        }
        return CacheEfficiency.aggregate(usages)
    }

    private var modelSummary: ModelSummary? {
        dataStore
            .modelSummaries(for: timeRange)
            .first(where: { $0.modelName == modelName })
    }

    private func modelMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

            Text(value)
                .font(UnifiedDesignSystem.Typography.monoSmall)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        .background(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.82))
        .clipShape(.rect(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                .stroke(UnifiedDesignSystem.Colors.border.opacity(0.7), lineWidth: 0.5)
        )
    }
}
