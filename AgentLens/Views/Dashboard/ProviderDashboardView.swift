import SwiftUI
import Charts

// MARK: - Provider Detail Metrics

/// One metric tile rendered in the provider detail header.
struct ProviderDetailMetric: Equatable {
    let label: String
    let value: String
}

/// Single presentation helper for provider-detail header metrics. Unsupported
/// providers (e.g. grokBot, augment) ALWAYS render typed support/confidence
/// labels from the canonical `ProviderSupportLevel`/`DataConfidence` copy —
/// regardless of usage rows — and empty partial providers (e.g. grokCLI, pi
/// with no usage rows in range) get the same typed treatment; never an
/// exact-looking "$0.00"/zero metric (VAL-PROV-010, round-4 scrutiny).
/// Zero-usage providers render "No data" for averages instead of fabricated
/// zeros.
enum ProviderDetailMetrics {
    static func headerMetrics(
        provider: AgentProvider,
        usages: [TokenUsage],
        displayMode: UsageDisplayMode,
        topModelName: String
    ) -> [ProviderDetailMetric] {
        // Unsupported is unconditional: a non-empty unsupported provider
        // (e.g. augment with parser rows) must never surface exact-looking
        // Spend/Volume tiles. The empty-partial predicate is a separate
        // additional condition (round-4 scrutiny).
        if provider.supportLevel == .unsupported
            || (provider.supportLevel == .partial && usages.isEmpty) {
            return [
                ProviderDetailMetric(label: "Tracking", value: provider.supportLevel.label),
                ProviderDetailMetric(label: "Data confidence", value: provider.dataConfidence.label),
                ProviderDetailMetric(label: "Top Model", value: topModelName)
            ]
        }

        let cost = usages.reduce(0) { $0 + $1.cost }
        let tokens = usages.reduce(0) { $0 + $1.totalTokens }
        let primary: String
        let average: String
        if displayMode == .currency {
            primary = cost.formatAsCost()
            average = usages.isEmpty ? "No data" : (cost / Double(usages.count)).formatAsCost()
        } else {
            primary = tokens.formatAsTokenVolume()
            average = usages.isEmpty ? "No data" : (tokens / usages.count).formatAsTokenVolume()
        }
        return [
            ProviderDetailMetric(label: displayMode == .currency ? "Spend" : "Volume", value: primary),
            ProviderDetailMetric(label: displayMode == .currency ? "Avg session" : "Avg session (tokens)", value: average),
            ProviderDetailMetric(label: "Top Model", value: topModelName)
        ]
    }

    /// Header subtitle. Unsupported providers (e.g. grokBot, a live-signal-only
    /// provider with an honest no-op usage parser) never claim exact
    /// "0 sessions / 0 tokens" counts — they render typed unavailability copy
    /// from the canonical support/confidence labels (VAL-PROV-010, round-2
    /// scrutiny). Partial providers with no rows in the window get an honest
    /// "no sessions yet" note instead of a bare zero claim.
    static func headerSubtitle(
        provider: AgentProvider,
        usages: [TokenUsage],
        totalTokens: String
    ) -> String {
        if usages.isEmpty {
            switch provider.supportLevel {
            case .unsupported:
                return "\(provider.supportLevel.label) • \(provider.dataConfidence.label) — no usage data"
            case .partial:
                return "\(provider.dataConfidence.label) • no sessions yet"
            case .supported:
                return "No sessions in range"
            }
        }
        return "\(usages.count) sessions in range • \(totalTokens) tokens processed"
    }
}

/// Composes all provider-detail fallback copy and section visibility decisions
/// in one route-level value. Keeping this at the detail-route boundary prevents
/// the header, analytics gate, and empty-session section from drifting apart
/// for zero-data providers.
struct ProviderDetailRoutePresentation: Equatable {
    let headerSubtitle: String
    let headerMetrics: [ProviderDetailMetric]
    let emptyMessage: String
    let emptyIconName: String
    let showsAnalytics: Bool

    static func make(
        provider: AgentProvider,
        usages: [TokenUsage],
        displayMode: UsageDisplayMode,
        topModelName: String,
        totalTokens: String
    ) -> ProviderDetailRoutePresentation {
        let emptyMessage: String
        switch provider.supportLevel {
        case .unsupported:
            emptyMessage = [
                "\(provider.supportLevel.label) • \(provider.dataConfidence.label):",
                "\(provider.displayName) does not expose token usage data yet."
            ].joined(separator: " ")
        case .partial:
            emptyMessage = [
                "\(provider.supportLevel.label) • \(provider.dataConfidence.label):",
                "No \(provider.displayName) sessions found at \(provider.logDirectory).",
                "Data will be estimated when available."
            ].joined(separator: " ")
        case .supported:
            emptyMessage = [
                "\(provider.supportLevel.label):",
                "No \(provider.displayName) sessions found.",
                "Check that \(provider.logDirectory) exists and contains session files."
            ].joined(separator: " ")
        }

        return ProviderDetailRoutePresentation(
            headerSubtitle: ProviderDetailMetrics.headerSubtitle(
                provider: provider,
                usages: usages,
                totalTokens: totalTokens
            ),
            headerMetrics: ProviderDetailMetrics.headerMetrics(
                provider: provider,
                usages: usages,
                displayMode: displayMode,
                topModelName: topModelName
            ),
            emptyMessage: emptyMessage,
            emptyIconName: provider.supportLevel == .unsupported ? "eye.slash" : "clock",
            showsAnalytics: !usages.isEmpty
        )
    }
}

