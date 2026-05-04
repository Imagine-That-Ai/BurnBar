import SwiftUI
import OpenBurnBarCore

struct DashboardActivityLaneView: View {
    var usages: [TokenUsage]
    var topModels: [(model: String, provider: AgentProvider, cost: Double, tokens: Int)]
    var settingsManager: SettingsManager
    var overviewAppeared: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
            UnifiedGlassCard {
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                    Text("Recent Sessions").font(UnifiedDesignSystem.Typography.headline).foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                        ForEach(Array(usages.prefix(6))) { usage in
                            SessionPreviewRow(usage: usage, settingsManager: settingsManager)
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
                    Text("Model Leaders").font(UnifiedDesignSystem.Typography.headline).foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    VStack(spacing: UnifiedDesignSystem.Spacing.md) {
                        ForEach(Array(topModels.prefix(4).enumerated()), id: \.offset) { index, item in
                            HStack(spacing: UnifiedDesignSystem.Spacing.md) {
                                Text("\(index + 1)").font(UnifiedDesignSystem.Typography.monoSmall).foregroundStyle(UnifiedDesignSystem.Colors.textMuted).frame(width: 16, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.model).font(UnifiedDesignSystem.Typography.body).foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                                    Text(item.provider.displayName).font(UnifiedDesignSystem.Typography.tiny).foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                }
                                Spacer()
                                Text(settingsManager.formatUsageMetric(cost: item.cost, tokens: item.tokens)).font(UnifiedDesignSystem.Typography.monoSmall).foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                            }
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
