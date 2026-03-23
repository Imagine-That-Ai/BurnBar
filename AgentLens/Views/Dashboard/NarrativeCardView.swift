import SwiftUI

struct NarrativeCardView: View {
    let dataStore: DataStore

    private var narrative: Insight {
        InsightEngine.generateNarrative(from: dataStore)
    }

    var body: some View {
        if dataStore.usages.isEmpty {
            EmptyView()
        } else {
            GlassCard {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    Image(systemName: narrative.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text(narrative.headline)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        if let detail = narrative.detail {
                            Text(detail)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }
                    Spacer()
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}
