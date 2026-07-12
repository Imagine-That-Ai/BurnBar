import SwiftUI
import Charts

public struct InsightTimeSeriesView: View {
    public let data: InsightWidgetData.TimeSeries
    public let spec: InsightWidgetSpec

    public init(data: InsightWidgetData.TimeSeries, spec: InsightWidgetSpec) {
        self.data = data
        self.spec = spec
    }

    @State private var selectedDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            if data.series.count > 1 {
                legend
            }
            if allPoints.isEmpty {
                emptyState
            } else {
                chart
            }
        }
    }

    // MARK: - Legend

    private var legend: some View {
        FlowLayout(spacing: 10) {
            ForEach(Array(data.series.enumerated()), id: \.element.id) { index, series in
                HStack(spacing: 4) {
                    // Marker shape mirrors the chart's per-series symbol so
                    // series identity never relies on hue alone.
                    Self.symbolShape(forSeriesIndex: index)
                        .fill(color(for: series))
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(series.name)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Deterministic per-series symbol shapes shared by the chart marks
    /// and the legend swatches.
    static func symbolShape(forSeriesIndex index: Int) -> BasicChartSymbolShape {
        let shapes: [BasicChartSymbolShape] = [
            .circle, .square, .triangle, .diamond, .pentagon, .plus, .asterisk, .cross
        ]
        let wrapped = ((index % shapes.count) + shapes.count) % shapes.count
        return shapes[wrapped]
    }

    private var symbolScaleRange: [BasicChartSymbolShape] {
        data.series.indices.map { Self.symbolShape(forSeriesIndex: $0) }
    }

    // MARK: - Chart

    // MARK: - Chart

    private var chart: some View {
        Group {
            if style == .line {
                Chart {
                    lineMarks
                    highlightPoints(symbolSize: 36)
                    annotationMarks
                    selectionMarks
                }
            } else if style == .area || style == .stackedArea || style == .stream {
                Chart {
                    areaMarks
                    highlightPoints(symbolSize: 24)
                    annotationMarks
                    selectionMarks
                }
            } else {
                Chart {
                    barMarks
                    annotationMarks
                    selectionMarks
                }
            }
        }
        .chartForegroundStyleScale(
            domain: data.series.map(\.name),
            range: data.series.map { color(for: $0) }
        )
        // Pin symbol assignment to series order so the legend swatches and
        // the plotted marks always show the same shape per series.
        .chartSymbolScale(
            domain: data.series.map(\.name),
            range: symbolScaleRange
        )
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6))
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(InsightFormatting.format(raw, as: data.yFormat))
                            .font(UnifiedDesignSystem.Typography.tiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                    .foregroundStyle(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.35))
                AxisValueLabel(
                    format: xAxisFormat,
                    centered: false,
                    collisionResolution: .greedy(minimumSpacing: 6)
                )
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
        }
        .chartPlotStyle { plot in
            plot
                .background(UnifiedDesignSystem.Colors.surface.opacity(0.35))
                .cornerRadius(8)
        }
        .chartXSelection(value: $selectedDate)
        .frame(maxWidth: .infinity, minHeight: 200)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: data.series.count)
        .accessibilityChartDescriptor(self)
        .accessibilityLabel(InsightChartAccessibility.timeSeriesSummary(data))
    }

    // MARK: - Mark families

    @ChartContentBuilder
    private var lineMarks: some ChartContent {
        ForEach(data.series) { series in
            ForEach(series.points, id: \.self) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value(data.yAxisLabel, point.value)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(by: .value("Series", series.name))
            }
        }
    }

    @ChartContentBuilder
    private var areaMarks: some ChartContent {
        ForEach(data.series) { series in
            ForEach(series.points, id: \.self) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    y: .value(data.yAxisLabel, point.value),
                    stacking: stacking
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(by: .value("Series", series.name))
                .opacity(0.75)
            }
        }
    }

    @ChartContentBuilder
    private var barMarks: some ChartContent {
        ForEach(data.series) { series in
            ForEach(series.points, id: \.self) { point in
                BarMark(
                    x: .value("Date", point.date),
                    y: .value(data.yAxisLabel, point.value),
                    stacking: style == .stackedBar ? .standard : .unstacked
                )
                .cornerRadius(3)
                .foregroundStyle(by: .value("Series", series.name))
            }
        }
    }

    @ChartContentBuilder
    private func highlightPoints(symbolSize: CGFloat) -> some ChartContent {
        ForEach(data.series) { series in
            ForEach(series.points, id: \.self) { point in
                PointMark(
                    x: .value("Date", point.date),
                    y: .value(data.yAxisLabel, point.value)
                )
                .symbol(by: .value("Series", series.name))
                .symbolSize(symbolSize)
                .foregroundStyle(by: .value("Series", series.name))
            }
        }
    }

    @ChartContentBuilder
    private var annotationMarks: some ChartContent {
        ForEach(Array(data.annotations.enumerated()), id: \.offset) { _, annotation in
            RuleMark(x: .value("Annotation", annotation.date))
                .foregroundStyle(toneColor(annotation.tone).opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    Text(annotation.label)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(toneColor(annotation.tone))
                }
        }
    }

    @ChartContentBuilder
    private var selectionMarks: some ChartContent {
        ForEach(activeSelection, id: \.date) { snapshot in
            RuleMark(x: .value("Selected", snapshot.date))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .annotation(
                    position: .top,
                    alignment: .center,
                    spacing: 6,
                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                ) {
                    SelectionCallout(
                        snapshot: snapshot,
                        format: data.yFormat,
                        colorFor: color(for:)
                    )
                }
            ForEach(snapshot.values) { row in
                PointMark(
                    x: .value("Selected", snapshot.date),
                    y: .value(data.yAxisLabel, row.value)
                )
                .symbolSize(110)
                .foregroundStyle(by: .value("Series", row.seriesName))
                .opacity(0.95)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.xs) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Text("No data in this window yet")
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surface.opacity(0.35))
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Selection callout

    private struct SelectionCallout: View {
        let snapshot: SelectionSnapshot
        let format: ValueFormat
        let colorFor: (InsightWidgetData.TimeSeries.Series) -> Color

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                    .font(UnifiedDesignSystem.Typography.tiny.weight(.semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                ForEach(snapshot.values.prefix(4)) { row in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(colorFor(row.series))
                            .frame(width: 6, height: 6)
                        Text(row.seriesName)
                            .font(UnifiedDesignSystem.Typography.tiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(InsightFormatting.format(row.value, as: format))
                            .font(UnifiedDesignSystem.Typography.tiny.weight(.medium))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.thickMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
            )
            .frame(maxWidth: 200, alignment: .leading)
        }
    }

    private struct SelectionSnapshot {
        let date: Date
        let values: [SelectionRow]
    }
    private struct SelectionRow: Identifiable {
        let id: String
        let series: InsightWidgetData.TimeSeries.Series
        let seriesName: String
        let value: Double
    }
    private var activeSelection: [SelectionSnapshot] {
        if let selectedDate, let snapshot = nearestSnapshot(to: selectedDate) {
            return [snapshot]
        }
        return []
    }

    private func nearestSnapshot(to date: Date) -> SelectionSnapshot? {
        var rows: [SelectionRow] = []
        var pivot: Date?
        for series in data.series {
            guard let point = series.points.min(by: {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }) else { continue }
            rows.append(SelectionRow(
                id: series.id,
                series: series,
                seriesName: series.name,
                value: point.value
            ))
            if pivot == nil || abs(point.date.timeIntervalSince(date)) < abs(pivot!.timeIntervalSince(date)) {
                pivot = point.date
            }
        }
        guard !rows.isEmpty, let pivot else { return nil }
        return SelectionSnapshot(date: pivot, values: rows)
    }

    // MARK: - Domains + helpers

    private var allPoints: [InsightWidgetData.TimeSeries.Point] {
        data.series.flatMap(\.points)
    }

    private var yDomain: ClosedRange<Double> {
        let values = allPoints.map(\.value)
        guard let maxValue = values.max(), maxValue > 0 else { return 0...1 }
        let minValue = Swift.min(0, values.min() ?? 0)
        let padded = maxValue * 1.15
        return minValue...Swift.max(padded, maxValue + 0.001)
    }

    private var xDomain: ClosedRange<Date> {
        let dates = allPoints.map(\.date)
        guard let minDate = dates.min(), let maxDate = dates.max() else {
            let now = Date()
            return now.addingTimeInterval(-3600)...now.addingTimeInterval(3600)
        }
        let span = maxDate.timeIntervalSince(minDate)
        if span < 60 * 60 {
            let pad: TimeInterval = 3 * 3600
            return minDate.addingTimeInterval(-pad)...maxDate.addingTimeInterval(pad)
        }
        let pad = span * 0.05
        return minDate.addingTimeInterval(-pad)...maxDate.addingTimeInterval(pad)
    }

    private var xAxisFormat: Date.FormatStyle {
        let dates = allPoints.map(\.date)
        guard let minDate = dates.min(), let maxDate = dates.max() else {
            return .dateTime.month(.abbreviated).day()
        }
        let span = maxDate.timeIntervalSince(minDate)
        if span < 36 * 3600 {
            return .dateTime.hour(.defaultDigits(amPM: .abbreviated))
        }
        if span < 60 * 86_400 {
            return .dateTime.month(.abbreviated).day()
        }
        return .dateTime.month(.abbreviated).year(.twoDigits)
    }

    private var style: InsightWidgetSpec.TimeSeriesSpec.Style {
        if case .timeSeries(let s) = spec { return s.style }
        return .line
    }

    private var isLineFamily: Bool { style == .line }
    private var isAreaFamily: Bool {
        style == .area || style == .stackedArea || style == .stream
    }

    private var stacking: MarkStackingMethod {
        switch style {
        case .stackedArea: return .standard
        case .stream: return .center
        case .area: return .standard
        default: return .unstacked
        }
    }

    private func color(for series: InsightWidgetData.TimeSeries.Series) -> Color {
        InsightFormatting.color(forHex: series.colorHex)
            ?? InsightFormatting.color(forSeriesID: series.id)
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

// MARK: - Accessibility

extension InsightTimeSeriesView: @preconcurrency AXChartDescriptorRepresentable {
    /// VoiceOver audio-graph descriptor. Mapping lives in
    /// `InsightChartAccessibility` so it is unit-testable without a view.
    public func makeChartDescriptor() -> AXChartDescriptor {
        InsightChartAccessibility.timeSeriesDescriptor(data)
    }
}
