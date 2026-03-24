import SwiftUI
import Charts

// MARK: - Model Card

struct ModelCard: View {
    let summary: ModelSummary
    let rank: Int
    let onTap: () -> Void

    @Bindable private var settingsManager = SettingsManager.shared

    private var theme: ProviderTheme { ProviderTheme.theme(forModel: summary.modelName) }

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

                            ModelProviderLogoView(
                                modelKey: summary.modelName,
                                size: 30,
                                fallbackSymbolColor: theme.primaryColor
                            )
                        }
                    }
                    .frame(width: 54, alignment: .leading)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.displayName)
                                    .font(DesignSystem.Typography.headline)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    .lineLimit(1)

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
                            MiniModelStat(label: "Input", value: formatTokens(summary.totalInputTokens))
                            MiniModelStat(label: "Output", value: formatTokens(summary.totalOutputTokens))
                        }

                        if !summary.providerBreakdown.isEmpty {
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                                Text("Used By")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .textCase(.uppercase)

                                ForEach(Array(summary.providerBreakdown.prefix(3).enumerated()), id: \.element.id) { index, pu in
                                    HStack(spacing: DesignSystem.Spacing.sm) {
                                        Capsule()
                                            .fill(DesignSystem.Colors.primary(for: pu.provider))
                                            .frame(width: 14, height: 5)

                                        Text(pu.provider.displayName)
                                            .font(DesignSystem.Typography.caption)
                                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                                            .lineLimit(1)

                                        Spacer()

                                        Text("\(pu.percentage, specifier: "%.0f")%")
                                            .font(DesignSystem.Typography.monoTiny)
                                            .foregroundStyle(DesignSystem.Colors.textMuted)

                                        Text("\(pu.sessionCount) sess.")
                                            .font(DesignSystem.Typography.monoTiny)
                                            .foregroundStyle(DesignSystem.Colors.textSecondary)
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

    private func formatTokens(_ tokens: Int) -> String {
        tokens.formatAsTokens()
    }
}

// MARK: - Mini Model Stat

private struct MiniModelStat: View {
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

// MARK: - Model Dashboard View

struct ModelDashboardView: View {
    let modelName: String
    let dataStore: DataStore
    let timeRange: TimeRange

    @Bindable private var settingsManager = SettingsManager.shared
    @State private var selectedSession: TokenUsage?

    private var theme: ProviderTheme { ProviderTheme.theme(forModel: modelName) }

    private var displayName: String {
        TokenExtractionUtility.displayNameForModel(usages.first?.model ?? modelName)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                modelHeader

                if !usages.isEmpty {
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

    private var modelHeader: some View {
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

                        ModelProviderLogoView(
                            modelKey: modelName,
                            size: 40,
                            fallbackSymbolColor: theme.primaryColor
                        )
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text(displayName)
                            .font(DesignSystem.Typography.display)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text("\(usages.count) sessions in range")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)

                        HStack(spacing: DesignSystem.Spacing.md) {
                            modelMetric(
                                label: settingsManager.usageDisplayMode == .currency ? "Spend" : "Volume",
                                value: primaryMetric
                            )
                            modelMetric(
                                label: settingsManager.usageDisplayMode == .currency ? "Avg session" : "Avg tokens",
                                value: averageSessionMetric
                            )
                            modelMetric(label: "Top Agent", value: topAgentName)
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

            agentStackPanel
                .frame(width: 280, alignment: .topLeading)
        }
    }

    private var agentStackPanel: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                Text("Agent Stack")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Which agents use this model in the selected window.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                if topAgents.isEmpty {
                    Text("No agent data")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    VStack(spacing: DesignSystem.Spacing.md) {
                        ForEach(Array(topAgents.enumerated()), id: \.element.id) { index, pu in
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                HStack(spacing: DesignSystem.Spacing.sm) {
                                    Capsule()
                                        .fill(DesignSystem.Colors.primary(for: pu.provider))
                                        .frame(width: 16, height: 6)

                                    Text(pu.provider.displayName)
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(settingsManager.formatUsageMetric(cost: pu.cost, tokens: pu.totalTokens))
                                        .font(DesignSystem.Typography.monoSmall)
                                        .foregroundStyle(theme.primaryColor)
                                }

                                HStack {
                                    Text("\(pu.percentage, specifier: "%.0f")% of model usage")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)

                                    Spacer()

                                    Text("\(pu.sessionCount) sessions")
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
                showsAgentBadge: true,
                footerCaption: "Search paths, models, and session ids for \(displayName). Groups use session start time within the range above."
            ) {
                VStack(spacing: DesignSystem.Spacing.md) {
                    Image(systemName: "clock")
                        .font(.system(size: 32))
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    Text("No sessions found for this model in the selected time range.")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignSystem.Spacing.xxl)
            }
            .padding(DesignSystem.Spacing.lg)
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

    private func modelMetric(label: String, value: String) -> some View {
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

