import Foundation
#if canImport(Accessibility)
import Accessibility
#endif

// MARK: - Insight Chart Accessibility
//
// Pure, testable accessibility engine for the shared Insight widget
// renderers (used by macOS AgentLens and iOS OpenBurnBarMobile alike).
// Everything VoiceOver reads about a chart-shaped `InsightWidgetData`
// is derived here so the mapping stays unit-testable without views:
//
//   - `summary(for:)` → a spoken summary for any chart-like variant
//     (series names, axis ranges, totals, peaks)
//   - `*Descriptor(...)` → `AXChartDescriptor`s powering VoiceOver
//     audio graphs on the Swift Charts-backed renderers
//   - `sparklineSummary(values:format:)` → labels for KPI sparklines
public enum InsightChartAccessibility {

    // MARK: - Summaries

    /// Spoken summary for a widget's data. Returns nil for text-first
    /// variants (narrative, recommendation, tables) whose content is
    /// already accessible as regular text.
    public static func summary(for data: InsightWidgetData) -> String? {
        switch data {
        case .kpi(let kpi):
            return kpiSummary(kpi)
        case .timeSeries(let ts):
            return timeSeriesSummary(ts)
        case .ranking(let r):
            return rankingSummary(r)
        case .distribution(let d):
            return distributionSummary(d)
        case .heatmap(let h):
            return heatmapSummary(h)
        case .scatter(let s):
            return scatterSummary(s)
        case .sankey(let s):
            return sankeySummary(s)
        case .radar(let r):
            return radarSummary(r)
        case .forecast(let f):
            return forecastSummary(f)
        case .composed(let children):
            let parts = children.prefix(4).compactMap { summary(for: $0) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        case .empty(let reason):
            return "No data: \(reason)"
        case .error(let message):
            return "Error: \(message)"
        case .cohort, .funnel, .quota, .anomaly, .narrative, .recommendation,
             .useCaseCluster, .focusMatrix, .drilldown, .mermaid, .ascii:
            // These renderers already surface their values as text.
            return nil
        }
    }

    public static func kpiSummary(_ kpi: InsightWidgetData.KPI) -> String {
        var out = "\(kpi.metricLabel): \(InsightFormatting.format(kpi.value, as: kpi.valueFormat))."
        if let delta = kpi.delta {
            let direction = delta >= 0 ? "up" : "down"
            out += " \(direction.capitalized) \(InsightFormatting.formatDelta(delta, asPercent: kpi.deltaIsPercent))."
        }
        if let ctx = kpi.contextLabel, !ctx.isEmpty { out += " \(ctx)." }
        if kpi.sparkline.count > 1 {
            out += " Trend: \(sparklineSummary(values: kpi.sparkline, format: kpi.valueFormat))."
        }
        return out
    }

    public static func timeSeriesSummary(_ data: InsightWidgetData.TimeSeries) -> String {
        let allPoints = data.series.flatMap(\.points)
        guard !allPoints.isEmpty else { return "Time series chart. No data in this window yet." }
        var parts: [String] = []
        let names = data.series.map(\.name)
        if names.count == 1 {
            parts.append("Time series chart, 1 series: \(names[0]), \(allPoints.count) points.")
        } else {
            parts.append("Time series chart, \(names.count) series: \(names.joined(separator: ", ")).")
        }
        let dates = allPoints.map(\.date)
        if let minDate = dates.min(), let maxDate = dates.max() {
            let f = axDateFormatter
            parts.append("\(data.xAxisLabel), from \(f.string(from: minDate)) to \(f.string(from: maxDate)).")
        }
        let values = allPoints.map(\.value)
        if let minV = values.min(), let maxV = values.max() {
            parts.append("\(data.yAxisLabel) ranges from \(InsightFormatting.format(minV, as: data.yFormat)) to \(InsightFormatting.format(maxV, as: data.yFormat)).")
        }
        if !data.annotations.isEmpty {
            let labels = data.annotations.prefix(3).map(\.label).joined(separator: ", ")
            parts.append("Annotations: \(labels).")
        }
        return parts.joined(separator: " ")
    }

    public static func rankingSummary(_ data: InsightWidgetData.Ranking) -> String {
        guard !data.rows.isEmpty else { return "Ranking chart. No rows." }
        var parts = ["Ranking by \(data.dimensionLabel), \(data.rows.count) rows."]
        if let top = data.rows.max(by: { $0.value < $1.value }) {
            parts.append("Top: \(top.label), \(InsightFormatting.format(top.value, as: data.valueFormat)).")
        }
        return parts.joined(separator: " ")
    }

    public static func distributionSummary(_ data: InsightWidgetData.Distribution) -> String {
        guard !data.slices.isEmpty else { return "Distribution chart. No slices." }
        var parts = [
            "Distribution, \(data.slices.count) slices, total \(InsightFormatting.format(data.total, as: data.valueFormat))."
        ]
        let top = data.slices.sorted { $0.value > $1.value }.prefix(3).map { slice -> String in
            let pct = data.total > 0 ? Int((slice.value / data.total * 100).rounded()) : 0
            return "\(slice.label) \(InsightFormatting.format(slice.value, as: data.valueFormat)) (\(pct)%)"
        }
        if !top.isEmpty { parts.append("Largest: \(top.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }

    public static func heatmapSummary(_ data: InsightWidgetData.Heatmap) -> String {
        let rows = data.cells.count
        let cols = data.cells.first?.count ?? 0
        var parts = ["Heat map, \(rows) rows by \(cols) columns."]
        var peak: (row: Int, col: Int, value: Double)?
        for (r, row) in data.cells.enumerated() {
            for (c, value) in row.enumerated() where value > (peak?.value ?? -.infinity) {
                peak = (r, c, value)
            }
        }
        if let peak, peak.value > 0 {
            let rowLabel = peak.row < data.rowLabels.count ? data.rowLabels[peak.row] : "row \(peak.row + 1)"
            let colLabel = peak.col < data.columnLabels.count ? data.columnLabels[peak.col] : "column \(peak.col + 1)"
            parts.append("Peak at \(rowLabel), \(colLabel): \(InsightFormatting.format(peak.value, as: data.valueFormat)).")
        }
        return parts.joined(separator: " ")
    }

    public static func scatterSummary(_ data: InsightWidgetData.Scatter) -> String {
        guard !data.points.isEmpty else { return "Scatter plot. No points." }
        var parts = ["Scatter plot of \(data.yAxisLabel) versus \(data.xAxisLabel), \(data.points.count) points."]
        let xs = data.points.map(\.x)
        let ys = data.points.map(\.y)
        if let minX = xs.min(), let maxX = xs.max() {
            parts.append("\(data.xAxisLabel) from \(InsightFormatting.format(minX, as: data.xFormat)) to \(InsightFormatting.format(maxX, as: data.xFormat)).")
        }
        if let minY = ys.min(), let maxY = ys.max() {
            parts.append("\(data.yAxisLabel) from \(InsightFormatting.format(minY, as: data.yFormat)) to \(InsightFormatting.format(maxY, as: data.yFormat)).")
        }
        return parts.joined(separator: " ")
    }

    public static func sankeySummary(_ data: InsightWidgetData.Sankey) -> String {
        guard !data.links.isEmpty else { return "Flow chart. No flows." }
        let lookup = Dictionary(uniqueKeysWithValues: data.nodes.map { ($0.id, $0.label) })
        let top = data.links.sorted { $0.value > $1.value }.prefix(4).map { link in
            "\(lookup[link.source] ?? link.source) to \(lookup[link.target] ?? link.target) \(InsightFormatting.tokensFormatter(link.value))"
        }
        return "Flow chart, \(data.links.count) flows. Largest: \(top.joined(separator: "; "))."
    }

    public static func radarSummary(_ data: InsightWidgetData.Radar) -> String {
        guard !data.series.isEmpty, !data.axes.isEmpty else { return "Radar chart. No data." }
        var parts = ["Radar chart across \(data.axes.joined(separator: ", "))."]
        for series in data.series.prefix(3) {
            if let maxIdx = series.values.indices.max(by: { series.values[$0] < series.values[$1] }),
               maxIdx < data.axes.count {
                parts.append("\(series.name) peaks at \(data.axes[maxIdx]) (\(Int((series.values[maxIdx] * 100).rounded()))%).")
            }
        }
        return parts.joined(separator: " ")
    }

    public static func forecastSummary(_ data: InsightWidgetData.Forecast) -> String {
        var parts = ["Forecast chart."]
        if let lastActual = data.actual.last {
            parts.append("Actual \(data.yAxisLabel) ends at \(InsightFormatting.format(lastActual.value, as: data.yFormat)) on \(axDateFormatter.string(from: lastActual.date)).")
        }
        if let lastForecast = data.forecast.last {
            parts.append("Projected to reach \(InsightFormatting.format(lastForecast.value, as: data.yFormat)) by \(axDateFormatter.string(from: lastForecast.date)).")
        }
        if let summary = data.summary, !summary.isEmpty { parts.append(summary) }
        return parts.joined(separator: " ")
    }

    /// Short spoken description of a sparkline: direction + endpoints.
    public static func sparklineSummary(values: [Double], format: ValueFormat = .raw) -> String {
        guard let first = values.first else { return "no data" }
        guard values.count > 1, let last = values.last else {
            return "single value \(InsightFormatting.format(first, as: format))"
        }
        let direction: String
        if last > first { direction = "up" } else if last < first { direction = "down" } else { direction = "flat" }
        return "trending \(direction), from \(InsightFormatting.format(first, as: format)) to \(InsightFormatting.format(last, as: format))"
    }

    static var axDateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }

#if canImport(Accessibility)

    // MARK: - AXChartDescriptors

    /// Audio-graph descriptor for the time-series renderer.
    public static func timeSeriesDescriptor(_ data: InsightWidgetData.TimeSeries) -> AXChartDescriptor {
        let allPoints = data.series.flatMap(\.points)
        let intervals = allPoints.map { $0.date.timeIntervalSinceReferenceDate }
        let lower = intervals.min() ?? 0
        let upper = Swift.max(intervals.max() ?? 1, lower + 1)
        let xAxis = AXNumericDataAxisDescriptor(
            title: data.xAxisLabel,
            range: lower...upper,
            gridlinePositions: []
        ) { interval in
            axDateFormatter.string(from: Date(timeIntervalSinceReferenceDate: interval))
        }
        let yAxis = numericYAxis(
            title: data.yAxisLabel,
            values: allPoints.map(\.value),
            format: data.yFormat
        )
        let series = data.series.map { s in
            AXDataSeriesDescriptor(
                name: s.name,
                isContinuous: true,
                dataPoints: s.points.map {
                    AXDataPoint(x: $0.date.timeIntervalSinceReferenceDate, y: $0.value)
                }
            )
        }
        return AXChartDescriptor(
            title: nil,
            summary: timeSeriesSummary(data),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: series
        )
    }

    /// Audio-graph descriptor for the horizontal ranking bars.
    public static func rankingDescriptor(_ data: InsightWidgetData.Ranking) -> AXChartDescriptor {
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: data.dimensionLabel,
            categoryOrder: data.rows.map(\.label)
        )
        let yAxis = numericYAxis(
            title: "Value",
            values: data.rows.map(\.value),
            format: data.valueFormat
        )
        let series = AXDataSeriesDescriptor(
            name: data.dimensionLabel,
            isContinuous: false,
            dataPoints: data.rows.map {
                AXDataPoint(x: $0.label, y: $0.value, additionalValues: [], label: $0.secondaryLabel)
            }
        )
        return AXChartDescriptor(
            title: nil,
            summary: rankingSummary(data),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }

    /// Audio-graph descriptor for the donut/pie distribution.
    public static func distributionDescriptor(_ data: InsightWidgetData.Distribution) -> AXChartDescriptor {
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Slice",
            categoryOrder: data.slices.map(\.label)
        )
        let yAxis = numericYAxis(
            title: "Value",
            values: data.slices.map(\.value),
            format: data.valueFormat
        )
        let series = AXDataSeriesDescriptor(
            name: "Distribution",
            isContinuous: false,
            dataPoints: data.slices.map { AXDataPoint(x: $0.label, y: $0.value) }
        )
        return AXChartDescriptor(
            title: nil,
            summary: distributionSummary(data),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }

    /// Audio-graph descriptor for the scatter renderer.
    public static func scatterDescriptor(_ data: InsightWidgetData.Scatter) -> AXChartDescriptor {
        let xs = data.points.map(\.x)
        let lower = xs.min() ?? 0
        let upper = Swift.max(xs.max() ?? 1, lower + 0.001)
        let xFormat = data.xFormat
        let xAxis = AXNumericDataAxisDescriptor(
            title: data.xAxisLabel,
            range: lower...upper,
            gridlinePositions: []
        ) { InsightFormatting.format($0, as: xFormat) }
        let yAxis = numericYAxis(
            title: data.yAxisLabel,
            values: data.points.map(\.y),
            format: data.yFormat
        )
        let series = AXDataSeriesDescriptor(
            name: data.yAxisLabel,
            isContinuous: false,
            dataPoints: data.points.map {
                AXDataPoint(x: $0.x, y: $0.y, additionalValues: [], label: $0.label)
            }
        )
        return AXChartDescriptor(
            title: nil,
            summary: scatterSummary(data),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }

    /// Audio-graph descriptor for the forecast renderer (actual +
    /// projected series).
    public static func forecastDescriptor(_ data: InsightWidgetData.Forecast) -> AXChartDescriptor {
        let allPoints = data.actual + data.forecast
        let intervals = allPoints.map { $0.date.timeIntervalSinceReferenceDate }
        let lower = intervals.min() ?? 0
        let upper = Swift.max(intervals.max() ?? 1, lower + 1)
        let xAxis = AXNumericDataAxisDescriptor(
            title: data.xAxisLabel,
            range: lower...upper,
            gridlinePositions: []
        ) { interval in
            axDateFormatter.string(from: Date(timeIntervalSinceReferenceDate: interval))
        }
        let yAxis = numericYAxis(
            title: data.yAxisLabel,
            values: allPoints.map(\.value) + data.upperBound.map(\.value) + data.lowerBound.map(\.value),
            format: data.yFormat
        )
        func series(_ name: String, _ points: [InsightWidgetData.TimeSeries.Point]) -> AXDataSeriesDescriptor {
            AXDataSeriesDescriptor(
                name: name,
                isContinuous: true,
                dataPoints: points.map {
                    AXDataPoint(x: $0.date.timeIntervalSinceReferenceDate, y: $0.value)
                }
            )
        }
        return AXChartDescriptor(
            title: nil,
            summary: forecastSummary(data),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series("Actual", data.actual), series("Forecast", data.forecast)]
        )
    }

    private static func numericYAxis(
        title: String,
        values: [Double],
        format: ValueFormat
    ) -> AXNumericDataAxisDescriptor {
        let lower = Swift.min(0, values.min() ?? 0)
        let upper = Swift.max(values.max() ?? 1, lower + 0.001)
        return AXNumericDataAxisDescriptor(
            title: title,
            range: lower...upper,
            gridlinePositions: []
        ) { InsightFormatting.format($0, as: format) }
    }

#endif
}
