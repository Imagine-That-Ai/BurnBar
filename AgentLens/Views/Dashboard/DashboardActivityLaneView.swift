import SwiftUI
import OpenBurnBarCore

struct DashboardActivityLaneView: View {
    var usages: [TokenUsage]
    var topModels: [(model: String, provider: AgentProvider, cost: Double, tokens: Int)]
    var settingsManager: SettingsManager
    var overviewAppeared: Bool = true
    var onOpenAllSessions: () -> Void = {}
    var onOpenSession: (TokenUsage) -> Void = { _ in }
    var onNavigateToModel: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
            UnifiedGlassCard {
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                    DashboardLaneHeader(
                        title: "Recent Sessions",
                        actionTitle: "View all",
                        systemImage: "clock.arrow.circlepath",
                        action: onOpenAllSessions
                    )

                    VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                        ForEach(Array(usages.prefix(6))) { usage in
                            SessionPreviewRow(
                                usage: usage,
                                settingsManager: settingsManager,
                                onTap: { onOpenSession(usage) }
                            )
                        }
                    }
                }
                .padding(UnifiedDesignSystem.Spacing.lg)
            }
            .opacity(overviewAppeared ? 1 : 0)
            .offset(y: overviewAppeared ? 0 : 8)
            .animation(UnifiedDesignSystem.Animation.standard.delay(0.28), value: overviewAppeared)

            UnifiedGlassCard {
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                    DashboardLaneHeader(
                        title: "Model Leaders",
                        actionTitle: "View all",
                        systemImage: "chart.bar.xaxis",
                        action: {
                            if let firstModel = topModels.first?.model {
                                onNavigateToModel(firstModel)
                            }
                        }
                    )

                    VStack(spacing: UnifiedDesignSystem.Spacing.md) {
                        ForEach(Array(topModels.prefix(4).enumerated()), id: \.offset) { index, item in
                            DashboardModelLeaderRow(
                                rank: index + 1,
                                item: item,
                                settingsManager: settingsManager,
                                onTap: { onNavigateToModel(item.model) }
                            )
                        }
                    }
                }
                .padding(UnifiedDesignSystem.Spacing.lg)
            }
            .opacity(overviewAppeared ? 1 : 0)
            .offset(y: overviewAppeared ? 0 : 8)
            .animation(UnifiedDesignSystem.Animation.standard.delay(0.34), value: overviewAppeared)
        }
        .frame(width: 320, alignment: .topLeading)
    }
}

struct DashboardModelLeaderRow: View {
    let rank: Int
    let item: (model: String, provider: AgentProvider, cost: Double, tokens: Int)
    let settingsManager: SettingsManager
    var onTap: (() -> Void)? = nil

    private var theme: ProviderTheme { .theme(for: item.provider) }

    var body: some View {
        if let onTap {
            Button(action: onTap) {
                rowContent
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous))
            .accessibilityLabel("Open \(item.model) model details")
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Text("\(rank)")
                .font(UnifiedDesignSystem.Typography.monoSmall)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                .frame(width: 16, alignment: .leading)

            ModelProviderLogoView(
                modelKey: item.model,
                size: 28,
                fallbackSymbolColor: theme.primaryColor
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.model)
                    .font(UnifiedDesignSystem.Typography.body)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    ProviderLogoView(provider: item.provider, size: 14, useFallbackColor: false)
                        .accessibilityHidden(true)

                    Text(item.provider.displayName)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: UnifiedDesignSystem.Spacing.xs)

            Text(settingsManager.formatUsageMetric(cost: item.cost, tokens: item.tokens))
                .font(UnifiedDesignSystem.Typography.monoSmall)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct DashboardLaneHeader: View {
    let title: String
    let actionTitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.md) {
            Text(title)
                .font(UnifiedDesignSystem.Typography.headline)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

            Spacer()

            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                    Text(actionTitle)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.62))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(UnifiedDesignSystem.Colors.border.opacity(0.38), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help(actionTitle)
        }
    }
}
