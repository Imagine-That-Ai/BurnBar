import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Provider Card

struct ProviderCard: View {
    let summary: ProviderSummary
    let rank: Int
    let onTap: () -> Void

    @Environment(SettingsManager.self) private var settingsManager
    @State private var isHovered: Bool = false

    private var theme: ProviderTheme { ProviderTheme.theme(for: summary.provider) }

    var body: some View {
        UnifiedGlassCard(interactive: true) {
            ZStack(alignment: .topTrailing) {
                provideGlow

                HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.xl) {
                    heroColumn
                    contentColumn
                }
                .padding(.vertical, UnifiedDesignSystem.Spacing.xs)
                .padding(.horizontal, UnifiedDesignSystem.Spacing.xs)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onTap)
    }

    // MARK: - Decorative theme glow

    private var provideGlow: some View {
        Circle()
            .fill(theme.gradient.opacity(isHovered ? 0.22 : 0.14))
            .frame(width: 180, height: 180)
            .blur(radius: 60)
            .offset(x: 60, y: -50)
            .allowsHitTesting(false)
            .animation(UnifiedDesignSystem.Animation.hover, value: isHovered)
    }

    // MARK: - Hero column

    private var heroColumn: some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            rankPill
            logoMedallion
        }
        .frame(width: 96)
    }

    private var rankPill: some View {
        Text(String(format: "%02d", rank))
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(theme.primaryColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(theme.primaryColor.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(theme.primaryColor.opacity(0.35), lineWidth: 0.6)
            )
    }

    private var logoMedallion: some View {
        ZStack {
            Circle()
                .fill(theme.gradient.opacity(0.22))
                .frame(width: 96, height: 96)
                .blur(radius: 22)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            theme.primaryColor.opacity(0.18),
                            theme.accentColor.opacity(0.04)
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 44
                    )
                )
                .frame(width: 80, height: 80)

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.primaryColor.opacity(0.6),
                            theme.accentColor.opacity(0.18),
                            theme.primaryColor.opacity(0.32)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
                .frame(width: 80, height: 80)

            UnifiedProviderLogoView(provider: summary.provider, size: 52, useFallbackColor: false)
                .shadow(color: theme.primaryColor.opacity(0.18), radius: 8, x: 0, y: 4)
        }
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .animation(UnifiedDesignSystem.Animation.hover, value: isHovered)
    }

    // MARK: - Content column

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
            headerRow
            tokenMixSection
            if !rankedModelBreakdown.isEmpty {
                Divider()
                    .overlay(UnifiedDesignSystem.Colors.border.opacity(0.4))
                topModelsSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header row

    private var headerRow: some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: UnifiedDesignSystem.Spacing.sm) {
                    Text(summary.provider.displayName)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    confidenceBadge(for: summary.provider.dataConfidence)
                }

                HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                    sessionsChip
                    secondaryMetricChip
                    if summary.cacheEfficiency.hasSignal {
                        UnifiedCacheHitRateBadge(efficiency: summary.cacheEfficiency)
                    }
                }
            }

            Spacer(minLength: UnifiedDesignSystem.Spacing.md)

            VStack(alignment: .trailing, spacing: 4) {
                Text(primaryMetric)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.gradient)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)

                Text(settingsManager.usageDisplayMode == .currency ? "TOTAL SPEND" : "TOTAL TOKENS")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
        }
    }

    private var sessionsChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.55))
        )
        .overlay(
            Capsule()
                .stroke(UnifiedDesignSystem.Colors.border.opacity(0.32), lineWidth: 0.5)
        )
    }

    private var secondaryMetricChip: some View {
        HStack(spacing: 5) {
            Image(systemName: settingsManager.usageDisplayMode == .currency ? "number" : "dollarsign")
                .font(.system(size: 9, weight: .semibold))
            Text(secondaryMetricValue)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.55))
        )
        .overlay(
            Capsule()
                .stroke(UnifiedDesignSystem.Colors.border.opacity(0.32), lineWidth: 0.5)
        )
    }

    private var primaryMetric: String {
        settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens)
    }

    private var secondaryMetricValue: String {
        switch settingsManager.usageDisplayMode {
        case .currency:
            return "\(ProviderCard.formatTokens(summary.totalTokens)) tokens"
        case .tokens:
            return summary.totalCost.formatAsCost()
        }
    }

    // MARK: - Token Mix

    private var tokenMixSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Text("Token Mix")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

                Rectangle()
                    .fill(UnifiedDesignSystem.Colors.border.opacity(0.25))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)

                Text(ProviderCard.formatTokens(tokenMixBasis))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            }

            segmentedTokenBar

            tokenLegend
        }
    }

    private var segmentedTokenBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(tokenSegments) { segment in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [segment.color, segment.color.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: max(3, geo.size.width * segment.share - 2))
                        .shadow(color: segment.color.opacity(0.32), radius: 2, x: 0, y: 1)
                }
            }
        }
        .frame(height: 10)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(UnifiedDesignSystem.Colors.border.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var tokenLegend: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.md) {
            ForEach(tokenSegments) { segment in
                ProviderTokenLegendItem(segment: segment)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Top Models

    private var topModelsSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Text("Top Models")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

                Rectangle()
                    .fill(UnifiedDesignSystem.Colors.border.opacity(0.25))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)

                Text("\(rankedModelBreakdown.count) tracked")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }

            VStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                ForEach(Array(rankedModelBreakdown.prefix(3).enumerated()), id: \.element.id) { index, model in
                    ProviderTopModelRow(
                        rank: index + 1,
                        model: model,
                        share: modelSharePercentage(model),
                        color: theme.chartColors[index % theme.chartColors.count],
                        primaryDisplay: settingsManager.formatUsageMetric(cost: model.cost, tokens: model.totalTokens)
                    )
                }
            }
        }
    }

    // MARK: - Computed token segments

    private var cacheCreationTokens: Int { summary.cacheEfficiency.cacheCreationTokens }
    private var cacheReadTokens: Int { summary.cacheEfficiency.cacheReadTokens }

    private var tokenMixBasis: Int {
        max(
            1,
            max(0, summary.totalInputTokens)
                + max(0, summary.totalOutputTokens)
                + max(0, cacheCreationTokens)
                + max(0, cacheReadTokens)
        )
    }

    private var tokenSegments: [ProviderTokenSegment] {
        let basis = Double(tokenMixBasis)
        let palette = theme.chartColors
        func paletteColor(_ i: Int, fallback: Color) -> Color {
            palette.indices.contains(i) ? palette[i] : fallback
        }

        let raw: [(label: String, value: Int, color: Color)] = [
            ("Input",   max(0, summary.totalInputTokens),  paletteColor(0, fallback: theme.primaryColor)),
            ("Cache W", max(0, cacheCreationTokens),       paletteColor(2, fallback: theme.primaryColor.opacity(0.6))),
            ("Cache R", max(0, cacheReadTokens),           paletteColor(1, fallback: theme.accentColor)),
            ("Output",  max(0, summary.totalOutputTokens), paletteColor(3, fallback: theme.accentColor.opacity(0.6))),
        ]

        return raw
            .filter { $0.value > 0 }
            .map { entry in
                ProviderTokenSegment(
                    label: entry.label,
                    value: entry.value,
                    share: Double(entry.value) / basis,
                    color: entry.color
                )
            }
    }

    // MARK: - Helpers

    private var rankedModelBreakdown: [ModelUsage] {
        DashboardUsageRanking.sortedModelUsages(
            summary.modelBreakdown,
            displayMode: settingsManager.usageDisplayMode
        )
    }

    private func modelSharePercentage(_ model: ModelUsage) -> Double {
        DashboardUsageRanking.modelUsagePercentage(
            model,
            in: summary,
            displayMode: settingsManager.usageDisplayMode
        )
    }

    @ViewBuilder
    private func confidenceBadge(for confidence: DataConfidence) -> some View {
        switch confidence {
        case .exact:
            confidencePill(text: "Exact", color: UnifiedDesignSystem.Colors.success)
        case .estimated:
            confidencePill(text: "Estimated", color: UnifiedDesignSystem.Colors.warning)
        case .unavailable:
            confidencePill(text: "Unsupported", color: UnifiedDesignSystem.Colors.textMuted)
        }
    }

    private func confidencePill(text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1.0)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.32), lineWidth: 0.5))
    }

    fileprivate static func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000_000 {
            return String(format: "%.2fB", Double(tokens) / 1_000_000_000)
        } else if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}

