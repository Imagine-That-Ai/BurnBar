import SwiftUI

// MARK: - ChartKit · Donut
//
// Cost-share ring with a legend. Static drawing only at rest; while the
// pointer is over the ring the hovered segment swells, the center readout
// swaps to that segment, and the legend row lights up. First appearance
// sweeps the ring in (gated by `accessibilityReduceMotion`).

struct ChartKitDonut: View {
    struct Segment: Identifiable {
        let id: String
        let label: String
        let value: Double
        let color: Color
        /// Optional legend mark (e.g. a provider logo); the color dot is drawn
        /// when nil. Additive hook for surfaces that rank brands, not colors.
        var badge: AnyView?

        init(id: String, label: String, value: Double, color: Color, badge: AnyView? = nil) {
            self.id = id
            self.label = label
            self.value = value
            self.color = color
            self.badge = badge
        }
    }

    let segments: [Segment]
    /// Text drawn in the ring's center (usually the leader's share).
    var centerText: String?
    /// Formats the hovered segment's raw value.
    var valueFormatter: (Double) -> String = { $0.formatAsCost() }

    @State private var hoveredID: String?
    @State private var sweep: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let total = segments.reduce(0) { $0 + $1.value }
        HStack(spacing: DesignSystem.Spacing.lg) {
            GeometryReader { proxy in
                let radius = min(proxy.size.width, proxy.size.height) / 2
                ZStack {
                    if total > 0 {
                        ForEach(Array(arcs(total: total).enumerated()), id: \.offset) { _, arc in
                            let selected = hoveredID == nil || hoveredID == arc.id
                            DonutArc(startFraction: arc.start, endFraction: arc.end)
                                .trim(from: 0, to: sweep)
                                .stroke(
                                    arc.color.opacity(selected ? 0.95 : 0.3),
                                    style: StrokeStyle(
                                        lineWidth: hoveredID == arc.id ? 17 : 13,
                                        lineCap: .butt
                                    )
                                )
                        }
                    } else {
                        Circle()
                            .stroke(DesignSystem.Colors.surface.opacity(0.6), lineWidth: 13)
                    }
                    centerReadout(total: total)
                }
                .padding(7)
                .onAppear { drawIn() }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        hoveredID = segmentID(
                            at: location, in: proxy.size, radius: radius, total: total
                        )
                    case .ended:
                        hoveredID = nil
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(segments.prefix(5)) { segment in
                    legendRow(segment, total: total)
                }
            }
        }
    }

    // MARK: Center readout

    private func centerReadout(total: Double) -> some View {
        Group {
            if let hovered = segments.first(where: { $0.id == hoveredID }), total > 0 {
                VStack(spacing: 1) {
                    Text(percentLabel(hovered.value / total))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(hovered.color)
                    Text(valueFormatter(hovered.value))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
                .transition(.opacity)
            } else if let centerText {
                Text(centerText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .transition(.opacity)
            }
        }
        .animation(DesignSystem.Animation.snappy, value: hoveredID)
    }

    // MARK: Legend

    private func legendRow(_ segment: Segment, total: Double) -> some View {
        let active = hoveredID == nil || hoveredID == segment.id
        return HStack(spacing: 6) {
            if let badge = segment.badge {
                badge
                    .frame(width: 12, height: 12)
            } else {
                Circle()
                    .fill(segment.color)
                    .frame(width: 7, height: 7)
            }
            Text(segment.label)
                .font(.system(size: 10.5, weight: active && hoveredID != nil ? .bold : .medium, design: .rounded))
                .foregroundStyle(
                    active ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted.opacity(0.6)
                )
                .lineLimit(1)
            Spacer(minLength: 6)
            if total > 0 {
                Text(percentLabel(segment.value / total))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(
                        active ? DesignSystem.Colors.textMuted : DesignSystem.Colors.textMuted.opacity(0.6)
                    )
            }
        }
        .opacity(min(1, sweep * 2))
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredID = hovering ? segment.id : nil
        }
    }

    // MARK: Hit math

    /// Maps a pointer location to a segment: angle around the ring, gated to
    /// a band around the stroke so hovering the center hole or far outside
    /// the ring selects nothing.
    private func segmentID(at location: CGPoint, in size: CGSize, radius: CGFloat, total: Double) -> String? {
        guard total > 0, radius > 0 else { return nil }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        // The ring is inset by the 7pt padding; allow a generous band.
        let ringRadius = max(radius - 7, 1)
        guard distance >= ringRadius - 18, distance <= ringRadius + 18 else { return nil }

        var degrees = atan2(dy, dx) * 180 / .pi + 90
        if degrees < 0 { degrees += 360 }
        let fraction = degrees / 360

        var cursor = 0.0
        for segment in segments where segment.value > 0 {
            let span = segment.value / total
            if fraction >= cursor && fraction < cursor + span {
                return segment.id
            }
            cursor += span
        }
        return nil
    }

    // MARK: Animation

    private func drawIn() {
        guard sweep == 0 else { return }
        if reduceMotion {
            sweep = 1
        } else {
            withAnimation(.easeOut(duration: 0.8)) {
                sweep = 1
            }
        }
    }

    private struct ArcSpec {
        let id: String
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
            let arc = ArcSpec(
                id: segment.id,
                start: cursor + gap / 2,
                end: cursor + fraction - gap / 2,
                color: segment.color
            )
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
            endAngle: .degrees(max(endFraction, startFraction) * 360 - 90),
            clockwise: false
        )
        return path
    }
}
