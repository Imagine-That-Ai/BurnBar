import SwiftUI
import Charts

public struct InsightScatterView: View {
    public let data: InsightWidgetData.Scatter
    public init(data: InsightWidgetData.Scatter) { self.data = data }

    public var body: some View {
        Chart {
            ForEach(data.points) { point in
                PointMark(
                    x: .value(data.xAxisLabel, point.x),
                    y: .value(data.yAxisLabel, point.y)
                )
                .symbolSize(by: .value("Size", point.size))
                .foregroundStyle(
                    InsightFormatting.color(forHex: point.colorHex)
                        ?? InsightFormatting.color(forSeriesID: point.id)
                )
                .annotation(position: .top, alignment: .center) {
                    Text(point.label)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(UnifiedDesignSystem.Colors.borderSubtle)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(InsightFormatting.format(v, as: data.xFormat))
                            .font(UnifiedDesignSystem.Typography.tiny)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(UnifiedDesignSystem.Colors.borderSubtle)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(InsightFormatting.format(v, as: data.yFormat))
                            .font(UnifiedDesignSystem.Typography.tiny)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}
