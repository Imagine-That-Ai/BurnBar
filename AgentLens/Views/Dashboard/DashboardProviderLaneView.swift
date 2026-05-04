import SwiftUI
import OpenBurnBarCore

// MARK: - Provider / Model / Activity Lanes

struct DashboardProviderLaneView: View {
    var summaries: [ProviderSummary]
    var overviewAppeared: Bool = true
    var onNavigateToProvider: (AgentProvider) -> Void = { _ in }

    var body: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                        Text("Provider Ranking")
                            .font(UnifiedDesignSystem.Typography.headline)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                        Text("Cost, session volume, and token mix across all tracked agents.")
                            .font(UnifiedDesignSystem.Typography.caption)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    }

                    Spacer()
                }

                VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                    ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                        ProviderCard(summary: summary, rank: index + 1) {
                            withAnimation(UnifiedDesignSystem.Animation.standard) {
                                onNavigateToProvider(summary.provider)
                            }
                        }
                        .opacity(overviewAppeared ? 1 : 0)
                        .offset(y: overviewAppeared ? 0 : 8)
                        .animation(UnifiedDesignSystem.Animation.standard.delay(Double(index) * 0.06), value: overviewAppeared)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(overviewAppeared ? 1 : 0)
        .offset(y: overviewAppeared ? 0 : 8)
        .animation(UnifiedDesignSystem.Animation.standard.delay(0.24), value: overviewAppeared)
    }
}

extension DashboardView {

    var providerLane: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                        Text("Provider Ranking")
                            .font(UnifiedDesignSystem.Typography.headline)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                        Text("Cost, session volume, and token mix across all tracked agents.")
                            .font(UnifiedDesignSystem.Typography.caption)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    }

                    Spacer()
                }

                VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                    ForEach(Array(dashboardProviderSummaries.enumerated()), id: \.element.id) { index, summary in
                        ProviderCard(summary: summary, rank: index + 1) {
                            withAnimation(UnifiedDesignSystem.Animation.standard) {
                                navigate(to: .provider(summary.provider))
                            }
                        }
                        .opacity(overviewAppeared ? 1 : 0)
                        .offset(y: overviewAppeared ? 0 : 8)
                        .animation(UnifiedDesignSystem.Animation.standard.delay(Double(index) * 0.06), value: overviewAppeared)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(overviewAppeared ? 1 : 0)
        .offset(y: overviewAppeared ? 0 : 8)
        .animation(UnifiedDesignSystem.Animation.standard.delay(0.24), value: overviewAppeared)
    }

    var modelLane: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                        Text("Model Ranking")
                            .font(UnifiedDesignSystem.Typography.headline)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                        Text("Cost, session volume, and agent mix across all tracked models.")
                            .font(UnifiedDesignSystem.Typography.caption)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    }

                    Spacer()
                }

                VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                    ForEach(Array(dashboardModelSummaries.enumerated()), id: \.element.id) { index, summary in
                        ModelCard(summary: summary, rank: index + 1) {
                            withAnimation(UnifiedDesignSystem.Animation.standard) {
                                navigate(to: .model(summary.modelName))
                            }
                        }
                        .opacity(overviewAppeared ? 1 : 0)
                        .offset(y: overviewAppeared ? 0 : 8)
                        .animation(UnifiedDesignSystem.Animation.standard.delay(Double(index) * 0.06), value: overviewAppeared)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(overviewAppeared ? 1 : 0)
        .offset(y: overviewAppeared ? 0 : 8)
        .animation(UnifiedDesignSystem.Animation.standard.delay(0.24), value: overviewAppeared)
    }

    var activityLane: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
            UnifiedGlassCard {
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                    Text("Recent Sessions")
                        .font(UnifiedDesignSystem.Typography.headline)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                    VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                        ForEach(Array(filteredUsages.prefix(6))) { usage in
                            SessionPreviewRow(usage: usage, settingsManager: settingsManager)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .opacity(overviewAppeared ? 1 : 0)
            .offset(y: overviewAppeared ? 0 : 8)
            .animation(UnifiedDesignSystem.Animation.standard.delay(0.28), value: overviewAppeared)

            UnifiedGlassCard {
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                    Text("Model Leaders")
                        .font(UnifiedDesignSystem.Typography.headline)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                    VStack(spacing: UnifiedDesignSystem.Spacing.md) {
                        ForEach(Array(topModels.prefix(4).enumerated()), id: \.offset) { index, item in
                            HStack(spacing: UnifiedDesignSystem.Spacing.md) {
                                Text("\(index + 1)")
                                    .font(UnifiedDesignSystem.Typography.monoSmall)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                    .frame(width: 16, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.model)
                                        .font(UnifiedDesignSystem.Typography.body)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                                    Text(item.provider.displayName)
                                        .font(UnifiedDesignSystem.Typography.tiny)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                }

                                Spacer()

                                Text(settingsManager.formatUsageMetric(cost: item.cost, tokens: item.tokens))
                                    .font(UnifiedDesignSystem.Typography.monoSmall)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                            }
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .opacity(overviewAppeared ? 1 : 0)
            .offset(y: overviewAppeared ? 0 : 8)
            .animation(UnifiedDesignSystem.Animation.standard.delay(0.34), value: overviewAppeared)
        }
        .frame(width: 320, alignment: .topLeading)
    }

    // MARK: - Metric Chip

    func metricChip(label: String, value: String) -> some View {
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
