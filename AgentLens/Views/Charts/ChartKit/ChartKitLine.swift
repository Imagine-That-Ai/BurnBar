import SwiftUI

// MARK: - ChartKit · Line / Area
//
// Pure Shape/Path renderers for the Charts page. Same discipline as
// `DashboardLiveCostCurve`: static drawing, no timers, no Canvas — the page
// can stay open all day, so idle render cost matters. Series arrive already
// bucketed (≤ ~62 points), so path construction in `body` is negligible.

/// A smooth monotone line with an optional gradient area fill underneath.
struct ChartKitLine: View {
    let values: [Double]
    var accent: Color = DesignSystem.Colors.ember
    var fillsArea = true
    /// Values from this index onward render as a dashed projection.
    var projectionStartIndex: Int?
    /// Fixed y-domain ceiling; defaults to the series max (with headroom).
    var yMax: Double?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let points = normalizedPoints(in: size)
            if points.count >= 2 {
                let splitIndex = projectionStartIndex.map { min(max(0, $0), points.count - 1) }
                let solidPoints = splitIndex.map { Array(points[...$0]) } ?? points
                let solidPath = ChartKitPathBuilder.monotonePath(solidPoints)

                ZStack {
                    if fillsArea {
                        ChartKitPathBuilder.areaPath(points: solidPoints, height: size.height)
                            .fill(
                                LinearGradient(
                                    colors: [accent.opacity(0.28), accent.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }

                    solidPath.stroke(
                        accent,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )

                    if let splitIndex, splitIndex < points.count - 1 {
                        ChartKitPathBuilder.monotonePath(Array(points[splitIndex...]))
                            .stroke(
                                accent.opacity(0.55),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5])
                            )
                    }

                    if projectionStartIndex == nil, let last = points.last {
                        Circle()
                            .fill(accent)
                            .frame(width: 6, height: 6)
                            .position(last)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2, size.width > 0, size.height > 0 else { return [] }
        let ceiling = max((yMax ?? values.max() ?? 0) * 1.08, 0.0001)
        let stepX = size.width / CGFloat(values.count - 1)
        // Inset the extremes by half the stroke so peaks don't clip.
        let inset: CGFloat = 2
        let drawableHeight = size.height - inset * 2
        return values.enumerated().map { index, value in
            CGPoint(
                x: CGFloat(index) * stepX,
                y: inset + drawableHeight - CGFloat(value / ceiling) * drawableHeight
            )
        }
    }
}

// MARK: - Shared path construction

enum ChartKitPathBuilder {

    /// Monotone cubic interpolation — same curve family the dashboard's live
    /// cost curve uses, so lines across the app share one visual voice.
    static func monotonePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        guard points.count > 2 else {
            path.addLine(to: points[1])
            return path
        }
        let n = points.count
        var tangents = [CGFloat](repeating: 0, count: n)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            let dy = points[i + 1].y - points[i].y
            tangents[i] = dx != 0 ? dy / dx : 0
        }
        tangents[n - 1] = tangents[n - 2]
        for i in 0..<(n - 1) {
            let p0 = points[i]
            let p1 = points[i + 1]
            let dx = (p1.x - p0.x) / 3
            let c1 = CGPoint(x: p0.x + dx, y: p0.y + dx * tangents[i])
            let c2 = CGPoint(x: p1.x - dx, y: p1.y - dx * tangents[i + 1])
            path.addCurve(to: p1, control1: c1, control2: c2)
        }
        return path
    }

    static func areaPath(points: [CGPoint], height: CGFloat) -> Path {
        var area = monotonePath(points)
        if let first = points.first, let last = points.last {
            area.addLine(to: CGPoint(x: last.x, y: height))
            area.addLine(to: CGPoint(x: first.x, y: height))
            area.closeSubpath()
        }
        return area
    }
}
