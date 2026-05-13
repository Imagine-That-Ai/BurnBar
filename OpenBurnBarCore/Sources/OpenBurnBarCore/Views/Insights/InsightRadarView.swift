import SwiftUI

public struct InsightRadarView: View {
    public let data: InsightWidgetData.Radar
    public init(data: InsightWidgetData.Radar) { self.data = data }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = (side / 2) - 28
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                gridRings(center: center, radius: radius)
                axisLabels(center: center, radius: radius)
                ForEach(Array(data.series.enumerated()), id: \.offset) { idx, series in
                    let color = InsightFormatting.color(forHex: series.colorHex)
                        ?? InsightFormatting.color(forSeriesID: series.id)
                    polygon(values: series.values, center: center, radius: radius)
                        .fill(color.opacity(0.18))
                    polygon(values: series.values, center: center, radius: radius)
                        .stroke(color, lineWidth: 1.5)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func gridRings(center: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            ForEach(1...4, id: \.self) { ring in
                let r = radius * CGFloat(ring) / 4
                polygonShape(values: Array(repeating: 1.0, count: data.axes.count),
                             center: center, radius: r)
                    .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
            }
        }
    }

    private func axisLabels(center: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            ForEach(Array(data.axes.enumerated()), id: \.offset) { idx, axis in
                let angle = self.angle(for: idx)
                let x = center.x + cos(angle) * (radius + 16)
                let y = center.y + sin(angle) * (radius + 16)
                Text(axis)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .position(x: x, y: y)
            }
        }
    }

    private func polygon(values: [Double], center: CGPoint, radius: CGFloat) -> Path {
        polygonShape(values: values, center: center, radius: radius)
    }

    private func polygonShape(values: [Double], center: CGPoint, radius: CGFloat) -> Path {
        Path { path in
            guard !values.isEmpty else { return }
            for (idx, value) in values.enumerated() {
                let angle = self.angle(for: idx)
                let r = radius * CGFloat(max(0, min(1, value)))
                let p = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                if idx == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }
    }

    private func angle(for index: Int) -> CGFloat {
        let count = max(1, data.axes.count)
        return CGFloat(index) * (2 * .pi / CGFloat(count)) - .pi / 2
    }
}
