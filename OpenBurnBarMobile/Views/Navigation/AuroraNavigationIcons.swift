import SwiftUI

// MARK: - Aurora Navigation Icons
//
// Five bespoke vector glyphs for the OpenBurnBar floating tab tray. Each
// icon is composed from primitive Path shapes (no SF Symbols) so we have
// full control over selection morph, gradient fills, and animation curves.
//
// Design rules per icon:
//   • A clean, evocative silhouette readable at 22pt and 28pt
//   • A muted at-rest treatment (single neutral stroke / fill)
//   • A rich selected treatment with the destination's accent gradient
//   • A characteristic flourish driven by `animatableData` so the
//     selection spring IS the click animation (no extra timers)
//
// Selection animations per icon:
//   • Pulse:   area under the curve fades in with a 3-stop ember gradient
//   • Burn:    inner hot core grows from the wick and glows
//   • Streams: three aurora ribbons phase-shift along their path
//   • Hermes:  twin wings spread outward and lift; orb radiates
//   • You:     a halo arc expands above the head

// MARK: - Destinations

enum AuroraNavDestination: Hashable, Identifiable, CaseIterable {
    case pulse
    case burn
    case streams
    case hermes
    case you

    var id: String { String(describing: self) }

    var label: String {
        switch self {
        case .pulse:   return "Pulse"
        case .burn:    return "Burn"
        case .streams: return "Streams"
        case .hermes:  return "Hermes"
        case .you:     return "You"
        }
    }

