import SwiftUI
import Charts

public struct InsightTimeSeriesView: View {
    public let data: InsightWidgetData.TimeSeries
    public let spec: InsightWidgetSpec

    public init(data: InsightWidgetData.TimeSeries, spec: InsightWidgetSpec) {
        self.data = data
        self.spec = spec
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            if data.series.count > 1 {
                legend
            }
            chart
        }
    }

    private var legend: some View {
        FlowLayout(spacing: 10) {
            ForEach(data.series) { series in
                HStack(spacing: 4) {
                    Circle()
                        .fill(
                            InsightFormatting.color(forHex: series.colorHex)
                                ?? InsightFormatting.color(forSeriesID: series.id)
                        )
                        .frame(width: 8, height: 8)
                    Text(series.name)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(data.series) { series in
                ForEach(series.points, id: \.date) { point in
                    switch style {
                    case .line:
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value(data.yAxisLabel, point.value)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Series", series.name))
                    case .area, .stackedArea, .stream:
                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value(data.yAxisLabel, point.value),
                            stacking: stacking
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Series", series.name))
                    case .bar:
                        BarMark(
                            x: .value("Date", point.date),
                            y: .value(data.yAxisLabel, point.value)
                        )
                        .foregroundStyle(by: .value("Series", series.name))
                    case .stackedBar:
                        BarMark(
                            x: .value("Date", point.date),
                            y: .value(data.yAxisLabel, point.value),
                            stacking: .standard
                        )
                        .foregroundStyle(by: .value("Series", series.name))
                    }
                }
            }
            ForEach(Array(data.annotations.enumerated()), id: \.offset) { _, annotation in
                RuleMark(x: .value("Annotation", annotation.date))
                    .foregroundStyle(toneColor(annotation.tone).opacity(0.5))
                    .annotation(position: .top) {
                        Text(annotation.label)
                            .font(UnifiedDesignSystem.Typography.tiny)
                            .foregroundStyle(toneColor(annotation.tone))
                    }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(UnifiedDesignSystem.Colors.borderSubtle)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(InsightFormatting.format(raw, as: data.yFormat))
                            .font(UnifiedDesignSystem.Typography.tiny)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.5))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    private var style: InsightWidgetSpec.TimeSeriesSpec.Style {
        if case .timeSeries(let s) = spec { return s.style }
        return .line
    }

    private var stacking: MarkStackingMethod {
        switch style {
        case .stackedArea: return .standard
        case .stream: return .center
        case .area: return .standard
        default: return .unstacked
        }
    }

    private func toneColor(_ tone: InsightWidgetData.TimeSeries.Annotation.Tone) -> Color {
        switch tone {
        case .positive: return UnifiedDesignSystem.Colors.success
        case .neutral: return UnifiedDesignSystem.Colors.textSecondary
        case .warning: return UnifiedDesignSystem.Colors.warning
        case .negative: return UnifiedDesignSystem.Colors.error
        }
    }
}
