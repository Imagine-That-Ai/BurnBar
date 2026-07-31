import Foundation
import CoreGraphics
import Accessibility

// MARK: - Chart Spec Accessibility
//
// Pure, testable accessibility engine for Chart Studio renderings.
// Everything VoiceOver reads about a `ChartSpec` / `AsciiSpec` /
// `InsightSpec` is derived here so the mapping is unit-testable without
// instantiating SwiftUI views:
//
//   - `summaryLabel(for:)`      → spoken chart summary (kind, series,
//                                 axis ranges, totals)
//   - `makeChartDescriptor(for:)` → `AXChartDescriptor` powering VoiceOver
//                                 audio graphs
//   - `marker(forSeriesIndex:)` / `dashPattern(forSeriesIndex:)` → the
//                                 deterministic non-color encodings the
//                                 renderer uses to distinguish series
//   - `asciiSummary(for:)` / `insightSummary(for:)` → labels for the
//                                 non-Swift-Charts canvases
public enum ChartSpecAccessibility {

    // MARK: - Value formatting

    /// Formats a numeric value according to the spec's `valueFormat`
    /// ("currency" | "tokens" | "percent" | "raw" | nil). Mirrors the
    /// on-screen axis formatting so VoiceOver reads the same units the
    /// sighted user sees.
    public static func formattedValue(_ value: Double, format: String?) -> String {
        switch format?.lowercased() {
        case "currency":
            if abs(value) >= 1000 { return String(format: "$%.0f", value) }
            if abs(value) >= 100 { return String(format: "$%.1f", value) }
            return String(format: "$%.2f", value)
        case "tokens":
            return compactNumber(value) + " tokens"
        case "percent":
            return String(format: "%.0f%%", value * 100)
        default:
            return compactNumber(value)
        }
    }

    /// Compact human-readable number (1.2k / 3.4M / 5.6B).
    public static func compactNumber(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if magnitude >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if magnitude >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        if value.rounded() == value { return String(format: "%.0f", value) }
        return String(format: "%.2f", value)
    }

    // MARK: - Kind description

    public static func kindDescription(_ kind: ChartSpec.Kind) -> String {
        switch kind {
        case .line: return "Line chart"
        case .bar: return "Bar chart"
        case .stackedBar: return "Stacked bar chart"
        case .area: return "Area chart"
        case .stackedArea: return "Stacked area chart"
        case .stream: return "Stream chart"
        case .scatter: return "Scatter plot"
        case .heatmap: return "Heat map"
        case .donut: return "Donut chart"
        case .rule: return "Reference line chart"
        }
    }

    // MARK: - Empty detection

    /// True when the spec has no plottable points at all — the renderer
    /// shows a meaningful empty state instead of a blank plot.
    public static func isEmpty(_ spec: ChartSpec) -> Bool {
        spec.series.allSatisfy { $0.points.isEmpty }
    }

    public static func emptyStateLabel(for spec: ChartSpec) -> String {
        "\(kindDescription(spec.kind)): \(spec.title). No data available."
    }

    // MARK: - Inferred X kind (shared with the renderer)

    public enum XKind { case time, number, category }

    /// Single source of truth for how the renderer interprets the x
    /// values — the view and the accessibility descriptor must agree.
    public static func inferredXKind(for spec: ChartSpec) -> XKind {
        switch spec.xAxis?.kind?.lowercased() {
        case "time": return .time
        case "linear": return .number
        case "category": return .category
        default: break
        }
        for series in spec.series {
            for point in series.points {
                if point.x.asDate != nil { return .time }
                if case .double = point.x { return .number }
                if case .int = point.x { return .number }
                if case .string = point.x { return .category }
            }
        }
        return .category
    }

    // MARK: - Summary label

