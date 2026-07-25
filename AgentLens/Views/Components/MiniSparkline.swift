import Charts
import SwiftUI

struct MiniSparkline: View {
    let data: [Double]
    var color: Color = DesignSystem.Colors.ember
    var width: CGFloat = 60
    var height: CGFloat = 20
    /// Optional spoken context ("Burn, last 7 days") prepended to the
    /// generated data summary.
    var accessibilityTitle: String?
    /// Optional formatter for spoken values (e.g. currency). Defaults to a
    /// compact number.
    var accessibilityValueFormatter: ((Double) -> String)?

    private var points: [(Int, Double)] {
        Array(data.enumerated())
    }

    var body: some View {
        Chart {
            ForEach(points, id: \.0) { index, value in
                // Area fill is declared first so it draws under the line.
                // Swift Charts paints in declaration order, so the crisp line
                // and the end-point cap must come last to sit on top.
                AreaMark(
                    x: .value("Day", index),
                    y: .value("Cost", value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.22), color.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Day", index),
                    y: .value("Cost", value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
            }
            if let last = points.last {
                PointMark(x: .value("Day", last.0), y: .value("Cost", last.1))
                    .foregroundStyle(color)
                    .symbolSize(12)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        // The sparkline has no axes or labels — without this it is an
        // opaque picture to VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.accessibilitySummary(
                data: data,
                title: accessibilityTitle,
                format: accessibilityValueFormatter
            )
        )
    }

    // MARK: - Accessibility

    /// Spoken summary of the sparkline data: trend direction, endpoints,
    /// and extremes. Pure + static so it is unit-testable.
    static func accessibilitySummary(
        data: [Double],
        title: String? = nil,
        format: ((Double) -> String)? = nil
    ) -> String {
        let prefix = title.map { "\($0): " } ?? ""
        let fmt = format ?? compactNumber
        guard let first = data.first else { return prefix + "no data" }
        guard data.count > 1, let last = data.last else {
            return prefix + "single value \(fmt(first))"
        }
        let direction: String
        if last > first { direction = "up" } else if last < first { direction = "down" } else { direction = "flat" }
        let lo = data.min() ?? last
        let hi = data.max() ?? last
        return prefix + "trending \(direction), from \(fmt(first)) to \(fmt(last)), low \(fmt(lo)), high \(fmt(hi))"
    }

    static func compactNumber(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if magnitude >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if magnitude >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        if value.rounded() == value { return String(format: "%.0f", value) }
        return String(format: "%.2f", value)
    }
}
