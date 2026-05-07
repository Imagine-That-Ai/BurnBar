import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Native Chart View
//
// Renders a `ChartSpec` using Swift Charts. We split per (axis-type, mark-type)
// pair into small explicit views so the Swift type-checker doesn't choke on
// a giant Chart-builder closure.

struct NativeChartView: View {
    let spec: ChartSpec

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            header
            chartContent
                .frame(minHeight: 220, idealHeight: 260)
                .accessibilityChartDescriptor(self)
            legend
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(spec.title)
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            if let subtitle = spec.subtitle {
                Text(subtitle)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var legend: some View {
        if spec.series.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(spec.series.enumerated()), id: \.offset) { index, series in
                        legendChip(series: series, index: index)
                    }
                }
            }
        }
    }

    private func legendChip(series: ChartSpec.Series, index: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(palette[index % palette.count])
                .frame(width: 8, height: 8)
            Text(series.name)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(MobileTheme.Colors.surface.opacity(0.5)))
    }

    @ViewBuilder
    private var chartContent: some View {
        switch xKind {
        case .time:
            switch spec.kind {
            case .line, .area:
                TimeLineChart(spec: spec, palette: palette, fillArea: spec.kind == .area)
            case .bar, .stackedBar:
                TimeBarChart(spec: spec, palette: palette)
            case .stream, .stackedArea:
                TimeStackedAreaChart(spec: spec, palette: palette)
            case .scatter:
                TimeScatterChart(spec: spec, palette: palette)
            case .heatmap:
                CategoricalHeatmapChart(spec: spec)
            case .donut:
                DonutChart(spec: spec, palette: palette)
            case .rule:
                RuleOnlyChart(spec: spec)
            }
        case .number:
            switch spec.kind {
            case .scatter:
                NumericScatterChart(spec: spec, palette: palette)
            case .bar:
                NumericBarChart(spec: spec, palette: palette)
            case .donut:
                DonutChart(spec: spec, palette: palette)
            default:
                NumericLineChart(spec: spec, palette: palette)
            }
        case .category:
            switch spec.kind {
            case .donut:
                DonutChart(spec: spec, palette: palette)
            case .heatmap:
                CategoricalHeatmapChart(spec: spec)
            default:
                CategoricalBarChart(spec: spec, palette: palette)
            }
        }
    }

    // MARK: - Inferred X kind

    private enum InferredXKind { case time, number, category }

    private var xKind: InferredXKind {
        switch spec.xAxis?.kind?.lowercased() {
        case "time":     return .time
        case "linear":   return .number
        case "category": return .category
        default: break
        }
        for series in spec.series {
            for point in series.points {
                if point.x.asDate != nil { return .time }
                if case .double = point.x { return .number }
                if case .int = point.x    { return .number }
                if case .string = point.x { return .category }
            }
        }
        return .category
    }

    // MARK: - Palette

    private var palette: [Color] {
        spec.series.enumerated().map { index, s in color(for: s, index: index) }
    }

    private func color(for series: ChartSpec.Series, index: Int) -> Color {
        if let hex = series.color, let parsed = Self.parseHex(hex) {
            return parsed
        }
        let p: [Color] = [
            MobileTheme.ember, MobileTheme.whimsy, MobileTheme.amber,
            MobileTheme.hermesAureate, MobileTheme.success, MobileTheme.blaze,
            MobileTheme.hermesMercury, MobileTheme.warning
        ]
        return p[index % p.count]
    }

    static func parseHex(_ hex: String) -> Color? {
        var s = hex.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Time-series subviews

private struct TimeLineChart: View {
    let spec: ChartSpec
    let palette: [Color]
    let fillArea: Bool

    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.self) { point in
                    let date = point.x.asDate ?? Date()
                    LineMark(x: .value("Date", date, unit: .day), y: .value("Y", point.y))
                        .foregroundStyle(by: .value("Series", series.name))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    if fillArea {
                        AreaMark(x: .value("Date", date, unit: .day), y: .value("Y", point.y))
                            .foregroundStyle(by: .value("Series", series.name))
                            .interpolationMethod(.catmullRom)
                            .opacity(0.18)
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: spec.series.map(\.name), range: palette)
        .modifier(StudioChartChrome(xKind: .time))
    }
}

private struct TimeBarChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.self) { point in
                    let date = point.x.asDate ?? Date()
                    BarMark(x: .value("Date", date, unit: .day), y: .value("Y", point.y))
                        .foregroundStyle(by: .value("Series", series.name))
                        .cornerRadius(4)
                }
            }
        }
        .chartForegroundStyleScale(domain: spec.series.map(\.name), range: palette)
        .modifier(StudioChartChrome(xKind: .time))
    }
}

private struct TimeStackedAreaChart: View {
    let spec: ChartSpec
    let palette: [Color]
    @State private var selected: Date?
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.self) { point in
                    let date = point.x.asDate ?? Date()
                    AreaMark(
                        x: .value("Date", date, unit: .day),
                        y: .value("Y", point.y),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Series", series.name))
                    .interpolationMethod(.catmullRom)
                }
            }
        }
        .chartForegroundStyleScale(domain: spec.series.map(\.name), range: palette)
        .chartXSelection(value: $selected)
        .modifier(StudioChartChrome(xKind: .time))
    }
}