// MARK: - Provider Card

struct ProviderCard: View {
    let summary: ProviderSummary
    let rank: Int
    let onTap: () -> Void

    @Bindable private var settingsManager = SettingsManager.shared

    private var theme: ProviderTheme { ProviderTheme.theme(for: summary.provider) }

    var body: some View {
        Button(action: onTap) {
            GlassCard(interactive: true) {
                HStack(spacing: DesignSystem.Spacing.lg) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text(String(format: "%02d", rank))
                            .font(DesignSystem.Typography.mono)
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        ZStack {
                            Circle()
                                .fill(theme.primaryColor.opacity(0.15))
                                .frame(width: 46, height: 46)

                            ProviderLogoView(provider: summary.provider, size: 28, useFallbackColor: false)
                        }
                    }
                    .frame(width: 54, alignment: .leading)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: DesignSystem.Spacing.sm) {
                                    Text(summary.provider.displayName)
                                        .font(DesignSystem.Typography.headline)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                                    confidenceBadge(for: summary.provider.dataConfidence)
                                }

                                Text("\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens))
                                    .font(DesignSystem.Typography.monoLarge)
                                    .foregroundStyle(theme.gradient)

                                Text(settingsManager.usageDisplayMode == .currency ? "total spend" : "total tokens")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                        }

                        HStack(spacing: DesignSystem.Spacing.xl) {
                            MiniStat(label: "Input", value: formatTokens(summary.totalInputTokens))
                            MiniStat(label: "Output", value: formatTokens(summary.totalOutputTokens))
                            MiniStat(label: "Cache R", value: formatTokens(summary.modelBreakdown.reduce(0) { $0 + $1.cacheReadTokens }))
                        }

                        if !summary.modelBreakdown.isEmpty {
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                                Text("Top Models")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .textCase(.uppercase)

                                ForEach(Array(summary.modelBreakdown.prefix(3).enumerated()), id: \.element.id) { index, model in
                                    HStack(spacing: DesignSystem.Spacing.sm) {
                                        Capsule()
                                            .fill(theme.chartColors[index % theme.chartColors.count])
                                            .frame(width: 14, height: 5)

                                        Text(model.modelName)
                                            .font(DesignSystem.Typography.caption)
                                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                                            .lineLimit(1)

                                        Spacer()

                                        Text("\(model.percentage, specifier: "%.0f")%")
                                            .font(DesignSystem.Typography.monoTiny)
                                            .foregroundStyle(DesignSystem.Colors.textMuted)

                                        Text(formatTokens(model.totalTokens))
                                            .font(DesignSystem.Typography.monoSmall)
                                            .foregroundStyle(theme.primaryColor)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func confidenceBadge(for confidence: DataConfidence) -> some View {
        switch confidence {
        case .exact:
            Text("Exact")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.success)
        case .estimated:
            Text("Estimated")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.warning)
        case .unavailable:
            Text("Unsupported")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}

// MARK: - Mini Stat

private struct MiniStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text(value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
    }
}

// MARK: - Provider Dashboard View

struct ProviderDashboardView: View {
    let provider: AgentProvider
    let dataStore: DataStore
    let timeRange: TimeRange

    @Bindable private var settingsManager = SettingsManager.shared
    @State private var selectedSession: TokenUsage?
    @State private var quotaService = ProviderQuotaService.shared

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                providerHeader

                ProviderDashboardQuotaPanel(
                    provider: provider,
                    quotaService: quotaService,
                    dataStore: dataStore
                )

                if routePresentation.showsAnalytics {
                    analyticsDeck
                }

                sessionsSection
            }
            .padding(DesignSystem.Spacing.xl)
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
            SessionDetailView(session: session, theme: theme, dataStore: dataStore)
        }
    }

