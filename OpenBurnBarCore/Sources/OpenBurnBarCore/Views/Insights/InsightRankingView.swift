import SwiftUI
import Charts

public struct InsightRankingView: View {
    public let data: InsightWidgetData.Ranking
    public init(data: InsightWidgetData.Ranking) { self.data = data }

    public var body: some View {
        Chart {
            ForEach(data.rows) { row in
                BarMark(
                    x: .value("Value", row.value),
                    y: .value(data.dimensionLabel, row.label)
                )
                .foregroundStyle(InsightFormatting.color(forHex: row.colorHex)
                                 ?? InsightFormatting.color(forSeriesID: row.id))
                .annotation(position: .trailing, alignment: .leading) {
                    Text(InsightFormatting.format(row.value, as: data.valueFormat))
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisValueLabel()
                    .font(UnifiedDesignSystem.Typography.caption)
            }
        }
        .frame(maxWidth: .infinity, minHeight: CGFloat(max(60, data.rows.count * 22)))
        .accessibilityChartDescriptor(self)
        .accessibilityLabel(InsightChartAccessibility.rankingSummary(data))
    }
}

// MARK: - Accessibility

extension InsightRankingView: @preconcurrency AXChartDescriptorRepresentable {
    /// VoiceOver audio-graph descriptor. Mapping lives in
    /// `InsightChartAccessibility` so it is unit-testable without a view.
    public func makeChartDescriptor() -> AXChartDescriptor {
        InsightChartAccessibility.rankingDescriptor(data)
    }
}