private struct TimeScatterChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.self) { point in
                    let date = point.x.asDate ?? Date()
                    PointMark(x: .value("Date", date, unit: .day), y: .value("Y", point.y))
                        .foregroundStyle(by: .value("Series", series.name))
                        .symbolSize(60)
                }
            }
        }
        .chartForegroundStyleScale(domain: spec.series.map(\.name), range: palette)
        .modifier(StudioChartChrome(xKind: .time))
    }
}

// MARK: - Numeric subviews

private struct NumericScatterChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.self) { point in
                    let x = point.x.asDouble ?? 0
                    PointMark(x: .value("X", x), y: .value("Y", point.y))
                        .foregroundStyle(by: .value("Series", series.name))
                        .symbolSize(60)
                }
            }
        }
        .chartForegroundStyleScale(domain: spec.series.map(\.name), range: palette)
        .modifier(StudioChartChrome(xKind: .auto))
    }
}

private struct NumericBarChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.self) { point in
                    let x = point.x.asDouble ?? 0
                    BarMark(x: .value("X", x), y: .value("Y", point.y))
                        .foregroundStyle(by: .value("Series", series.name))
                        .cornerRadius(4)
                }
            }
        }
        .chartForegroundStyleScale(domain: spec.series.map(\.name), range: palette)
        .modifier(StudioChartChrome(xKind: .auto))
    }
}

private struct NumericLineChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.self) { point in
                    let x = point.x.asDouble ?? 0
                    LineMark(x: .value("X", x), y: .value("Y", point.y))
                        .foregroundStyle(by: .value("Series", series.name))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
            }
        }
        .chartForegroundStyleScale(domain: spec.series.map(\.name), range: palette)
        .modifier(StudioChartChrome(xKind: .auto))
    }
}

// MARK: - Categorical subviews

private struct CategoricalBarChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.self) { point in
                    BarMark(
                        x: .value("X", point.x.asString ?? "—"),
                        y: .value("Y", point.y)
                    )
                    .foregroundStyle(by: .value("Series", series.name))
                    .cornerRadius(4)
                }
            }
        }
        .chartForegroundStyleScale(domain: spec.series.map(\.name), range: palette)
        .modifier(StudioChartChrome(xKind: .auto))
    }
}

private struct CategoricalHeatmapChart: View {
    let spec: ChartSpec
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.self) { point in
                    let xValue = point.x.asString ?? "—"
                    let seriesName = series.name
                    let intensity = point.y
                    RectangleMark(
                        x: .value("X", xValue),
                        y: .value("Series", seriesName)
                    )
                    .foregroundStyle(by: .value("Intensity", intensity))
                }
            }
        }
        .modifier(StudioChartChrome(xKind: .auto))
    }
}

private struct DonutChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.self) { point in
                    SectorMark(
                        angle: .value("Value", point.y),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .cornerRadius(3)
                    .foregroundStyle(by: .value("Slice", point.label ?? (point.x.asString ?? series.name)))
                }
            }
        }
        .chartLegend(.hidden)
        .chartEntrance()
    }
}

private struct RuleOnlyChart: View {
    let spec: ChartSpec
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.self) { point in
                    RuleMark(y: .value("Y", point.y))
                        .foregroundStyle(MobileTheme.amber)
                }
            }
        }
        .modifier(StudioChartChrome(xKind: .auto))
    }
}

// MARK: - Chart Chrome (axes + entrance)

private struct StudioChartChrome: ViewModifier {
    enum XKind { case time, auto }
    let xKind: XKind

    @ViewBuilder
    func body(content: Content) -> some View {
        if xKind == .time {
            content
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine().foregroundStyle(MobileTheme.Colors.border.opacity(0.25))
                        AxisValueLabel(format: .dateTime.month().day())
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(MobileTheme.Colors.border.opacity(0.20))
                        AxisValueLabel().foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                .chartEntrance()
        } else {
            content
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine().foregroundStyle(MobileTheme.Colors.border.opacity(0.25))
                        AxisValueLabel().foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(MobileTheme.Colors.border.opacity(0.20))
                        AxisValueLabel().foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                .chartEntrance()
        }
    }
}

// MARK: - Accessibility

@MainActor extension NativeChartView: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let allPoints = spec.series.flatMap { series -> [(String, Double, String)] in
            series.points.map { (series.name, $0.y, $0.x.asString ?? "—") }
        }
        let yMax = allPoints.map(\.1).max() ?? 1
        let xCategories = (Array(NSOrderedSet(array: allPoints.map(\.2))) as? [String]) ?? []
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: spec.xAxis?.title ?? "X",
            categoryOrder: xCategories
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: spec.yAxis?.title ?? "Y",
            range: 0...yMax,
            gridlinePositions: []
        ) { v in String(v) }

        let series = spec.series.map { s in
            AXDataSeriesDescriptor(
                name: s.name,
                isContinuous: false,
                dataPoints: s.points.map { p in
                    AXDataPoint(
                        x: p.x.asString ?? "—",
                        y: p.y,
                        additionalValues: [],
                        label: p.label
                    )
                }
            )
        }

        return AXChartDescriptor(
            title: spec.title,
            summary: spec.subtitle,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: series
        )
    }
}