    /// Human summary VoiceOver speaks when the chart element is focused:
    /// kind, title, series names, axis ranges, and (for additive kinds)
    /// the total.
    public static func summaryLabel(for spec: ChartSpec) -> String {
        var parts: [String] = ["\(kindDescription(spec.kind)): \(spec.title)."]
        if let subtitle = spec.subtitle, !subtitle.isEmpty {
            parts.append(sentence(subtitle))
        }
        guard !isEmpty(spec) else {
            parts.append("No data available.")
            return parts.joined(separator: " ")
        }

        if spec.kind == .donut {
            parts.append(donutSummary(for: spec))
            return parts.joined(separator: " ")
        }

        let named = spec.series.filter { !$0.points.isEmpty }
        if named.count == 1 {
            parts.append("1 series: \(named[0].name), \(named[0].points.count) points.")
        } else {
            parts.append("\(named.count) series: \(named.map(\.name).joined(separator: ", ")).")
        }
        if let x = xAxisSummary(for: spec) { parts.append(x) }
        if let y = yAxisSummary(for: spec) { parts.append(y) }
        return parts.joined(separator: " ")
    }

    private static func donutSummary(for spec: ChartSpec) -> String {
        let slices = donutBreakdown(for: spec)
        let total = slices.reduce(0) { $0 + $1.value }
        var out = "\(slices.count) slices, total \(formattedValue(total, format: spec.valueFormat))."
        let top = slices.sorted { $0.value > $1.value }.prefix(4)
        if !top.isEmpty {
            let described = top.map { slice -> String in
                let pct = total > 0 ? Int((slice.value / total * 100).rounded()) : 0
                return "\(slice.label) \(formattedValue(slice.value, format: spec.valueFormat)) (\(pct)%)"
            }
            out += " Largest: \(described.joined(separator: ", "))."
        }
        return out
    }

    private static func xAxisSummary(for spec: ChartSpec) -> String? {
        let allX = spec.series.flatMap { $0.points.map(\.x) }
        guard !allX.isEmpty else { return nil }
        let title = spec.xAxis?.title
        switch inferredXKind(for: spec) {
        case .time:
            let dates = allX.compactMap(\.asDate)
            guard let minDate = dates.min(), let maxDate = dates.max() else { return nil }
            let f = axDateFormatter
            return "X axis: \(title ?? "Time"), from \(f.string(from: minDate)) to \(f.string(from: maxDate))."
        case .number:
            let values = allX.compactMap(\.asDouble)
            guard let minV = values.min(), let maxV = values.max() else { return nil }
            return "X axis: \(title ?? "X"), from \(compactNumber(minV)) to \(compactNumber(maxV))."
        case .category:
            let categories = orderedCategories(for: spec)
            return "X axis: \(title ?? "Category"), \(categories.count) categories."
        }
    }

    private static func yAxisSummary(for spec: ChartSpec) -> String? {
        let values = spec.series.flatMap { $0.points.map(\.y) }
        guard let minV = values.min(), let maxV = values.max() else { return nil }
        var out = "Y axis: \(spec.yAxis?.title.map { "\($0), " } ?? "")ranges from \(formattedValue(minV, format: spec.valueFormat)) to \(formattedValue(maxV, format: spec.valueFormat))."
        if isAdditiveKind(spec.kind) {
            let total = values.reduce(0, +)
            out += " Total \(formattedValue(total, format: spec.valueFormat))."
        }
        return out
    }

    private static func isAdditiveKind(_ kind: ChartSpec.Kind) -> Bool {
        switch kind {
        case .bar, .stackedBar, .stackedArea, .donut: return true
        default: return false
        }
    }

    // MARK: - Donut breakdown

    /// Slice labels (in first-appearance order) with their summed values —
    /// used by the renderer for the textual (non-color) slice breakdown
    /// and by `summaryLabel` for the spoken version.
    public static func donutBreakdown(for spec: ChartSpec) -> [(label: String, value: Double)] {
        var order: [String] = []
        var sums: [String: Double] = [:]
        for series in spec.series {
            for point in series.points {
                let label = point.label ?? point.x.asString ?? series.name
                if sums[label] == nil { order.append(label) }
                sums[label, default: 0] += point.y
            }
        }
        return order.map { ($0, sums[$0] ?? 0) }
    }

    // MARK: - Non-color series encodings

    /// Deterministic per-series marker shapes so multi-series scatter and
    /// point overlays never rely on hue alone.
    public enum SeriesMarker: String, CaseIterable, Equatable {
        case circle, square, triangle, diamond, pentagon, plus, asterisk, cross
    }