// MARK: - Token Mix Supporting Types

private struct ProviderTokenSegment: Identifiable {
    let label: String
    let value: Int
    let share: Double
    let color: Color
    var id: String { label }
}

private struct ProviderTokenLegendItem: View {
    let segment: ProviderTokenSegment

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [segment.color, segment.color.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(segment.label.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

                HStack(spacing: 4) {
                    Text(ProviderCard.formatTokens(segment.value))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                    Text("\(Int((segment.share * 100).rounded()))%")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(segment.color.opacity(0.85))
                }
            }
        }
        .lineLimit(1)
    }
}

private struct ProviderTopModelRow: View {
    let rank: Int
    let model: ModelUsage
    let share: Double
    let color: Color
    let primaryDisplay: String

    private var clampedShare: Double { min(max(share, 0), 100) }

    var body: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Text("\(rank)")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                .frame(width: 12, alignment: .leading)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [color, color.opacity(0.5)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 4
                    )
                )
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.5), radius: 2)

            Text(model.modelName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 140, alignment: .leading)

            shareBar

            Text("\(Int(clampedShare.rounded()))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .frame(width: 38, alignment: .trailing)

            Text(primaryDisplay)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var shareBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.55))
                    .frame(height: 6)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(0.55)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(clampedShare / 100), height: 6)
                    .shadow(color: color.opacity(0.45), radius: 3, x: 0, y: 1)
            }
        }
        .frame(height: 6)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Provider Dashboard View

