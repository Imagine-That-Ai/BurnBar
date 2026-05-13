import SwiftUI

public struct InsightHeatmapView: View {
    public let data: InsightWidgetData.Heatmap
    public init(data: InsightWidgetData.Heatmap) { self.data = data }

    public var body: some View {
        let maxValue = data.cells.flatMap { $0 }.max() ?? 1
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(data.cells.enumerated()), id: \.offset) { rIdx, row in
                HStack(spacing: 2) {
                    Text(rIdx < data.rowLabels.count ? data.rowLabels[rIdx] : "")
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .frame(width: 28, alignment: .trailing)
                    GeometryReader { proxy in
                        let cellSize = proxy.size.width / CGFloat(row.count)
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { cIdx, value in
                                Rectangle()
                                    .fill(colorFor(value: value, max: maxValue))
                                    .frame(width: cellSize - 1, height: cellSize - 1)
                                    .cornerRadius(2)
                                    .padding(.trailing, 1)
                                    .accessibilityLabel("\(data.rowLabels[safe: rIdx] ?? "") \(data.columnLabels[safe: cIdx] ?? "")")
                                    .accessibilityValue(InsightFormatting.format(value, as: data.valueFormat))
                            }
                        }
                    }
                    .frame(height: 18)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 7 * 18)
    }

    private func colorFor(value: Double, max: Double) -> Color {
        guard max > 0 else { return UnifiedDesignSystem.Colors.surface }
        let t = min(1, value / max)
        return UnifiedDesignSystem.Colors.ember.opacity(0.15 + 0.7 * t)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