    public static func marker(forSeriesIndex index: Int) -> SeriesMarker {
        let all = SeriesMarker.allCases
        let wrapped = ((index % all.count) + all.count) % all.count
        return all[wrapped]
    }

    /// Deterministic per-series dash patterns so multi-series line charts
    /// stay distinguishable without color. Index 0 is always solid.
    public static func dashPattern(forSeriesIndex index: Int) -> [CGFloat] {
        let patterns: [[CGFloat]] = [
            [],            // solid
            [6, 3],
            [2, 3],
            [8, 3, 2, 3],
            [4, 4],
            [1, 3],
            [10, 4],
            [5, 2, 1, 2]
        ]
        let wrapped = ((index % patterns.count) + patterns.count) % patterns.count
        return patterns[wrapped]
    }

    // MARK: - AXChartDescriptor

    /// Builds the descriptor that powers VoiceOver's chart audio graph:
    /// series names, axis titles + ranges, and every data point with its
    /// formatted value.
    public static func makeChartDescriptor(for spec: ChartSpec) -> AXChartDescriptor {
        let xKind = inferredXKind(for: spec)
        let yAxis = makeYAxis(for: spec)
        let series = spec.series.map { s in
            AXDataSeriesDescriptor(
                name: s.name,
                isContinuous: isContinuousKind(spec.kind),
                dataPoints: s.points.map { dataPoint(for: $0, xKind: xKind, format: spec.valueFormat) }
            )
        }
        return AXChartDescriptor(
            title: spec.title,
            summary: summaryLabel(for: spec),
            xAxis: makeXAxis(for: spec, xKind: xKind),
            yAxis: yAxis,
            additionalAxes: [],
            series: series
        )
    }

    static func isContinuousKind(_ kind: ChartSpec.Kind) -> Bool {
        switch kind {
        case .line, .area, .stackedArea, .stream, .rule: return true
        default: return false
        }
    }

