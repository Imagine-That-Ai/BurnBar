import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct CostSparklineMediumView: View {
    let snap: BurnBarWidgetSnapshot?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("BurnBar")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                }

                Spacer(minLength: 2)

                Text(snap?.heroTotalCost.formatAsCost() ?? "—")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                HStack(spacing: 4) {
                    Text("\(snap?.heroTotalTokens ?? 0)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("tokens")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if let first = snap?.topProviders.first {
                    Text(first)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
            }
            .frame(width: 130, alignment: .leading)

            Spacer()

            if let points = snap?.dailyPoints, !points.isEmpty {
                TokenSparkline(data: points, color: Color.accentColor)
                    .frame(maxHeight: .infinity)
            } else {
                EmptyState()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetAccentable()
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack {
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 24))
                .foregroundStyle(.secondary.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

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

            Path { path in
                for (i, val) in normalized.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = h - (CGFloat(val) * h)
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            Path { path in
                for (i, val) in normalized.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = h - (CGFloat(val) * h)
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: h))
                        path.addLine(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    if i == normalized.count - 1 {
                        path.addLine(to: CGPoint(x: x, y: h))
                        path.closeSubpath()
                    }
                }
            }
            .fill(color.opacity(0.12))

            if let last = normalized.last {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .position(x: w, y: h - (CGFloat(last) * h))
            }
        }
    }
}

#Preview("Medium", as: .systemMedium, widget: {
    BurnBarWidget()
}, timeline: {
    BurnBarEntry(date: Date(), snapshot: .preview)
})