struct ProviderDashboardView: View {
    let provider: AgentProvider
    let dataStore: DataStore
    let timeRange: TimeRange
    var onOpenSessionLog: ((ConversationJumpTarget) -> Void)? = nil

    @Environment(SettingsManager.self) private var settingsManager
    @State private var selectedSession: TokenUsage?
    @State private var quotaService = ProviderQuotaService.shared

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                providerHeader

                ProviderDashboardQuotaPanel(
                    provider: provider,
                    quotaService: quotaService,
                    dataStore: dataStore
                )

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

    private var providerHeader: some View {
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

                        ProviderLogoView(provider: provider, size: 40, useFallbackColor: false)
                    }

                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                        Text(provider.displayName)
                            .font(UnifiedDesignSystem.Typography.display)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                        Text("\(usages.count) sessions in range • \(totalTokens) tokens processed")
                            .font(UnifiedDesignSystem.Typography.body)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)

                        HStack(spacing: UnifiedDesignSystem.Spacing.md) {
                            UnifiedMiniStat(
                                label: settingsManager.usageDisplayMode == .currency ? "Spend" : "Volume",
                                value: primaryProviderMetric
                            )
                            UnifiedMiniStat(
                                label: settingsManager.usageDisplayMode == .currency ? "Avg session" : "Avg session (tokens)",
                                value: averageSessionMetric
                            )
                            UnifiedMiniStat(label: "Top Model", value: topModelName)
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

            modelStackPanel
                .frame(width: 280, alignment: .topLeading)
        }
    }

    private var modelStackPanel: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                Text("Model Stack")
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                Text("Dominant models for this provider in the selected window.")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)

                if topModels.isEmpty {
                    Text("No model data")
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                } else {
                    VStack(spacing: UnifiedDesignSystem.Spacing.md) {
                        ForEach(Array(topModels.enumerated()), id: \.element.id) { index, model in
                            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                                HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                                    Capsule()
                                        .fill(theme.chartColors[index % theme.chartColors.count])
                                        .frame(width: 16, height: 6)

                                    Text(model.modelName)
                                        .font(UnifiedDesignSystem.Typography.body)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(settingsManager.formatUsageMetric(cost: model.cost, tokens: model.totalTokens))
                                        .font(UnifiedDesignSystem.Typography.monoSmall)
                                        .foregroundStyle(theme.primaryColor)
                                }

                                HStack {
                                    Text(settingsManager.usageDisplayMode == .currency
                                        ? "\(modelSharePercentage(model), specifier: "%.0f")% of provider spend"
                                        : "\(modelSharePercentage(model), specifier: "%.0f")% of provider tokens")
                                        .font(UnifiedDesignSystem.Typography.tiny)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

                                    Spacer()

                                    Text(formatTokens(model.totalTokens))
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
                showsAgentBadge: false,
                footerCaption: "Search paths, models, and session ids for \(provider.displayName). Groups use session start time within the range above."
            ) {
                emptySessionsView
            }
            .padding(UnifiedDesignSystem.Spacing.lg)
        }
    }

    private var emptyMessage: String {
        switch provider.supportLevel {
        case .unsupported:
            return "\(provider.displayName) does not expose token usage data yet."
        case .partial:
            return "No \(provider.displayName) sessions found at \(provider.logDirectory). Data will be estimated when available."
        case .supported:
            return "No \(provider.displayName) sessions found. Check that \(provider.logDirectory) exists and contains session files."
        }
    }

    private var emptySessionsView: some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.md) {
            Image(systemName: provider.supportLevel == .unsupported ? "eye.slash" : "clock")
                .font(.system(size: 32))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

            Text(emptyMessage)
                .font(UnifiedDesignSystem.Typography.body)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UnifiedDesignSystem.Spacing.xxl)
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

    private var usages: [TokenUsage] {
        if let range = timeRange.dateRange() {
            return dataStore.usages(for: provider, in: range)
        }
        return dataStore.usages(for: provider)
    }

    private var totalTokens: String {
        formatTokens(providerSummary?.totalTokens ?? usages.reduce(0) { $0 + $1.totalTokens })
    }

    private var primaryProviderMetric: String {
        let cost = providerSummary?.totalCost ?? usages.reduce(0) { $0 + $1.cost }
        let tokens = providerSummary?.totalTokens ?? usages.reduce(0) { $0 + $1.totalTokens }
        return settingsManager.formatUsageMetric(cost: cost, tokens: tokens)
    }

    private var averageSessionMetric: String {
        let count = providerSummary?.sessionCount ?? usages.count
        guard count > 0 else {
            return settingsManager.usageDisplayMode == .currency ? "$0.00" : "0"
        }
        if settingsManager.usageDisplayMode == .currency {
            let value = (providerSummary?.totalCost ?? usages.reduce(0) { $0 + $1.cost }) / Double(count)
            return value.formatAsCost()
        }
        let t = (providerSummary?.totalTokens ?? usages.reduce(0) { $0 + $1.totalTokens }) / count
        return t.formatAsTokenVolume()
    }

    private var topModels: [ModelUsage] {
        Array(
            DashboardUsageRanking.sortedModelUsages(
                providerSummary?.modelBreakdown ?? [],
                displayMode: settingsManager.usageDisplayMode
            )
            .prefix(5)
        )
    }

    private var topModelName: String {
        topModels.first?.modelName ?? "None"
    }

    private var providerSummary: ProviderSummary? {
        dataStore
            .providerSummaries(for: timeRange)
            .first(where: { $0.provider == provider })
    }

    private func modelSharePercentage(_ model: ModelUsage) -> Double {
        guard let providerSummary else { return 0 }
        return DashboardUsageRanking.modelUsagePercentage(
            model,
            in: providerSummary,
            displayMode: settingsManager.usageDisplayMode
        )
    }


    private func formatTokens(_ tokens: Int) -> String {
        tokens.formatAsTokens()
    }
}