    static func orderedCategories(for spec: ChartSpec) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for series in spec.series {
            for point in series.points {
                let value = point.x.asString ?? "—"
                if seen.insert(value).inserted { ordered.append(value) }
            }
        }
        return ordered
    }

    private static func makeXAxis(for spec: ChartSpec, xKind: XKind) -> AXDataAxisDescriptor {
        let title = spec.xAxis?.title
        switch xKind {
        case .time:
            let intervals = spec.series
                .flatMap { $0.points.compactMap { $0.x.asDate?.timeIntervalSinceReferenceDate } }
            let lower = intervals.min() ?? 0
            let upper = Swift.max(intervals.max() ?? 1, lower + 1)
            return AXNumericDataAxisDescriptor(
                title: title ?? "Time",
                range: lower...upper,
                gridlinePositions: []
            ) { interval in
                axDateFormatter.string(from: Date(timeIntervalSinceReferenceDate: interval))
            }
        case .number:
            let values = spec.series.flatMap { $0.points.compactMap { $0.x.asDouble } }
            let lower = values.min() ?? 0
            let upper = Swift.max(values.max() ?? 1, lower + 0.001)
            return AXNumericDataAxisDescriptor(
                title: title ?? "X",
                range: lower...upper,
                gridlinePositions: []
            ) { compactNumber($0) }
        case .category:
            return AXCategoricalDataAxisDescriptor(
                title: title ?? "Category",
                categoryOrder: orderedCategories(for: spec)
            )
        }
    }

    private static func makeYAxis(for spec: ChartSpec) -> AXNumericDataAxisDescriptor {
        let values = spec.series.flatMap { $0.points.map(\.y) }
        let lower = Swift.min(0, values.min() ?? 0)
        let upper = Swift.max(values.max() ?? 1, lower + 0.001)
        let format = spec.valueFormat
        return AXNumericDataAxisDescriptor(
            title: spec.yAxis?.title ?? "Value",
            range: lower...upper,
            gridlinePositions: []
        ) { formattedValue($0, format: format) }
    }

    private static func dataPoint(
        for point: ChartSpec.DataPoint,
        xKind: XKind,
        format: String?
    ) -> AXDataPoint {
        let label = point.label
        switch xKind {
        case .time:
            let interval = point.x.asDate?.timeIntervalSinceReferenceDate ?? 0
            return AXDataPoint(x: interval, y: point.y, additionalValues: [], label: label)
        case .number:
            return AXDataPoint(x: point.x.asDouble ?? 0, y: point.y, additionalValues: [], label: label)
        case .category:
            return AXDataPoint(x: point.x.asString ?? "—", y: point.y, additionalValues: [], label: label)
        }
    }

    private static var axDateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }

    // MARK: - ASCII canvas summary

    /// Spoken summary of a terminal-art canvas. Raw box-drawing art is
    /// noise for VoiceOver, so we strip the art glyphs and read the labels
    /// plus whatever textual data (values, axis text) survives.
    public static func asciiSummary(for spec: AsciiSpec) -> String {
        var parts: [String] = []
        let variantName: String
        switch spec.variant {
        case .bar: variantName = "Terminal bar chart"
        case .sparkline: variantName = "Terminal sparkline"
        case .heatmap: variantName = "Terminal heat map"
        case .banner: variantName = "Terminal banner"
        case .scene: variantName = "Terminal scene"
        }
        if let title = spec.title, !title.isEmpty {
            parts.append("\(variantName): \(title).")
        } else {
            parts.append("\(variantName).")
        }
        if let subtitle = spec.subtitle, !subtitle.isEmpty { parts.append(sentence(subtitle)) }
        let digests = spec.blocks.prefix(8).compactMap { blockDigest($0) }
        if !digests.isEmpty {
            parts.append(digests.joined(separator: "; ") + ".")
        }
        if let footnote = spec.footnote, !footnote.isEmpty { parts.append(sentence(footnote)) }
        return parts.joined(separator: " ")
    }

    /// Strips block/box-drawing glyphs from one block, keeping its label
    /// and any textual fragments (numbers, axis labels).
    static func blockDigest(_ block: AsciiSpec.Block) -> String? {
        let artChars: Set<Character> = [
            "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█",
            "▏", "▎", "▍", "▌", "▋", "▊", "▉",
            "░", "▒", "▓",
            "╭", "╮", "╯", "╰", "─", "│", "├", "┤",
            "┬", "┴", "┼", "═", "║", "╔", "╗",
            "╚", "╝", "╠", "╣", "╦", "╩", "╬", "❯"
        ]
        let fragments = block.lines.compactMap { line -> String? in
            let stripped = String(line.map { artChars.contains($0) ? " " : $0 })
                .split(separator: " ")
                .joined(separator: " ")
            return stripped.isEmpty ? nil : stripped
        }
        var text = fragments.joined(separator: ", ")
        if text.count > 120 { text = String(text.prefix(119)) + "…" }
        let label = block.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (label.isEmpty, text.isEmpty) {
        case (false, false): return "\(label): \(text)"
        case (false, true): return label
        case (true, false): return text
        case (true, true): return nil
        }
    }

    // MARK: - Insight + sparkline summaries

    public static func insightSummary(for spec: InsightSpec) -> String {
        let prefix: String
        switch spec.tone?.lowercased() {
        case "positive": prefix = "Positive insight"
        case "warning": prefix = "Warning insight"
        default: prefix = "Insight"
        }
        var out = "\(prefix): \(spec.title). \(sentence(spec.body))"
        if let spark = spec.sparkline, spark.count > 1 {
            out += " Trend: \(sparklineSummary(values: spark))."
        }
        return out
    }

    /// Short spoken description of a sparkline: direction + endpoints +
    /// extremes.
    public static func sparklineSummary(values: [Double]) -> String {
        guard let first = values.first else { return "no data" }
        guard values.count > 1, let last = values.last else {
            return "single value \(compactNumber(first))"
        }
        let direction: String
        if last > first { direction = "up" } else if last < first { direction = "down" } else { direction = "flat" }
        let lo = values.min() ?? last
        let hi = values.max() ?? last
        return "trending \(direction), from \(compactNumber(first)) to \(compactNumber(last)), low \(compactNumber(lo)), high \(compactNumber(hi))"
    }

    // MARK: - Helpers

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")
            ? trimmed
            : trimmed + "."
    }
}