    var accent: Color {
        switch self {
        case .pulse:   return MobileTheme.ember
        case .burn:    return MobileTheme.amber
        case .streams: return MobileTheme.whimsy
        case .hermes:  return MobileTheme.hermesAureate
        case .you:     return MobileTheme.blaze
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .pulse:
            return LinearGradient(
                colors: [MobileTheme.ember, MobileTheme.amber],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .burn:
            return LinearGradient(
                colors: [MobileTheme.amber, MobileTheme.blaze],
                startPoint: .bottom,
                endPoint: .top
            )
        case .streams:
            return LinearGradient(
                colors: [MobileTheme.whimsy, MobileTheme.whimsy.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .hermes:
            return MobileTheme.mercuryGradient
        case .you:
            return LinearGradient(
                colors: [MobileTheme.blaze, MobileTheme.ember],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - 1. Vitalis (Pulse)
// A vitals waveform — one tall peak, then a softer dip. The selected state
// fills the area UNDER the curve down to the baseline with a multi-stop
// ember→amber→clear gradient, evoking a sparkline area chart.

/// The line component of Vitalis — peak then valley.
struct VitalisLineShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let baseline = h * 0.74
        let amplitude = h * 0.50

        var path = Path()
        let p0 = CGPoint(x: w * 0.06, y: baseline)
        let p1 = CGPoint(x: w * 0.26, y: baseline - amplitude * 0.18)
        let peak = CGPoint(x: w * 0.46, y: baseline - amplitude)
        let dip = CGPoint(x: w * 0.66, y: baseline + amplitude * 0.05)
        let p3 = CGPoint(x: w * 0.84, y: baseline - amplitude * 0.30)
        let pEnd = CGPoint(x: w * 0.96, y: baseline - amplitude * 0.10)

        path.move(to: p0)
        path.addCurve(to: p1,
                      control1: CGPoint(x: w * 0.14, y: baseline),
                      control2: CGPoint(x: w * 0.20, y: baseline - amplitude * 0.04))
        path.addCurve(to: peak,
                      control1: CGPoint(x: w * 0.34, y: baseline - amplitude * 0.55),
                      control2: CGPoint(x: w * 0.40, y: baseline - amplitude))
        path.addCurve(to: dip,
                      control1: CGPoint(x: w * 0.52, y: baseline - amplitude),
                      control2: CGPoint(x: w * 0.58, y: baseline + amplitude * 0.05))
        path.addCurve(to: p3,
                      control1: CGPoint(x: w * 0.74, y: baseline + amplitude * 0.05),
                      control2: CGPoint(x: w * 0.78, y: baseline - amplitude * 0.20))
        path.addCurve(to: pEnd,
                      control1: CGPoint(x: w * 0.90, y: baseline - amplitude * 0.04),
                      control2: CGPoint(x: w * 0.94, y: baseline - amplitude * 0.06))
        return path
    }
}

/// Closed area-under-curve down to the baseline.
struct VitalisAreaShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let baseline = rect.height * 0.74
        var path = VitalisLineShape().path(in: rect)
        path.addLine(to: CGPoint(x: w * 0.96, y: baseline))
        path.addLine(to: CGPoint(x: w * 0.06, y: baseline))
        path.closeSubpath()
        return path
    }
}

// MARK: - 2. Ignis (Burn)
// A confident teardrop flame silhouette with a soft inner core that lights
// up and grows on selection. Two layers — outline and core — animated via
// the `progress` driver so the spring transition reads as a flame leap.

/// Outer flame silhouette — base, waist, neck, soft tip.
struct IgnisOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2

        var path = Path()
        let baseY = h * 0.86
        let baseL = CGPoint(x: cx - w * 0.16, y: baseY)
        let baseR = CGPoint(x: cx + w * 0.16, y: baseY)
        let waistL = CGPoint(x: cx - w * 0.30, y: h * 0.56)
        let waistR = CGPoint(x: cx + w * 0.30, y: h * 0.56)
        let neckL = CGPoint(x: cx - w * 0.14, y: h * 0.30)
        let neckR = CGPoint(x: cx + w * 0.14, y: h * 0.30)
        let tip = CGPoint(x: cx + w * 0.02, y: h * 0.08)

        path.move(to: baseL)
        path.addCurve(to: waistL,
                      control1: CGPoint(x: cx - w * 0.10, y: baseY - h * 0.04),
                      control2: CGPoint(x: cx - w * 0.36, y: h * 0.68))
        path.addCurve(to: neckL,
                      control1: CGPoint(x: cx - w * 0.30, y: h * 0.44),
                      control2: CGPoint(x: cx - w * 0.22, y: h * 0.34))
        path.addQuadCurve(to: tip,
                          control: CGPoint(x: cx - w * 0.14, y: h * 0.14))
        path.addQuadCurve(to: neckR,
                          control: CGPoint(x: cx + w * 0.20, y: h * 0.16))
        path.addCurve(to: waistR,
                      control1: CGPoint(x: cx + w * 0.24, y: h * 0.34),
                      control2: CGPoint(x: cx + w * 0.32, y: h * 0.44))
        path.addCurve(to: baseR,
                      control1: CGPoint(x: cx + w * 0.36, y: h * 0.68),
                      control2: CGPoint(x: cx + w * 0.10, y: baseY - h * 0.04))
        path.closeSubpath()
        return path
    }
}

/// Inner hot core — grows from a tiny ember to a full teardrop with progress.
struct IgnisCoreShape: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2
        let scale: CGFloat = 0.72 + progress * 0.32 // 0.72 → 1.04 of nominal core

        let baseY = h * 0.74
        let baseL = CGPoint(x: cx - w * 0.07 * scale, y: baseY)
        let baseR = CGPoint(x: cx + w * 0.07 * scale, y: baseY)
        let waistL = CGPoint(x: cx - w * 0.13 * scale, y: h * 0.55)
        let waistR = CGPoint(x: cx + w * 0.13 * scale, y: h * 0.55)
        let tip = CGPoint(x: cx + w * 0.01, y: h * 0.34)

        var path = Path()
        path.move(to: baseL)
        path.addCurve(to: waistL,
                      control1: CGPoint(x: cx - w * 0.04 * scale, y: baseY - h * 0.04),
                      control2: CGPoint(x: cx - w * 0.16 * scale, y: h * 0.64))
        path.addQuadCurve(to: tip,
                          control: CGPoint(x: cx - w * 0.10 * scale, y: h * 0.42))
        path.addQuadCurve(to: waistR,
                          control: CGPoint(x: cx + w * 0.10 * scale, y: h * 0.42))
        path.addCurve(to: baseR,
                      control1: CGPoint(x: cx + w * 0.16 * scale, y: h * 0.64),
                      control2: CGPoint(x: cx + w * 0.04 * scale, y: baseY - h * 0.04))
        path.closeSubpath()
        return path
    }
}

