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

                        if !summary.providerBreakdown.isEmpty {
                            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                                Text("Used By")
                                    .font(UnifiedDesignSystem.Typography.tiny)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                    .textCase(.uppercase)

                                ForEach(Array(summary.providerBreakdown.prefix(3).enumerated()), id: \.element.id) { index, pu in
                                    HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                                        Capsule()
                                            .fill(UnifiedDesignSystem.Colors.primary(for: pu.provider))
                                            .frame(width: 14, height: 5)

                                        Text(pu.provider.displayName)
                                            .font(UnifiedDesignSystem.Typography.caption)
                                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                            .lineLimit(1)

                                        Spacer()

                                        Text("\(pu.percentage, specifier: "%.0f")%")
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

    private func formatTokens(_ tokens: Int) -> String {
        tokens.formatAsTokens()
    }
}

// MARK: - Model Dashboard View

struct ModelDashboardView: View {
    let modelName: String
    let dataStore: DataStore
    let timeRange: TimeRange
    var onOpenSessionLog: ((ConversationJumpTarget) -> Void)? = nil

    @Environment(SettingsManager.self) private var settingsManager
    @State private var selectedSession: TokenUsage?

    private var theme: ProviderTheme { ProviderTheme.theme(forModel: modelName) }

    private var displayName: String {
        TokenExtractionUtility.displayNameForModel(usages.first?.model ?? modelName)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                modelHeader

                if !usages.isEmpty {
                    analyticsDeck
                }

                sessionsSection
            }
            .padding(UnifiedDesignSystem.Spacing.xl)
        }
        .background {
            LinearGradient(
                colors: [
                    theme.primaryColor.opacity(0.06),
                    Color.clear,
                    theme.accentColor.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $selectedSession) { session in
            SessionDetailView(session: session, theme: theme, dataStore: dataStore, onOpenSessionLog: onOpenSessionLog)
        }
    }

    private var modelHeader: some View {
        UnifiedGlassCard {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.primaryColor.opacity(0.18),
                                theme.accentColor.opacity(0.12),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.xl) {
                    ZStack {
                        Circle()
                            .fill(theme.primaryColor.opacity(0.15))
                            .frame(width: 64, height: 64)

                        ModelProviderLogoView(
                            modelKey: modelName,
                            size: 40,
                            fallbackSymbolColor: theme.primaryColor
                        )
                    }

                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                        Text(displayName)
                            .font(UnifiedDesignSystem.Typography.display)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                        Text("\(usages.count) sessions in range")
                            .font(UnifiedDesignSystem.Typography.body)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)

                        HStack(spacing: UnifiedDesignSystem.Spacing.md) {
                            modelMetric(
                                label: settingsManager.usageDisplayMode == .currency ? "Spend" : "Volume",
                                value: primaryMetric
                            )
                            modelMetric(
                                label: settingsManager.usageDisplayMode == .currency ? "Avg session" : "Avg tokens",
                                value: averageSessionMetric
                            )
                            modelMetric(label: "Top Agent", value: topAgentName)
                            modelMetric(
                                label: "Cache Hit",
                                value: modelCacheEfficiency.formattedHitRate
                            )
                        }
                    }

                    Spacer()
                }
                .padding(UnifiedDesignSystem.Spacing.xl)

                Circle()
                    .fill(theme.gradient.opacity(0.22))
                    .frame(width: 180, height: 180)
                    .blur(radius: 45)
                    .offset(x: 26, y: 40)
            }
        }
    }

    private var analyticsDeck: some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.lg) {
            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.lg) {
                TokenBreakdownChart(usages: usages, theme: theme)
                    .frame(minHeight: 260)

                DailyTrendChart(usages: usages, theme: theme, days: 30, displayMode: settingsManager.usageDisplayMode)
                    .frame(minHeight: 260)
            }
            .frame(maxWidth: .infinity)

            agentStackPanel
                .frame(width: 280, alignment: .topLeading)
        }
    }

    private var agentStackPanel: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                Text("Agent Stack")
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                Text("Which agents use this model in the selected window.")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)

                if topAgents.isEmpty {
                    Text("No agent data")
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                } else {
                    VStack(spacing: UnifiedDesignSystem.Spacing.md) {
                        ForEach(Array(topAgents.enumerated()), id: \.element.id) { index, pu in
                            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                                HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                                    Capsule()
                                        .fill(UnifiedDesignSystem.Colors.primary(for: pu.provider))
                                        .frame(width: 16, height: 6)

                                    Text(pu.provider.displayName)
                                        .font(UnifiedDesignSystem.Typography.body)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(settingsManager.formatUsageMetric(cost: pu.cost, tokens: pu.totalTokens))
                                        .font(UnifiedDesignSystem.Typography.monoSmall)
                                        .foregroundStyle(theme.primaryColor)
                                }

                                HStack {
                                    Text("\(pu.percentage, specifier: "%.0f")% of model usage")
                                        .font(UnifiedDesignSystem.Typography.tiny)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

                                    Spacer()

                                    UnifiedCacheHitRateBadge(efficiency: pu.cacheEfficiency)

                                    Text("\(pu.sessionCount) sessions")
                                        .font(UnifiedDesignSystem.Typography.monoTiny)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                }
                            }
                            .padding(.bottom, UnifiedDesignSystem.Spacing.xs)
                        }
                    }
                }
            }
            .padding(UnifiedDesignSystem.Spacing.lg)
        }
    }

    private var sessionsSection: some View {
        UnifiedGlassCard {
            SessionLedgerSection(
                usages: usages,
                theme: theme,
                selectedSession: $selectedSession,
                onOpenUsage: openUsage,
                displayMode: settingsManager.usageDisplayMode,
                showsAgentBadge: true,
                footerCaption: "Search paths, models, and session ids for \(displayName). Groups use session start time within the range above."
            ) {
                VStack(spacing: UnifiedDesignSystem.Spacing.md) {
                    Image(systemName: "clock")
                        .font(.system(size: 32))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

                    Text("No sessions found for this model in the selected time range.")
                        .font(UnifiedDesignSystem.Typography.body)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, UnifiedDesignSystem.Spacing.xxl)
            }
            .padding(UnifiedDesignSystem.Spacing.lg)
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
        let cost = usages.reduce(0) { $0 + $1.cost }
        let tokens = usages.reduce(0) { $0 + $1.totalTokens }
        return settingsManager.formatUsageMetric(cost: cost, tokens: tokens)
    }

    private func openUsage(_ usage: TokenUsage) {
        guard let target = jumpTarget(for: usage) else {
            selectedSession = usage
            return
        }
        if let onOpenSessionLog {
            onOpenSessionLog(target)
        } else {
            selectedSession = usage
        }
    }

    private func jumpTarget(for usage: TokenUsage) -> ConversationJumpTarget? {
        guard let conversation = conversationForUsage(usage) else {
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

    private func conversationForUsage(_ usage: TokenUsage) -> ConversationRecord? {
        let conversationID = ConversationRecord.stableId(provider: usage.provider, sessionId: usage.sessionId)
        if let conversation = try? dataStore.fetchConversation(id: conversationID) {
            return conversation
        }

        return try? dataStore
            .fetchSessionLogSummaries(limit: 1000)
            .first(where: { $0.sessionId == usage.sessionId && $0.provider == usage.provider })
    }

    private var averageSessionMetric: String {
        guard !usages.isEmpty else {
            return settingsManager.usageDisplayMode == .currency ? "$0.00" : "0"
        }
        if settingsManager.usageDisplayMode == .currency {
            return (usages.reduce(0) { $0 + $1.cost } / Double(usages.count)).formatAsCost()
        }
        return (usages.reduce(0) { $0 + $1.totalTokens } / usages.count).formatAsTokenVolume()
    }

    private var topAgents: [ProviderUsage] {
        let summary = dataStore.modelSummaries(in: timeRange.dateRange()).first(where: { $0.modelName == modelName })
        return Array(summary?.providerBreakdown.prefix(5) ?? [])
    }

    private var topAgentName: String {
        topAgents.first?.provider.displayName ?? "None"
    }

    /// Aggregate cache reuse for this model in the active window.
    private var modelCacheEfficiency: CacheEfficiency {
        if let summary = dataStore
            .modelSummaries(in: timeRange.dateRange())
            .first(where: { $0.modelName == modelName }) {
            return summary.cacheEfficiency
        }
        return CacheEfficiency.aggregate(usages)
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
