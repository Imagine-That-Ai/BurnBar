import SwiftUI
import OpenBurnBarCore

// MARK: - Pace Tick Overlay (linear bar)

/// A 1.5pt vertical tick drawn over a horizontal progress bar at the
/// position corresponding to "where the fill edge *should* be" given the
/// current pace through the window. Quietly tells the user whether they
/// are ahead of or behind ideal pace.
///
/// `fuelGauge`: when true (default), the bar fills from the leading edge
/// with *remaining* (shrinks left as time passes). When false, the bar
/// fills with *used* (grows right as time passes). The tick position is
/// always the ideal fill-edge for the current pace.
struct PaceTickOverlay: View {
    let pace: IdealPace?
    let tint: Color
    var fuelGauge: Bool = true

    var body: some View {
        if let pace {
            GeometryReader { geo in
                let fraction = fuelGauge ? (1 - pace.elapsedFraction) : pace.elapsedFraction
                let x = geo.size.width * fraction
                ZStack(alignment: .leading) {
                    Color.clear
                    // Soft ghost halo — gives the tick presence without
                    // demanding attention.
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.18))
                        .frame(width: 4, height: geo.size.height + 4)
                        .position(x: x, y: geo.size.height / 2)
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.85))
                        .frame(width: 1.5, height: geo.size.height + 2)
                        .position(x: x, y: geo.size.height / 2)
                }
                .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Pace Arc Marker (rings)

/// A small dot drawn on a circular ring at the ideal fill-edge angle for
/// the current pace. Used by `QuotaArcDial` for both outer (weekly) and
/// inner (5h) rings, which fill clockwise from the top with *remaining*.
struct PaceArcMarker: View {
    let pace: IdealPace?
    let tint: Color
    var ringInset: CGFloat = 0
    var lineWidth: CGFloat = 6
    var fuelGauge: Bool = true

    var body: some View {
        if let pace {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let inset = ringInset + lineWidth / 2
                let radius = (side / 2) - inset
                let fraction = fuelGauge ? (1 - pace.elapsedFraction) : pace.elapsedFraction
                // Rings rotate -90° so 0 starts at the top.
                let angle = Angle.degrees(-90 + 360 * fraction)
                let cx = geo.size.width / 2
                let cy = geo.size.height / 2
                let dx = CGFloat(cos(angle.radians))
                let dy = CGFloat(sin(angle.radians))
                Circle()
                    .fill(tint.opacity(0.25))
                    .frame(width: lineWidth + 4, height: lineWidth + 4)
                    .position(x: cx + dx * radius, y: cy + dy * radius)
                Circle()
                    .fill(Color.white)
                    .frame(width: max(lineWidth - 2, 2), height: max(lineWidth - 2, 2))
                    .overlay(
                        Circle().stroke(tint.opacity(0.9), lineWidth: 1)
                    )
                    .position(x: cx + dx * radius, y: cy + dy * radius)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Pace Badge (header pill)

/// Capsule pill summarising over/under pace. Renders nothing when usage
/// is within `PacingMath.onPaceThreshold` of ideal — keeps the UI quiet
/// for the common case.
struct PaceBadge: View {
    let pace: IdealPace?
    var compact: Bool = false

    var body: some View {
        if let pace, pace.severity != .onPace {
            let tint = Self.tint(for: pace.severity)
            Text(pace.humanLabel)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .lineLimit(1)
                .padding(.horizontal, compact ? 6 : 8)
                .padding(.vertical, compact ? 2 : 4)
                .background(tint.opacity(0.10))
                .overlay(
                    Capsule()
                        .stroke(tint.opacity(0.18), lineWidth: 1)
                )
                .clipShape(.capsule)
                .accessibilityLabel(Self.accessibilityLabel(for: pace))
        }
    }

    private static func tint(for severity: PaceSeverity) -> Color {
        switch severity {
        case .onPace:         return DesignSystem.Colors.textMuted
        case .aheadOfBudget:  return DesignSystem.Colors.warning
        case .behindBudget:   return DesignSystem.Colors.success
        }
    }

    private static func accessibilityLabel(for pace: IdealPace) -> String {
        let percent = Int((abs(pace.delta) * 100).rounded())
        switch pace.severity {
        case .onPace:        return "On pace"
        case .aheadOfBudget: return "\(percent) percent ahead of ideal pace — burning fast"
        case .behindBudget:  return "\(percent) percent behind ideal pace — comfortable"
        }
    }
}

#if DEBUG
#Preview("PaceBadge — variants") {
    VStack(alignment: .leading, spacing: 8) {
        PaceBadge(pace: IdealPace(
            windowStart: Date().addingTimeInterval(-3600),
            windowEnd: Date().addingTimeInterval(3600),
            elapsedFraction: 0.5,
            usedFraction: 0.82,
            delta: 0.32,
            severity: .aheadOfBudget,
            humanLabel: "+32% pace"
        ))
        PaceBadge(pace: IdealPace(
            windowStart: Date().addingTimeInterval(-3600),
            windowEnd: Date().addingTimeInterval(3600),
            elapsedFraction: 0.5,
            usedFraction: 0.21,
            delta: -0.29,
            severity: .behindBudget,
            humanLabel: "-29% pace"
        ))
        PaceBadge(pace: IdealPace(
            windowStart: Date().addingTimeInterval(-3600),
            windowEnd: Date().addingTimeInterval(3600),
            elapsedFraction: 0.5,
            usedFraction: 0.51,
            delta: 0.01,
            severity: .onPace,
            humanLabel: "on pace"
        ))
    }
    .padding(16)
    .background(DesignSystem.Colors.background)
}
#endif