// MARK: - 3. Streams (Aurora Ribbons)
// Three stacked sine-wave ribbons — like aurora bands of streaming data.
// Phase shifts when selected, so the ribbons appear to flow.

/// One ribbon at row 0 (top), 1 (middle), or 2 (bottom).
/// `phase` is the animation driver: 0 at rest, 1 when selected.
struct StreamsRibbonShape: Shape {
    var rowIndex: Int
    var phase: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        // Vertical band centers — top brightest, bottom faintest
        let yCenter = h * (0.32 + CGFloat(rowIndex) * 0.20)
        let amplitude = h * 0.085
        // Phase shift: each row staggered so motion reads as flow, not sync
        let phaseShift = phase * .pi * 0.85 + CGFloat(rowIndex) * .pi * 0.45

        let xStart = w * 0.08
        let xEnd = w * 0.92

        var path = Path()
        let steps = 28
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = xStart + (xEnd - xStart) * t
            let y = yCenter + sin(t * .pi * 2 + phaseShift) * amplitude
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

/// Combined silhouette of all three ribbons — used for the halo glow only.
struct StreamsGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 0..<3 {
            path.addPath(StreamsRibbonShape(rowIndex: i, phase: 0).path(in: rect))
        }
        return path
    }
}

// MARK: - 4. Hermes (Winged Orb)
// A central messenger orb flanked by twin wings. The wings extend outward
// and lift their tips as `spread` animates from 0 → 1, evoking flight.

/// Central filled circle.
struct HermesOrbShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2
        let cy = h * 0.50
        let r = w * 0.17
        var path = Path()
        path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        return path
    }
}

/// Two symmetric wing leaves flanking the orb.
/// `spread`: 0 = wings tucked in close to the orb, 1 = wings extended.
struct HermesWingsShape: Shape {
    var spread: CGFloat

    var animatableData: CGFloat {
        get { spread }
        set { spread = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2
        let cy = h * 0.50

        // Wing geometry breathes with spread
        let extend: CGFloat = 0.30 + spread * 0.12   // x of wing tip
        let lift: CGFloat   = 0.16 + spread * 0.08   // y rise of wing tip
        let droop: CGFloat  = 0.10                   // y of wing's lower edge

        var path = Path()

        // Left wing — closed leaf
        let leftInner = CGPoint(x: cx - w * 0.12, y: cy - h * 0.02)
        let leftTip   = CGPoint(x: cx - w * extend, y: cy - h * lift)
        let leftOuter = CGPoint(x: cx - w * 0.14, y: cy + h * droop)
        path.move(to: leftInner)
        path.addQuadCurve(to: leftTip,
                          control: CGPoint(x: cx - w * (extend - 0.06), y: cy - h * (lift + 0.06)))
        path.addQuadCurve(to: leftOuter,
                          control: CGPoint(x: cx - w * (extend - 0.04), y: cy + h * 0.02))
        path.addQuadCurve(to: leftInner,
                          control: CGPoint(x: cx - w * 0.10, y: cy + h * 0.02))
        path.closeSubpath()

        // Right wing — mirrored
        let rightInner = CGPoint(x: cx + w * 0.12, y: cy - h * 0.02)
        let rightTip   = CGPoint(x: cx + w * extend, y: cy - h * lift)
        let rightOuter = CGPoint(x: cx + w * 0.14, y: cy + h * droop)
        path.move(to: rightInner)
        path.addQuadCurve(to: rightTip,
                          control: CGPoint(x: cx + w * (extend - 0.06), y: cy - h * (lift + 0.06)))
        path.addQuadCurve(to: rightOuter,
                          control: CGPoint(x: cx + w * (extend - 0.04), y: cy + h * 0.02))
        path.addQuadCurve(to: rightInner,
                          control: CGPoint(x: cx + w * 0.10, y: cy + h * 0.02))
        path.closeSubpath()

        return path
    }
}

/// Combined silhouette (orb + spread wings) for halo glow.
struct HermesGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = HermesOrbShape().path(in: rect)
        path.addPath(HermesWingsShape(spread: 1.0).path(in: rect))
        return path
    }
}

// MARK: - 5. You (Bust + Halo)
// A polished bust silhouette (head + shoulders) topped by a thin halo arc
// that crowns the head when selected. The halo expands outward as `spread`
// rises, like an aurora cresting over the brow.

