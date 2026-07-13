import SwiftUI

// MARK: - ChartKit · Donut
//
// Cost-share ring with a legend. Static drawing only.

struct ChartKitDonut: View {
    struct Segment: Identifiable {
        let id: String
        let label: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    /// Text drawn in the ring's center (usually the leader's share).
    var centerText: String?

    var body: some View {
        let total = segments.reduce(0) { $0 + $1.value }
        HStack(spacing: DesignSystem.Spacing.lg) {
            ZStack {
                if total > 0 {
                    ForEach(Array(arcs(total: total).enumerated()), id: \.offset) { _, arc in
                        DonutArc(startFraction: arc.start, endFraction: arc.end)
                            .stroke(
                                arc.color,
                                style: StrokeStyle(lineWidth: 12, lineCap: .butt)
                            )
                    }
                } else {
                    Circle()
                        .stroke(DesignSystem.Colors.textPrimary.opacity(0.07), lineWidth: 12)
                }
                if let centerText {
                    Text(centerText)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
            }
            .padding(7)
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(segments.prefix(5)) { segment in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: 7, height: 7)
                        Text(segment.label)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if total > 0 {
                            Text(percentLabel(segment.value / total))
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private struct ArcSpec {
        let start: Double
        let end: Double
        let color: Color
    }

    private func arcs(total: Double) -> [ArcSpec] {
        var cursor = 0.0
        return segments.compactMap { segment in
            guard segment.value > 0 else { return nil }
            let fraction = segment.value / total
            // Hairline gap between arcs keeps neighbors distinguishable.
            let gap = min(0.006, fraction * 0.25)
            let arc = ArcSpec(start: cursor + gap / 2, end: cursor + fraction - gap / 2, color: segment.color)
            cursor += fraction
            return arc
        }
    }

    private func percentLabel(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }
}

private struct DonutArc: Shape {
    let startFraction: Double
    let endFraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(startFraction * 360 - 90),
            endAngle: .degrees(endFraction * 360 - 90),
            clockwise: false
        )
        return path
    }
}
