import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Native Chart View
//
// Renders a `ChartSpec` using Swift Charts with Aurora polish:
//   - gradient area fills under line / area charts
//   - glow shadows behind key marks
//   - rounded-top bar marks with vertical gradient
//   - larger scatter points with soft halo
//   - warm donut palette with inner gradient ring
//   - subtle chart background wash + card shadow in full mode

struct NativeChartView: View {
    enum DisplayMode {
        case full
        case gallery
    }

    let spec: ChartSpec
    var displayMode: DisplayMode = .full

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: displayMode == .gallery ? 6 : MobileTheme.Spacing.sm) {
            if displayMode == .full {
                header
            }
            if ChartSpecAccessibility.isEmpty(spec) {
                emptyState
            } else {
                chartContent
                    .frame(height: chartHeight)
                    .background(chartBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityChartDescriptor(self)
                    .accessibilityLabel(ChartSpecAccessibility.summaryLabel(for: spec))
                legend
            }
        }
    }

    /// Meaningful empty state — a spec with zero points renders a labeled
    /// placeholder instead of a blank plot, and VoiceOver says why.
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text("No data to chart yet")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .frame(height: chartHeight)
        .background(chartBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChartSpecAccessibility.emptyStateLabel(for: spec))
    }

    var chartHeightForTesting: CGFloat {
        chartHeight
    }

    private var chartHeight: CGFloat {
        switch displayMode {
        case .full:
            switch spec.kind {
            case .donut: return 260
            case .heatmap: return 240
            default: return 260
            }
        case .gallery:
            switch spec.kind {
            case .donut: return 150
            case .scatter: return 170
            case .heatmap: return 155
            default: return 165
            }
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
        if displayMode == .full && spec.kind == .donut {
            donutBreakdown
        } else if displayMode == .full && spec.series.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(spec.series.enumerated()), id: \.offset) { index, series in
                        legendChip(series: series, index: index)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func legendChip(series: ChartSpec.Series, index: Int) -> some View {
        HStack(spacing: 6) {
            legendMarker(index: index)
            Text(series.name)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(MobileTheme.Colors.surface.opacity(0.5)))
    }

    /// Legend swatch that mirrors the chart's non-color series encoding:
    /// line-family kinds show the per-series dash pattern, scatter shows
    /// the per-series marker shape, everything else keeps the color dot.
    @ViewBuilder
    private func legendMarker(index: Int) -> some View {
        let color = palette[index % palette.count]
        switch spec.kind {
        case .line, .area, .stackedArea, .stream, .rule:
            LegendDashSwatch(
                color: color,
                dash: spec.series.count > 1
                    ? ChartSpecAccessibility.dashPattern(forSeriesIndex: index)
                    : []
            )
        case .scatter:
            ChartSpecAccessibility.marker(forSeriesIndex: index)
                .chartSymbolShape
                .fill(color)
                .frame(width: 9, height: 9)
        default:
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
    }

    /// Textual slice breakdown under donut charts so slice identity never
    /// relies on hue alone.
    private var donutBreakdown: some View {
        let slices = ChartSpecAccessibility.donutBreakdown(for: spec)
        let total = slices.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(slices.prefix(6).enumerated()), id: \.offset) { index, slice in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.donutWarmPalette[index % Self.donutWarmPalette.count])
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(slice.label)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(donutValueText(slice.value, total: total))
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func donutValueText(_ value: Double, total: Double) -> String {
        let formatted = ChartSpecAccessibility.formattedValue(value, format: spec.valueFormat)
        guard total > 0 else { return formatted }
        let pct = Int((value / total * 100).rounded())
        return "\(formatted) · \(pct)%"
    }

    /// Aurora-warm donut palette shared by the sector chart and the
    /// breakdown rows so colors always agree.
    static let donutWarmPalette: [Color] = [
        MobileTheme.ember,
        MobileTheme.whimsy,
        MobileTheme.amber,
        MobileTheme.hermesMercury,
        MobileTheme.blaze,
        MobileTheme.hermesAureate
    ]

    /// Subtle warm wash behind the plot area.
    private var chartBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        MobileTheme.ember.opacity(colorScheme == .dark ? 0.04 : 0.02),
                        MobileTheme.amber.opacity(colorScheme == .dark ? 0.02 : 0.01),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(MobileTheme.Colors.border.opacity(0.15), lineWidth: 0.5)
            )
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

    /// Delegates to the accessibility engine so the plotted interpretation
    /// and the VoiceOver descriptor can never disagree.
    private var xKind: ChartSpecAccessibility.XKind {
        ChartSpecAccessibility.inferredXKind(for: spec)
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

// MARK: - Helpers

private extension Color {
    func gradientFill(topOpacity: Double = 0.35, bottomOpacity: Double = 0.02) -> some ShapeStyle {
        LinearGradient(
            colors: [self.opacity(topOpacity), self.opacity(bottomOpacity)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    func glowShadow(radius: CGFloat = 6) -> some ViewModifier {
        _GlowShadow(color: self, radius: radius)
    }
}

private struct _GlowShadow: ViewModifier {
    let color: Color
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.35), radius: radius, x: 0, y: radius * 0.3)
    }
}

// MARK: - Time-series subviews

private struct TimeLineChart: View {
    let spec: ChartSpec
    let palette: [Color]
    let fillArea: Bool

    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { idx, series in
                let color = palette[idx % palette.count]
                // Non-color encoding: multi-series lines carry a per-series
                // dash pattern (index 0 stays solid) so hue is never the
                // only series signal.
                let dash = spec.series.count > 1
                    ? ChartSpecAccessibility.dashPattern(forSeriesIndex: idx)
                    : []
                ForEach(series.points, id: \.self) { point in
                    let date = point.x.asDate ?? Date()
                    if fillArea {
                        AreaMark(x: .value("Date", date, unit: .day), y: .value("Y", point.y))
                            .foregroundStyle(color.gradientFill(topOpacity: 0.30, bottomOpacity: 0.02))
                            .interpolationMethod(.catmullRom)
                    }
                    LineMark(x: .value("Date", date, unit: .day), y: .value("Y", point.y))
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: dash))
                        .shadow(color: color.opacity(0.25), radius: 5, x: 0, y: 2)
                }
            }
        }
        .chartLegend(.hidden)
        .modifier(StudioChartChrome(xKind: .time))
    }
}