/// Bust silhouette — single closed shape, no seams between head and shoulders.
struct YouBustShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2

        let headR = w * 0.20
        let headCY = h * 0.36
        let bottomY = h * 0.92
        let leftX = cx - w * 0.40
        let rightX = cx + w * 0.40
        let shoulderTopY = h * 0.72
        let neckHalfW = w * 0.13
        let neckTopY = headCY + headR * 0.92
        let headBottomY = headCY + headR

        var path = Path()
        path.move(to: CGPoint(x: leftX, y: bottomY))
        path.addLine(to: CGPoint(x: leftX, y: shoulderTopY))
        path.addCurve(
            to: CGPoint(x: cx - neckHalfW, y: neckTopY),
            control1: CGPoint(x: cx - w * 0.30, y: shoulderTopY - h * 0.02),
            control2: CGPoint(x: cx - w * 0.18, y: neckTopY + h * 0.02)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - headR * 0.85, y: headBottomY - headR * 0.30),
            control: CGPoint(x: cx - neckHalfW - w * 0.02, y: neckTopY - h * 0.02)
        )
        path.addArc(
            center: CGPoint(x: cx, y: headCY),
            radius: headR,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addQuadCurve(
            to: CGPoint(x: cx + neckHalfW, y: neckTopY),
            control: CGPoint(x: cx + neckHalfW + w * 0.02, y: neckTopY - h * 0.02)
        )
        path.addCurve(
            to: CGPoint(x: rightX, y: shoulderTopY),
            control1: CGPoint(x: cx + w * 0.18, y: neckTopY + h * 0.02),
            control2: CGPoint(x: cx + w * 0.30, y: shoulderTopY - h * 0.02)
        )
        path.addLine(to: CGPoint(x: rightX, y: bottomY))
        path.addLine(to: CGPoint(x: leftX, y: bottomY))
        path.closeSubpath()
        return path
    }
}

/// Halo arc above the head. `spread` 0…1 grows the arc outward from a tight
/// crown to a generous aurora.
struct YouHaloShape: Shape {
    var spread: CGFloat

    var animatableData: CGFloat {
        get { spread }
        set { spread = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2
        let headCY = h * 0.36
        let baseR = w * 0.30
        let r = baseR * (0.78 + spread * 0.40)

        var path = Path()
        // ~140° crown arc, opening downward toward the head
        path.addArc(
            center: CGPoint(x: cx, y: headCY),
            radius: r,
            startAngle: .degrees(200),
            endAngle: .degrees(340),
            clockwise: false
        )
        return path
    }
}

/// Combined silhouette for halo/glow. Just the bust (the halo is so thin
/// it doesn't need to contribute to the soft halo blur).
struct YouGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        YouBustShape().path(in: rect)
    }
}

// MARK: - Animated Icon View

struct AuroraNavIcon: View {
    let destination: AuroraNavDestination
    let size: CGFloat
    let isSelected: Bool
    let isPressed: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Animation driver — 0 at rest, 1 when selected. Drives the
    /// `animatableData` of every shape so the spring on isSelected
    /// becomes the click animation for free.
    private var progress: CGFloat { isSelected ? 1.0 : 0.0 }