// MARK: - Chart Wrappers

struct TokenBreakdownChart: View {
    let usages: [TokenUsage]
    let theme: ProviderTheme

    var body: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                Text("Token Breakdown")
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                Text("Input, output, and cache token distribution.")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)

                if totalTokens > 0 {
                    Chart(tokenData, id: \.label) { item in
                        BarMark(
                            x: .value("Type", item.label),
                            y: .value("Tokens", item.value)
                        )
                        .foregroundStyle(item.color)
                        .cornerRadius(4)
                    }
                    .chartXAxis {
                        AxisMarks { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(UnifiedDesignSystem.Colors.border)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(UnifiedDesignSystem.Colors.border)
                            AxisValueLabel {
                                if let v = value.as(Int.self) {
                                    Text(formatTokens(v))
                                        .font(UnifiedDesignSystem.Typography.monoTiny)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                }
                            }
                        }
                    }
                    .frame(height: 170)
                } else {
                    Text("No data")
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(UnifiedDesignSystem.Spacing.lg)
        }
    }

    private var totalTokens: Int {
        usages.reduce(0) { $0 + $1.totalTokens }
    }

    private var tokenData: [(label: String, value: Int, color: Color)] {
        [
            ("Input", usages.reduce(0) { $0 + $1.inputTokens }, theme.chartColors[0]),
            ("Output", usages.reduce(0) { $0 + $1.outputTokens }, theme.chartColors[1]),
            ("Cache W", usages.reduce(0) { $0 + $1.cacheCreationTokens }, theme.chartColors[2]),
            ("Cache R", usages.reduce(0) { $0 + $1.cacheReadTokens }, theme.chartColors[3])
        ].filter { $0.1 > 0 }
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000_000 {
            return String(format: "%.2fB", Double(tokens) / 1_000_000_000)
        } else if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}