private struct TimeBarChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { idx, series in
                let color = palette[idx % palette.count]
                ForEach(series.points, id: \.self) { point in
                    let date = point.x.asDate ?? Date()
                    BarMark(x: .value("Date", date, unit: .day), y: .value("Y", point.y))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color.opacity(0.85), color.opacity(0.35)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .cornerRadius(5)
                        .shadow(color: color.opacity(0.18), radius: 4, x: 0, y: 2)
                }
            }
        }
        .chartLegend(.hidden)
        .modifier(StudioChartChrome(xKind: .time))
    }
}

private struct TimeStackedAreaChart: View {
    let spec: ChartSpec
    let palette: [Color]
    @State private var selected: Date?
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { idx, series in
                let color = palette[idx % palette.count]
                ForEach(series.points, id: \.self) { point in
                    let date = point.x.asDate ?? Date()
                    AreaMark(
                        x: .value("Date", date, unit: .day),
                        y: .value("Y", point.y),
                        stacking: .standard
                    )
                    .foregroundStyle(color.gradientFill(topOpacity: 0.45, bottomOpacity: 0.06))
                    .interpolationMethod(.catmullRom)

                    // Thin glow line on top for definition
                    LineMark(x: .value("Date", date, unit: .day), y: .value("Y", point.y))
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .shadow(color: color.opacity(0.20), radius: 4, x: 0, y: 1)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $selected)
        .modifier(StudioChartChrome(xKind: .time))
    }
}

private struct TimeScatterChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { idx, series in
                let color = palette[idx % palette.count]
                // Non-color encoding: each series gets a distinct marker
                // shape (circle, square, triangle, …).
                let shape = ChartSpecAccessibility.marker(forSeriesIndex: idx).chartSymbolShape
                ForEach(series.points, id: \.self) { point in
                    let date = point.x.asDate ?? Date()
                    PointMark(x: .value("Date", date, unit: .day), y: .value("Y", point.y))
                        .foregroundStyle(color)
                        .symbol(shape)
                        .symbolSize(90)
                        .shadow(color: color.opacity(0.30), radius: 6, x: 0, y: 2)
                }
            }
        }
        .chartLegend(.hidden)
        .modifier(StudioChartChrome(xKind: .time))
    }
}

// MARK: - Numeric subviews

private struct NumericScatterChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { idx, series in
                let color = palette[idx % palette.count]
                let shape = ChartSpecAccessibility.marker(forSeriesIndex: idx).chartSymbolShape
                ForEach(series.points, id: \.self) { point in
                    let x = point.x.asDouble ?? 0
                    PointMark(x: .value("X", x), y: .value("Y", point.y))
                        .foregroundStyle(color)
                        .symbol(shape)
                        .symbolSize(90)
                        .shadow(color: color.opacity(0.30), radius: 6, x: 0, y: 2)
                }
            }
        }
        .chartLegend(.hidden)
        .modifier(StudioChartChrome(xKind: .auto))
    }
}

private struct NumericBarChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { idx, series in
                let color = palette[idx % palette.count]
                ForEach(series.points, id: \.self) { point in
                    let x = point.x.asDouble ?? 0
                    BarMark(x: .value("X", x), y: .value("Y", point.y))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color.opacity(0.85), color.opacity(0.35)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .cornerRadius(5)
                        .shadow(color: color.opacity(0.18), radius: 4, x: 0, y: 2)
                }
            }
        }
        .chartLegend(.hidden)
        .modifier(StudioChartChrome(xKind: .auto))
    }
}