    var body: some View {
        ZStack {
            if isSelected {
                iconGlow
                    .blur(radius: size * 0.22)
                    .opacity(0.55)
                    .scaleEffect(1.18)
            }

            iconContent
                .scaleEffect(isPressed ? 0.88 : (isSelected ? 1.06 : 1.0))
                .animation(
                    reduceMotion
                        ? .easeInOut(duration: 0.18)
                        : .spring(response: 0.36, dampingFraction: 0.70),
                    value: isSelected
                )
                .animation(.spring(response: 0.18, dampingFraction: 0.65), value: isPressed)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(destination.label)
        .accessibilityHidden(true)
    }

    // MARK: Glow halo behind the selected icon

    @ViewBuilder
    private var iconGlow: some View {
        switch destination {
        case .pulse:
            VitalisLineShape()
                .stroke(
                    destination.accent.opacity(0.45),
                    style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round, lineJoin: .round)
                )
        case .burn:
            IgnisOutlineShape()
                .fill(destination.accent.opacity(0.45))
        case .streams:
            StreamsGlyphShape()
                .stroke(
                    destination.accent.opacity(0.45),
                    style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round, lineJoin: .round)
                )
        case .hermes:
            HermesGlyphShape()
                .fill(destination.accent.opacity(0.45))
        case .you:
            YouGlyphShape()
                .fill(destination.accent.opacity(0.45))
        }
    }

    // MARK: Per-icon foreground rendering

    @ViewBuilder
    private var iconContent: some View {
        switch destination {
        case .pulse:   pulseIcon
        case .burn:    burnIcon
        case .streams: streamsIcon
        case .hermes:  hermesIcon
        case .you:     youIcon
        }
    }

    // MARK: 1. Pulse — heartbeat curve with a rich gradient area

    private var pulseIcon: some View {
        ZStack {
            // Area-under-curve fades in with a 3-stop ember→amber→clear
            // gradient. The transition combines opacity + a slight bottom-
            // anchored scale so it appears to "fill in" upward.
            if isSelected {
                VitalisAreaShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                MobileTheme.ember.opacity(0.70),
                                MobileTheme.amber.opacity(0.38),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .transition(
                        .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
                    )
            }
            VitalisLineShape()
                .stroke(
                    isSelected
                        ? AnyShapeStyle(destination.gradient)
                        : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.78)),
                    style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round, lineJoin: .round)
                )
        }
    }

    // MARK: 2. Burn — outline flame with a glowing inner core

    private var burnIcon: some View {
        ZStack {
            IgnisOutlineShape()
                .stroke(
                    isSelected
                        ? AnyShapeStyle(destination.gradient)
                        : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.78)),
                    style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round, lineJoin: .round)
                )

            // Inner hot core scales in with progress and lights up.
            IgnisCoreShape(progress: progress)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            MobileTheme.amber,
                            MobileTheme.ember
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(progress)
        }
    }

    // MARK: 3. Streams — three aurora ribbons that phase-shift on select

    private var streamsIcon: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { row in
                StreamsRibbonShape(rowIndex: row, phase: progress)
                    .stroke(
                        isSelected
                            ? AnyShapeStyle(destination.gradient)
                            : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.85)),
                        style: StrokeStyle(
                            lineWidth: size * (row == 0 ? 0.085 : 0.075),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .opacity(rowOpacity(row, selected: isSelected))
            }
        }
    }

    private func rowOpacity(_ row: Int, selected: Bool) -> Double {
        // Top ribbon brightest; subsequent rows ease off so the stack reads
        // as one object with depth instead of three equal lines.
        switch row {
        case 0: return 1.0
        case 1: return selected ? 0.82 : 0.72
        default: return selected ? 0.62 : 0.48
        }
    }

    // MARK: 4. Hermes — orb + wings spreading outward

    private var hermesIcon: some View {
        ZStack {
            // Wings sit behind the orb so the orb visually punches forward.
            HermesWingsShape(spread: progress)
                .fill(
                    isSelected
                        ? AnyShapeStyle(destination.gradient)
                        : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.78))
                )

            HermesOrbShape()
                .fill(
                    isSelected
                        ? AnyShapeStyle(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(0.92),
                                    MobileTheme.hermesAureate
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: size * 0.20
                            )
                        )
                        : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.92))
                )
        }
    }

    // MARK: 5. You — bust silhouette with a halo arc that crowns it

    private var youIcon: some View {
        ZStack {
            // Halo behind the bust. Stroke-only, expands with progress.
            YouHaloShape(spread: progress)
                .stroke(
                    destination.gradient,
                    style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round)
                )
                .opacity(progress)

            YouBustShape()
                .fill(
                    isSelected
                        ? AnyShapeStyle(destination.gradient)
                        : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.78))
                )
        }
    }
}

// MARK: - Preview

#Preview("All Icons") {
    VStack(spacing: 28) {
        ForEach(AuroraNavDestination.allCases) { dest in
            HStack(spacing: 40) {
                VStack {
                    AuroraNavIcon(destination: dest, size: 44, isSelected: false, isPressed: false)
                    Text("Idle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    AuroraNavIcon(destination: dest, size: 44, isSelected: true, isPressed: false)
                    Text("Selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    .padding()
}
