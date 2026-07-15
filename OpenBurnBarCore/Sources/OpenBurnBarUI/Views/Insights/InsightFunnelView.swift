import SwiftUI
import OpenBurnBarInsights

struct InsightFunnelView: View {
    let data: InsightWidgetData.Funnel
    init(data: InsightWidgetData.Funnel) { self.data = data }

    var body: some View {
        let maxCount = data.steps.map(\.count).max() ?? 1
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            ForEach(data.steps) { step in
                HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                    Text(step.label)
                        .font(UnifiedDesignSystem.Typography.caption)
                        .frame(width: 84, alignment: .trailing)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    GeometryReader { proxy in
                        let w = maxCount > 0 ? CGFloat(step.count / maxCount) * proxy.size.width : 0
                        RoundedRectangle(cornerRadius: 4)
                            .fill(UnifiedDesignSystem.primaryGradient)
                            .frame(width: w, height: 22)
                    }
                    .frame(height: 22)
                    Text(String(format: "%.0f", step.count))
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .frame(width: 38, alignment: .leading)
                }
            }
        }
    }
}
