import SwiftUI

struct DashboardProviderLaneView: View {
    var summaries: [ProviderSummary]
    var overviewAppeared: Bool = true
    var onNavigateToProvider: (AgentProvider) -> Void = { _ in }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Provider Ranking").font(DesignSystem.Typography.headline).foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Cost, session volume, and token mix across all tracked agents.").font(DesignSystem.Typography.caption).foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    Spacer()
                }
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                        ProviderCard(summary: summary, rank: index + 1) {
                            withAnimation(DesignSystem.Animation.standard) {
                                onNavigateToProvider(summary.provider)
                            }
                        }
                        .opacity(overviewAppeared ? 1 : 0)
                        .offset(y: overviewAppeared ? 0 : 8)
                        .animation(DesignSystem.Animation.standard.delay(Double(index) * 0.06), value: overviewAppeared)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(overviewAppeared ? 1 : 0)
        .offset(y: overviewAppeared ? 0 : 8)
        .animation(DesignSystem.Animation.standard.delay(0.24), value: overviewAppeared)
    }
}
