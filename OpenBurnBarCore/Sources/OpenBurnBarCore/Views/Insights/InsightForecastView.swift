import SwiftUI
import Charts

public struct InsightForecastView: View {
    public let data: InsightWidgetData.Forecast
    public init(data: InsightWidgetData.Forecast) { self.data = data }

    public var body: some View {
        Chart {
            // Actual
            ForEach(data.actual, id: \.date) { point in
                LineMark(x: .value("Date", point.date), y: .value(data.yAxisLabel, point.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(UnifiedDesignSystem.Colors.ember)
            }
            // Confidence band
            ForEach(Array(zip(data.lowerBound, data.upperBound).enumerated()), id: \.offset) { _, pair in
                AreaMark(
                    x: .value("Date", pair.0.date),
                    yStart: .value("Lower", pair.0.value),
                    yEnd: .value("Upper", pair.1.value)
                )
                .foregroundStyle(UnifiedDesignSystem.Colors.whimsy.opacity(0.18))
            }
            // Forecast
            ForEach(data.forecast, id: \.date) { point in
                LineMark(x: .value("Date", point.date), y: .value(data.yAxisLabel, point.value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, dash: [4, 3]))
                    .foregroundStyle(UnifiedDesignSystem.Colors.whimsy)
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(UnifiedDesignSystem.Colors.borderSubtle)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(InsightFormatting.format(v, as: data.yFormat))
                            .font(UnifiedDesignSystem.Typography.tiny)
                    }
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let summary = data.summary, !summary.isEmpty {
                Text(summary)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}