struct DailyTrendChart: View {
    let usages: [TokenUsage]
    let theme: ProviderTheme
    let days: Int
    var displayMode: UsageDisplayMode = .currency

    var body: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                HStack {
                    Text("Daily Trend")
                        .font(UnifiedDesignSystem.Typography.headline)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                    Spacer()

                    Text("Last \(days) days")
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }

                Text(displayMode == .currency
                    ? "Daily spend velocity over the trailing window."
                    : "Daily token volume over the trailing window.")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)

                if !dailyDataPoints.isEmpty {
                    Chart(dailyDataPoints, id: \.date) { day in
                        AreaMark(
                            x: .value("Date", day.date),
                            y: .value("Value", day.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [theme.primaryColor.opacity(0.3), theme.primaryColor.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Date", day.date),
                            y: .value("Value", day.value)
                        )
                        .foregroundStyle(theme.primaryColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(UnifiedDesignSystem.Colors.border)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(UnifiedDesignSystem.Colors.border)
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text(axisLabel(for: v))
                                        .font(UnifiedDesignSystem.Typography.monoTiny)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                }
                            }
                        }
                    }
                    .chartYScale(domain: 0...(maxDailyValue * 1.15))
                    .frame(height: 170)

                    HStack(spacing: UnifiedDesignSystem.Spacing.lg) {
                        UnifiedMiniStat(label: "Avg/Day", value: formatSummary(averageDailyValue))
                        UnifiedMiniStat(label: "Peak", value: formatSummary(peakDailyValue))
                        UnifiedMiniStat(label: "Total", value: formatSummary(totalValue))
                    }
                } else {
                    Text("No data")
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(UnifiedDesignSystem.Spacing.lg)
        }
    }

    private var dailyDataPoints: [(date: Date, value: Double)] {
        let calendar = Calendar.current
        let now = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: now) ?? now

        var buckets: [Date: Double] = [:]
        for offset in 0..<days {
            if let date = calendar.date(byAdding: .day, value: -offset, to: now) {
                buckets[calendar.startOfDay(for: date)] = 0
            }
        }

        for usage in usages where usage.startTime >= startDate {
            let dayStart = calendar.startOfDay(for: usage.startTime)
            if displayMode == .currency {
                buckets[dayStart, default: 0] += usage.cost
            } else {
                buckets[dayStart, default: 0] += Double(usage.totalTokens)
            }
        }

        return buckets
            .map { (date: $0.key, value: $0.value) }
            .sorted { $0.date < $1.date }
    }

    private var averageDailyValue: Double {
        guard !dailyDataPoints.isEmpty else { return 0 }
        return dailyDataPoints.reduce(0) { $0 + $1.value } / Double(dailyDataPoints.count)
    }

    private var peakDailyValue: Double {
        dailyDataPoints.map(\.value).max() ?? 0
    }

    private var totalValue: Double {
        dailyDataPoints.reduce(0) { $0 + $1.value }
    }

    private var maxDailyValue: Double {
        max(dailyDataPoints.map(\.value).max() ?? 1, 0.01)
    }

    private func axisLabel(for v: Double) -> String {
        if displayMode == .currency {
            return v.formatAsCost()
        }
        return Int(v).formatAsTokenVolume()
    }

    private func formatSummary(_ v: Double) -> String {
        if displayMode == .currency {
            return v.formatAsCost()
        }
        return Int(v).formatAsTokenVolume()
    }

}

#Preview {
    let store = (try? DataStore()) ?? {
        preconditionFailure("Preview requires a valid DataStore - ensure app support directory is writable")
    }()
    return ProviderDashboardView(
        provider: .factory,
        dataStore: store,
        timeRange: .today
    )
    .environment(SettingsManager())
}
