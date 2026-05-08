import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct CostSparklineMediumView: View {
    let snap: BurnBarWidgetSnapshot?

    var body: some View {
        HStack(spacing: 0) {
            // Left metric panel
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WidgetDesignSystem.Colors.accentGradient)

                    Text("BurnBar")
                        .font(WidgetDesignSystem.Typography.micro)
                        .foregroundStyle(WidgetDesignSystem.Colors.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.6)

                    Spacer()
                }

                Spacer(minLength: 2)

                Text(snap?.heroTotalCost.formatAsCost() ?? "—")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .widgetAccentable()

                HStack(spacing: 4) {
                    Text(snap?.heroTotalTokens.formatAsTokensRaw() ?? "0")
                        .font(WidgetDesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    Text("tokens")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(WidgetDesignSystem.Colors.textSecondary)
                }

                if let first = snap?.topProviders.first {
                    WidgetProviderPill(name: first, tokens: snap?.topProviderTokens.first)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 140, alignment: .leading)
            .background(WidgetDesignSystem.Colors.headerGradient)

            // Divider
            Rectangle()
                .fill(WidgetDesignSystem.Colors.amber.opacity(0.15))
                .frame(width: 1)

            // Right sparkline panel
            Group {
                if let points = snap?.dailyPoints, !points.isEmpty {
                    TokenSparkline(data: points, color: WidgetDesignSystem.Colors.amber)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                } else {
                    EmptyState()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WidgetDesignSystem.Colors.surfaceLight)
        .widgetAccentable()
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack {
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 22))
                .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Token Sparkline

struct TokenSparkline: View {
    let data: [Double]
    let color: Color

    var normalized: [Double] {
        guard let max = data.max(), max > 0 else { return data.map { _ in 0.5 } }
        return data.map { $0 / max }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let stepX = w / CGFloat(max(normalized.count - 1, 1))
            let safeH = h - 4

            // Grid lines
            VStack(spacing: 0) {
                HStack { Spacer() }
                Spacer()
                Divider().opacity(0.15)
                Spacer()
                Divider().opacity(0.15)
                Spacer()
            }

            // Area fill with soft gradient
            areaPath(width: w, height: safeH, stepX: stepX)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.25), color.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .offset(y: 2)

            // Smooth line
            smoothLinePath(width: w, height: safeH, stepX: stepX)
                .stroke(
                    color.opacity(0.9),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
                .offset(y: 2)

            // Glow on trailing dot
            if let last = normalized.last {
                let lastX = w
                let lastY = safeH - (CGFloat(last) * safeH) + 2

                Circle()
                    .fill(color.opacity(0.25))
                    .frame(width: 14, height: 14)
                    .position(x: lastX, y: lastY)
                    .blur(radius: 5)

                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .position(x: lastX, y: lastY)
            }
        }
    }

    private func areaPath(width: CGFloat, height: CGFloat, stepX: CGFloat) -> Path {
        Path { path in
            guard !normalized.isEmpty else { return }
            for (i, val) in normalized.enumerated() {
                let x = CGFloat(i) * stepX
                let y = height - (CGFloat(val) * height)
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: height))
                    path.addLine(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                if i == normalized.count - 1 {
                    path.addLine(to: CGPoint(x: x, y: height))
                    path.closeSubpath()
                }
            }
        }
    }

    private func smoothLinePath(width: CGFloat, height: CGFloat, stepX: CGFloat) -> Path {
        Path { path in
            guard !normalized.isEmpty else { return }
            let points = normalized.enumerated().map { i, val in
                CGPoint(x: CGFloat(i) * stepX, y: height - (CGFloat(val) * height))
            }

            guard points.count > 1 else {
                if let first = points.first {
                    path.move(to: first)
                }
                return
            }

            path.move(to: points[0])
            for i in 1..<points.count {
                let prev = points[i - 1]
                let curr = points[i]
                let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
                if i == 1 {
                    path.addLine(to: mid)
                } else {
                    path.addQuadCurve(to: mid, control: CGPoint(x: prev.x, y: prev.y))
                }
                if i == points.count - 1 {
                    path.addLine(to: curr)
                }
            }
        }
    }
}

#Preview("Medium", as: .systemMedium, widget: {
    BurnBarWidget()
}, timeline: {
    BurnBarEntry(date: Date(), snapshot: .preview)
})
