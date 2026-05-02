import SwiftUI

struct DashboardActivityLaneView: View {
    var usages: [TokenUsage]
    var topModels: [(model: String, provider: AgentProvider, cost: Double, tokens: Int)]
    var settingsManager: SettingsManager
    var overviewAppeared: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    Text("Recent Sessions").font(DesignSystem.Typography.headline).foregroundStyle(DesignSystem.Colors.textPrimary)
                    VStack(spacing: DesignSystem.Spacing.sm) {
                        ForEach(Array(usages.prefix(6))) { usage in
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
                    Text("Model Leaders").font(DesignSystem.Typography.headline).foregroundStyle(DesignSystem.Colors.textPrimary)
                    VStack(spacing: DesignSystem.Spacing.md) {
                        ForEach(Array(topModels.prefix(4).enumerated()), id: \.offset) { index, item in
                            HStack(spacing: DesignSystem.Spacing.md) {
                                Text("\(index + 1)").font(DesignSystem.Typography.monoSmall).foregroundStyle(DesignSystem.Colors.textMuted).frame(width: 16, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.model).font(DesignSystem.Typography.body).foregroundStyle(DesignSystem.Colors.textPrimary)
                                    Text(item.provider.displayName).font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                                Spacer()
                                Text(settingsManager.formatUsageMetric(cost: item.cost, tokens: item.tokens)).font(DesignSystem.Typography.monoSmall).foregroundStyle(DesignSystem.Colors.textPrimary)
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
}