private struct NumericLineChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { idx, series in
                let color = palette[idx % palette.count]
                let dash = spec.series.count > 1
                    ? ChartSpecAccessibility.dashPattern(forSeriesIndex: idx)
                    : []
                ForEach(series.points, id: \.self) { point in
                    let x = point.x.asDouble ?? 0
                    AreaMark(x: .value("X", x), y: .value("Y", point.y))
                        .foregroundStyle(color.gradientFill(topOpacity: 0.28, bottomOpacity: 0.02))
                        .interpolationMethod(.catmullRom)

                    LineMark(x: .value("X", x), y: .value("Y", point.y))
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: dash))
                        .shadow(color: color.opacity(0.25), radius: 5, x: 0, y: 2)
                }
            }
        }
        .chartLegend(.hidden)
        .modifier(StudioChartChrome(xKind: .auto))
    }
}

// MARK: - Categorical subviews

private struct CategoricalBarChart: View {
    let spec: ChartSpec
    let palette: [Color]
    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { idx, series in
                let color = palette[idx % palette.count]
                ForEach(series.points, id: \.self) { point in
                    BarMark(
                        x: .value("X", point.x.asString ?? "—"),
                        y: .value("Y", point.y)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.85), color.opacity(0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(5)
                    .shadow(color: color.opacity(0.18), radius: 4, x: 0, y: 2)
                }
            }
        }
        .chartLegend(.hidden)
        .modifier(StudioChartChrome(xKind: .auto))
    }
}

private struct CategoricalHeatmapChart: View {
    let spec: ChartSpec
    @Environment(\.colorScheme) private var colorScheme

    private var heatmapPalette: [Color] {
        [
            MobileTheme.ember.opacity(colorScheme == .dark ? 0.12 : 0.06),
            MobileTheme.amber.opacity(colorScheme == .dark ? 0.35 : 0.22),
            MobileTheme.ember.opacity(colorScheme == .dark ? 0.65 : 0.45),
            MobileTheme.blaze.opacity(colorScheme == .dark ? 0.85 : 0.65)
        ]
    }

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
                    .cornerRadius(4)
                }
            }
        }
        .chartForegroundStyleScale(
            domain: spec.series.flatMap { $0.points.map(\.y) }.sorted(),
            range: heatmapPalette
        )
        .chartLegend(.hidden)
        .modifier(StudioChartChrome(xKind: .auto))
    }
}

private struct DonutChart: View {
    let spec: ChartSpec
    let palette: [Color]

    private var sliceLabels: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for series in spec.series {
            for point in series.points {
                let label = point.label ?? point.x.asString ?? series.name
                if seen.insert(label).inserted {
                    ordered.append(label)
                }
            }
        }
        return ordered
    }

    /// Aurora-warm donut palette: ember → whimsy → amber → mercury → blaze → aureate.
    /// Shared with the textual breakdown rows so colors always agree.
    private var donutPalette: [Color] {
        let warm = NativeChartView.donutWarmPalette
        return zip(sliceLabels, 0...).map { _, idx in warm[idx % warm.count] }
    }

    var body: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
                ForEach(series.points, id: \.self) { point in
                    let label = point.label ?? (point.x.asString ?? series.name)
                    let color = donutPalette[sliceLabels.firstIndex(of: label) ?? 0]
                    SectorMark(
                        angle: .value("Value", point.y),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .cornerRadius(4)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.95), color.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
        }
        .chartForegroundStyleScale(domain: sliceLabels, range: donutPalette)
        .chartLegend(.hidden)
        // Soft outer glow around the donut
        .shadow(color: MobileTheme.ember.opacity(0.08), radius: 18, x: 0, y: 6)
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
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .shadow(color: MobileTheme.amber.opacity(0.25), radius: 6, x: 0, y: 0)
                }
            }
        }
        .chartLegend(.hidden)
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
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(MobileTheme.Colors.border.opacity(0.20))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(v.humanReadableNumber())
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                            }
                        }
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
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(MobileTheme.Colors.border.opacity(0.20))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(v.humanReadableNumber())
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                            }
                        }
                    }
                }
                .chartEntrance()
        }
    }
}

// MARK: - Accessibility

extension NativeChartView: @preconcurrency AXChartDescriptorRepresentable {
    /// VoiceOver audio-graph descriptor. The mapping lives in
    /// `ChartSpecAccessibility` so it is unit-testable without a view.
    func makeChartDescriptor() -> AXChartDescriptor {
        ChartSpecAccessibility.makeChartDescriptor(for: spec)
    }
}

extension ChartSpecAccessibility.SeriesMarker {
    /// Swift Charts symbol shape matching this marker — used by scatter
    /// marks and by the legend swatches so they always agree.
    var chartSymbolShape: BasicChartSymbolShape {
        switch self {
        case .circle: return .circle
        case .square: return .square
        case .triangle: return .triangle
        case .diamond: return .diamond
        case .pentagon: return .pentagon
        case .plus: return .plus
        case .asterisk: return .asterisk
        case .cross: return .cross
        }
    }
}

/// Small legend swatch showing a series' line dash pattern.
private struct LegendDashSwatch: View {
    let color: Color
    let dash: [CGFloat]

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 3))
            path.addLine(to: CGPoint(x: 16, y: 3))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
        .frame(width: 16, height: 6)
    }
}
