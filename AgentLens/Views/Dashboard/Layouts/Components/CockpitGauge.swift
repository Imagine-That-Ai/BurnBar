import SwiftUI

// MARK: - Cockpit gauge
//
// A 240° arc gauge with a redline band, a needle-free progress sweep, and the
// value read out in the bowl.
//
// This lives here rather than in the shared component set on purpose: gauges are
// Cockpit's *enforced* distinguishing rule. If another layout wants a gauge, the
// right answer is that it should not have one — a ratio drawn as an arc is an
// operator idiom, and Cockpit is the operator surface (the layout and its home
// shell). The other seven layouts read ratios as numbers, bars, or curves.
//
// Behaviour worth knowing:
//   * `value` is a 0...1 fraction and is clamped, so a >100% budget overrun
//     pins the sweep at full and turns the readout red rather than wrapping.
//   * `redline` marks where the arc turns hot. Above it the sweep takes the
//     warning ramp regardless of the passed accent, because an operator surface
//     should not need the legend to tell you something is wrong.
//   * With Reduce Motion on the sweep snaps instead of animating.

struct CockpitGauge: View {
    let label: String
    /// Formatted value shown in the bowl. Kept as a string so the caller owns
    /// units — a percentage, a dollar figure, and a count all read here.
    let readout: String
    /// 0...1 fraction driving the sweep.
    let value: Double
    /// Fraction above which the gauge reads hot. `nil` disables the redline.
    var redline: Double? = 0.85
    var accent: Color = DesignSystem.Colors.ember
    var caption: String?
    var diameter: CGFloat = 108

    @Environment(\.backdropInk) private var ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The arc spans 240°, centred on the bottom — the standard instrument
    /// sweep, and wide enough that a 5% change is visible.
    private let sweep: Double = 240
    private var startAngle: Double { 90 + (360 - sweep) / 2 }

    private var clamped: Double { max(0, min(1, value)) }
    private var isHot: Bool {
        guard let redline else { return false }
        return clamped >= redline
    }
    private var sweepTint: Color { isHot ? DesignSystem.Colors.warning : accent }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            ZStack {
                track
                progress
                if let redline { redlineTick(at: redline) }
                bowl
            }
            .frame(width: diameter, height: diameter)
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .textCase(.uppercase)
                .tracking(1.1)
                .foregroundStyle(ink.subtle)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(caption.map { "\(readout), \($0)" } ?? readout)
    }

    private var track: some View {
        Circle()
            .trim(from: 0, to: sweep / 360)
            .stroke(ink.hairline, style: StrokeStyle(lineWidth: 9, lineCap: .round))
            .rotationEffect(.degrees(startAngle))
    }

    private var progress: some View {
        Circle()
            .trim(from: 0, to: (sweep / 360) * clamped)
            .stroke(
                AngularGradient(
                    colors: [sweepTint.opacity(0.55), sweepTint],
                    center: .center,
                    startAngle: .degrees(startAngle),
                    endAngle: .degrees(startAngle + sweep)
                ),
                style: StrokeStyle(lineWidth: 9, lineCap: .round)
            )
            .rotationEffect(.degrees(startAngle))
            .shadow(color: sweepTint.opacity(0.45), radius: 6)
            .animation(reduceMotion ? nil : DesignSystem.Animation.gentle, value: clamped)
    }

    private func redlineTick(at fraction: Double) -> some View {
        Circle()
            .trim(from: (sweep / 360) * fraction, to: (sweep / 360) * min(1, fraction + 0.012))
            .stroke(DesignSystem.Colors.error.opacity(0.85), style: StrokeStyle(lineWidth: 12, lineCap: .butt))
            .rotationEffect(.degrees(startAngle))
            .accessibilityHidden(true)
    }

    private var bowl: some View {
        VStack(spacing: 0) {
            Text(readout)
                .font(.system(size: diameter * 0.22, weight: .bold, design: .monospaced))
                .foregroundStyle(isHot ? DesignSystem.Colors.warning : ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : DesignSystem.Animation.gentle, value: readout)
            if let caption {
                Text(caption)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(ink.subtle)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
    }
}

// MARK: - Alarm row
//
// Cockpit's second operator idiom: a state line that is either quiet or loud,
// never decorative. A dashboard that shows a red dot when nothing is wrong
// trains the operator to ignore red dots.

struct CockpitAlarmRow: View {
    enum State {
        case nominal
        case caution
        case alarm

        var tint: Color {
            switch self {
            case .nominal: return DesignSystem.Colors.success
            case .caution: return DesignSystem.Colors.warning
            case .alarm: return DesignSystem.Colors.error
            }
        }

        var symbol: String {
            switch self {
            case .nominal: return "checkmark.circle.fill"
            case .caution: return "exclamationmark.triangle.fill"
            case .alarm: return "exclamationmark.octagon.fill"
            }
        }

        var word: String {
            switch self {
            case .nominal: return "NOMINAL"
            case .caution: return "CAUTION"
            case .alarm: return "ALARM"
            }
        }
    }

    let title: String
    let detail: String
    let state: State

    @Environment(\.backdropInk) private var ink

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: state.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(state.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(ink.subtle)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignSystem.Spacing.sm)
            Text(state.word)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.bold)
                .tracking(1)
                .foregroundStyle(state.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(state.tint.opacity(0.14)))
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(state.word). \(detail)")
    }
}

// MARK: - Alarm panel

/// A stack of alarm rows separated by rules.
///
/// Exists for the same reason as `DashboardRankedTable`: the Cockpit layout and
/// the Cockpit home shell both render this list, and before this they each
/// re-derived `ForEach` + interleaved dividers, which is exactly how two
/// surfaces that are meant to read identically start to drift.
struct CockpitAlarmPanel: View {
    let alarms: [(title: String, detail: String, state: CockpitAlarmRow.State)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(alarms.enumerated()), id: \.offset) { index, alarm in
                if index > 0 { DashboardSectionRule() }
                CockpitAlarmRow(title: alarm.title, detail: alarm.detail, state: alarm.state)
            }
        }
    }
}
