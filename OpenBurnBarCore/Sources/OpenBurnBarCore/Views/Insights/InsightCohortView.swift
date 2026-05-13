import SwiftUI

public struct InsightCohortView: View {
    public let data: InsightWidgetData.Cohort
    public init(data: InsightWidgetData.Cohort) { self.data = data }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            ForEach(Array(data.cells.enumerated()), id: \.offset) { rIdx, row in
                HStack(spacing: 2) {
                    Text(rIdx < data.cohortLabels.count ? data.cohortLabels[rIdx] : "")
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .frame(width: 72, alignment: .trailing)
                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                        ZStack {
                            Rectangle()
                                .fill(colorFor(value: value))
                                .frame(height: 20)
                            if let v = value {
                                Text(String(format: "%.0f%%", v * 100))
                                    .font(UnifiedDesignSystem.Typography.tiny)
                                    .foregroundStyle(v > 0.4 ? .white : UnifiedDesignSystem.Colors.textSecondary)
                            }
                        }
                        .cornerRadius(2)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text("Cohort")
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                .frame(width: 72, alignment: .trailing)
            ForEach(data.periodLabels, id: \.self) { label in
                Text(label)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func colorFor(value: Double?) -> Color {
        guard let v = value else { return UnifiedDesignSystem.Colors.surface }
        return UnifiedDesignSystem.Colors.whimsy.opacity(0.15 + 0.65 * v)
    }
}