    private var providerHeader: some View {
        GlassCard {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
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

                HStack(alignment: .top, spacing: DesignSystem.Spacing.xl) {
                    ZStack {
                        Circle()
                            .fill(theme.primaryColor.opacity(0.15))
                            .frame(width: 64, height: 64)

                        ProviderLogoView(provider: provider, size: 40, useFallbackColor: false)
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text(provider.displayName)
                            .font(DesignSystem.Typography.display)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text(routePresentation.headerSubtitle)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)

                        HStack(spacing: DesignSystem.Spacing.md) {
                            ForEach(routePresentation.headerMetrics, id: \.label) { metric in
                                providerMetric(label: metric.label, value: metric.value)
                            }
                        }
                    }

                    Spacer()
                }
                .padding(DesignSystem.Spacing.xl)

                Circle()
                    .fill(theme.gradient.opacity(0.22))
                    .frame(width: 180, height: 180)
                    .blur(radius: 45)
                    .offset(x: 26, y: 40)
            }
        }
    }

    private var analyticsDeck: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
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
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                Text("Model Stack")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Dominant models for this provider in the selected window.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                if topModels.isEmpty {
                    Text("No model data")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    VStack(spacing: DesignSystem.Spacing.md) {
                        ForEach(Array(topModels.enumerated()), id: \.element.id) { index, model in
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                HStack(spacing: DesignSystem.Spacing.sm) {
                                    Capsule()
                                        .fill(theme.chartColors[index % theme.chartColors.count])
                                        .frame(width: 16, height: 6)

                                    Text(model.modelName)
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(settingsManager.formatUsageMetric(cost: model.cost, tokens: model.totalTokens))
                                        .font(DesignSystem.Typography.monoSmall)
                                        .foregroundStyle(theme.primaryColor)
                                }

                                HStack {
                                    Text(settingsManager.usageDisplayMode == .currency
                                        ? "\(model.percentage, specifier: "%.0f")% of provider spend"
                                        : "\(model.percentage, specifier: "%.0f")% of provider tokens")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)

                                    Spacer()

                                    Text(formatTokens(model.totalTokens))
                                        .font(DesignSystem.Typography.monoTiny)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                }
                            }
                            .padding(.bottom, DesignSystem.Spacing.xs)
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private var sessionsSection: some View {
        GlassCard {
            SessionLedgerSection(
                usages: usages,
                theme: theme,
                selectedSession: $selectedSession,
                displayMode: settingsManager.usageDisplayMode,
                showsAgentBadge: false,
                footerCaption: "Search paths, models, and session ids for \(provider.displayName). Groups use session start time within the range above."
            ) {
                emptySessionsView
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private var emptySessionsView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: routePresentation.emptyIconName)
                .font(.system(size: 32))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text(routePresentation.emptyMessage)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.xxl)
    }

    private var usages: [TokenUsage] {
        if let range = timeRange.dateRange() {
            return dataStore.usages(for: provider, in: range)
        }
        return dataStore.usages(for: provider)
    }

    private var totalTokens: String {
        formatTokens(usages.reduce(0) { $0 + $1.totalTokens })
    }

    /// Header subtitle. Unsupported providers (e.g. grokBot, a live-signal-only
    /// provider with an honest no-op usage parser) never claim exact
    /// "0 sessions / 0 tokens" counts — they render typed unavailability copy
    /// from the canonical support/confidence labels (VAL-PROV-010, round-2
    /// scrutiny). Partial providers with no rows in the window get an honest
    /// "no sessions yet" note instead of a bare zero claim.
    var routePresentation: ProviderDetailRoutePresentation {
        ProviderDetailRoutePresentation.make(
            provider: provider,
            usages: usages,
            displayMode: settingsManager.usageDisplayMode,
            topModelName: topModelName,
            totalTokens: totalTokens
        )
    }

    private var topModels: [ModelUsage] {
        Array(
            dataStore
                .providerSummaries(in: timeRange.dateRange())
                .first(where: { $0.provider == provider })?
                .modelBreakdown
                .prefix(5) ?? []
        )
    }

    private var topModelName: String {
        topModels.first?.modelName ?? "None"
    }

    private func providerMetric(label: String, value: String) -> some View {
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

    private func formatTokens(_ tokens: Int) -> String {
        tokens.formatAsTokens()
    }
}

// MARK: - Chart Wrappers

struct TokenBreakdownChart: View {
    let usages: [TokenUsage]
    let theme: ProviderTheme

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Token Breakdown")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Input, output, and cache token distribution.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

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
                                .foregroundStyle(DesignSystem.Colors.border)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(DesignSystem.Colors.border)
                            AxisValueLabel {
                                if let v = value.as(Int.self) {
                                    Text(formatTokens(v))
                                        .font(DesignSystem.Typography.monoTiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                            }
                        }
                    }
                    .frame(height: 170)
                } else {
                    Text("No data")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(DesignSystem.Spacing.lg)
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
        if tokens >= 1_000_000 {
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
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Text("Daily Trend")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Spacer()

                    Text("Last \(days) days")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Text(displayMode == .currency
                    ? "Daily spend velocity over the trailing window."
                    : "Daily token volume over the trailing window.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

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
                                .foregroundStyle(DesignSystem.Colors.border)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(DesignSystem.Colors.border)
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text(axisLabel(for: v))
                                        .font(DesignSystem.Typography.monoTiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                            }
                        }
                    }
                    .chartYScale(domain: 0...(maxDailyValue * 1.15))
                    .frame(height: 170)

                    HStack(spacing: DesignSystem.Spacing.lg) {
                        MiniStat(label: "Avg/Day", value: formatSummary(averageDailyValue))
                        MiniStat(label: "Peak", value: formatSummary(peakDailyValue))
                        MiniStat(label: "Total", value: formatSummary(totalValue))
                    }
                } else {
                    Text("No data")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(DesignSystem.Spacing.lg)
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
    ProviderDashboardView(
        provider: .factory,
        dataStore: DataStore(),
        timeRange: .today
    )
}
