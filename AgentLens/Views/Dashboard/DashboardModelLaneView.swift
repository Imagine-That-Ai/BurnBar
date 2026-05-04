import SwiftUI
import OpenBurnBarCore

struct DashboardModelLaneView: View {
    var models: [ModelSummary]
    var overviewAppeared: Bool = true
    var onNavigateToModel: (String) -> Void = { _ in }

    var body: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                        Text("Model Ranking").font(UnifiedDesignSystem.Typography.headline).foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        Text("Cost, session volume, and agent mix across all tracked models.").font(UnifiedDesignSystem.Typography.caption).foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    }
                    Spacer()
                }
                VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, summary in
                        ModelCard(summary: summary, rank: index + 1) {
                            withAnimation(UnifiedDesignSystem.Animation.standard) {
                                onNavigateToModel(summary.modelName)
                            }
                        }
                        .opacity(overviewAppeared ? 1 : 0)
                        .offset(y: overviewAppeared ? 0 : 8)
                        .animation(UnifiedDesignSystem.Animation.standard.delay(Double(index) * 0.06), value: overviewAppeared)
                    }
                }
            }
            .padding(UnifiedDesignSystem.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(overviewAppeared ? 1 : 0)
        .offset(y: overviewAppeared ? 0 : 8)
        .animation(UnifiedDesignSystem.Animation.standard.delay(0.24), value: overviewAppeared)
    }
}
