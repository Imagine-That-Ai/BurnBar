import SwiftUI

// MARK: - Ember Sparkline
//
// Compact area sparkline with brand glow. Uses pure `Canvas` to avoid the
// overhead of Swift Charts in dense compositions (Pulse hero card).

struct EmberSparkline: View {
    let values: [Double]
    var lineWidth: CGFloat = 2.0
    var fillOpacity: Double = 0.32

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let mn = values.min() ?? 0
            let mx = values.max() ?? 1
            let range = max(mx - mn, 0.0001)
            let stepX = size.width / CGFloat(values.count - 1)

            var linePath = Path()
            var areaPath = Path()
            areaPath.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * stepX
                let normalized = (v - mn) / range
                let y = size.height - CGFloat(normalized) * size.height
                let pt = CGPoint(x: x, y: y)
                if i == 0 { linePath.move(to: pt) }
                else { linePath.addLine(to: pt) }
                areaPath.addLine(to: pt)
            }
            areaPath.addLine(to: CGPoint(x: size.width, y: size.height))
            areaPath.closeSubpath()

            ctx.fill(
                areaPath,
                with: .linearGradient(
                    Gradient(colors: [
                        MobileTheme.ember.opacity(fillOpacity),
                        MobileTheme.amber.opacity(fillOpacity * 0.6),
                        MobileTheme.ember.opacity(0.0)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            ctx.stroke(
                linePath,
                with: .linearGradient(
                    Gradient(colors: [
                        MobileTheme.amber,
                        MobileTheme.ember
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                ),
                lineWidth: lineWidth
            )

            // Endpoint glow
            if let last = values.last {
                let normalized = (last - mn) / range
                let endY = size.height - CGFloat(normalized) * size.height
                let endX = size.width
                let endPoint = CGRect(x: endX - 4, y: endY - 4, width: 8, height: 8)
                ctx.fill(Circle().path(in: endPoint), with: .color(MobileTheme.amber))
                ctx.fill(
                    Circle().path(in: endPoint.insetBy(dx: -6, dy: -6)),
                    with: .color(MobileTheme.amber.opacity(0.18))
                )
            }
        }
    }
}
