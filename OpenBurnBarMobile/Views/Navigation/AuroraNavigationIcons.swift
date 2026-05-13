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
    case insights
    case streams
    case hermes
    case you

    var id: String { String(describing: self) }

    var label: String {
        switch self {
        case .pulse:    return "Pulse"
        case .burn:     return "Burn"
        case .insights: return "Insights"
        case .streams:  return "Streams"
        // Plan 2: tab label flips to "Assistants" but the enum case stays
        // `.hermes` so existing route strings, deep links, and persisted
        // selection values keep working.
        case .hermes:   return "Assistants"
        case .you:      return "You"
        }
    }

    var accent: Color {
        switch self {
        case .pulse:    return MobileTheme.ember
        case .burn:     return MobileTheme.amber
        case .insights: return MobileTheme.whimsy
        case .streams:  return MobileTheme.whimsy
        case .hermes:   return MobileTheme.hermesAureate
        case .you:      return MobileTheme.blaze
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
        case .insights:
            return LinearGradient(
                colors: [MobileTheme.whimsy, MobileTheme.ember],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
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

// MARK: - 2. Ignis (Real-Fire Canvas Flame)
//
// A real fire — not a stack of gradient teardrops. We simulate ~28
// luminance particles that spawn at the wick, drift up + inward in a
// cone, expand and cool over their lifetime, and expire near the tip.
// Every particle is stamped twice (a large blurred halo + a sharp inner
// core), all blended `.plusLighter` so overlapping density brightens
// the silhouette into a continuous flame body. Sharper coral sparks
// shoot above the cone and fade.
//
// Off-state: the flame is never dead. A static outlined ember silhouette
// holds a slow coal pulse at the base + occasional drifting embers.
//
// Geometry conventions:
//   • baseY:      tapered base of the flame
//   • waistY:     widest belly
//   • neckY:      narrow neck above the belly
//   • tipY:       sharp upper tip
// Each layer scales the silhouette inward + animates wobble independently.

/// One teardrop flame layer. `tier` (0 outer / 1 mid / 2 core) selects how
/// Legacy teardrop silhouette — kept ONLY because the icon glow halo and
/// off-state outline reference it. The real fire is rendered by
/// `LivingFireCanvas` below.
struct IgnisFlameShape: Shape {
    var tier: Int
    var flicker: CGFloat

    var animatableData: CGFloat {
        get { flicker }
        set { flicker = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2

        // Per-tier scaling — each inner layer is tighter and shorter.
        let scale: CGFloat
        let topYOffset: CGFloat
        switch tier {
        case 0:  scale = 1.00; topYOffset = 0.00
        case 1:  scale = 0.78; topYOffset = 0.06
        default: scale = 0.50; topYOffset = 0.14
        }

        // Wobble: waist shifts left/right + tip leans, slightly off-phase
        // per tier so the layers aren't synchronized.
        let waistShift = sin(flicker * .pi * 2 + CGFloat(tier) * 0.7) * (0.025 * scale)
        let tipShift   = sin(flicker * .pi * 2 + CGFloat(tier) * 1.3 + 0.4) * (0.04 * scale)
        let breathe    = 0.95 + 0.05 * sin(flicker * .pi * 2 + CGFloat(tier) * 0.9)

        let baseY = h * 0.86
        let waistY = h * (0.56 + topYOffset * 0.5)
        let neckY = h * (0.30 + topYOffset)
        let tipY  = h * (0.08 + topYOffset)

        let baseHalfW = w * 0.16 * scale
        let waistHalfW = w * 0.30 * scale * breathe
        let neckHalfW  = w * 0.14 * scale

        let baseL = CGPoint(x: cx - baseHalfW, y: baseY)
        let baseR = CGPoint(x: cx + baseHalfW, y: baseY)
        let waistL = CGPoint(x: cx - waistHalfW + w * waistShift, y: waistY)
        let waistR = CGPoint(x: cx + waistHalfW + w * waistShift, y: waistY)
        let neckL = CGPoint(x: cx - neckHalfW + w * waistShift * 0.6, y: neckY)
        let neckR = CGPoint(x: cx + neckHalfW + w * waistShift * 0.6, y: neckY)
        let tip = CGPoint(x: cx + w * tipShift, y: tipY)

        var path = Path()
        path.move(to: baseL)
        path.addCurve(to: waistL,
                      control1: CGPoint(x: cx - w * 0.10 * scale, y: baseY - h * 0.04),
                      control2: CGPoint(x: cx - w * 0.36 * scale + w * waistShift, y: h * 0.68))
        path.addCurve(to: neckL,
                      control1: CGPoint(x: cx - w * 0.30 * scale + w * waistShift, y: h * 0.44),
                      control2: CGPoint(x: cx - w * 0.22 * scale + w * waistShift * 0.6, y: h * (0.34 + topYOffset)))
        path.addQuadCurve(to: tip,
                          control: CGPoint(x: cx - w * 0.14 * scale + w * tipShift * 0.3,
                                           y: h * (0.14 + topYOffset)))
        path.addQuadCurve(to: neckR,
                          control: CGPoint(x: cx + w * 0.20 * scale + w * tipShift * 0.3,
                                           y: h * (0.16 + topYOffset)))
        path.addCurve(to: waistR,
                      control1: CGPoint(x: cx + w * 0.24 * scale + w * waistShift * 0.6, y: h * (0.34 + topYOffset)),
                      control2: CGPoint(x: cx + w * 0.32 * scale + w * waistShift, y: h * 0.44))
        path.addCurve(to: baseR,
                      control1: CGPoint(x: cx + w * 0.36 * scale + w * waistShift, y: h * 0.68),
                      control2: CGPoint(x: cx + w * 0.10 * scale, y: baseY - h * 0.04))
        path.closeSubpath()
        return path
    }
}

/// Compatibility shim — the icon glow halo continues to reference the
/// outermost flame silhouette by this name.
struct IgnisOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        IgnisFlameShape(tier: 0, flicker: 0).path(in: rect)
    }
}

/// White-hot pilot — a tiny bright bead inside the core that wobbles
/// independently and gives the flame a sun-like center.
struct IgnisPilotShape: Shape {
    var flicker: CGFloat

    var animatableData: CGFloat {
        get { flicker }
        set { flicker = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2
        let cy = h * 0.62 + h * 0.02 * sin(flicker * .pi * 2)
        let r = w * 0.06 * (1.0 + 0.12 * sin(flicker * .pi * 2 + 0.6))
        var path = Path()
        path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        return path
    }
}

/// Wick stripe — a thin charcoal log at the very bottom of the flame.
struct IgnisWickShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2
        let wickW = w * 0.30
        let wickH = h * 0.04
        let wickY = h * 0.86 + h * 0.02
        return Path(roundedRect: CGRect(
            x: cx - wickW / 2,
            y: wickY,
            width: wickW,
            height: wickH
        ), cornerRadius: wickH / 2)
    }
}

/// Six rising ember particles. Each one's position is computed from the
/// `phase` parameter (0…1, looping). Embers drift up + sideways and fade
/// out as they rise.
struct IgnisEmbersView: View {
    var phase: CGFloat
    let size: CGFloat

    private struct Ember: Identifiable {
        let id: Int
        let xJitter: CGFloat   // -1 … 1
        let drift: CGFloat     // sideways drift
        let scale: CGFloat
        let phaseOffset: CGFloat
    }

    private static let embers: [Ember] = [
        Ember(id: 0, xJitter: -0.45, drift:  0.10, scale: 0.7, phaseOffset: 0.00),
        Ember(id: 1, xJitter:  0.30, drift: -0.08, scale: 1.0, phaseOffset: 0.18),
        Ember(id: 2, xJitter: -0.10, drift:  0.04, scale: 0.85, phaseOffset: 0.36),
        Ember(id: 3, xJitter:  0.55, drift:  0.12, scale: 0.7, phaseOffset: 0.54),
        Ember(id: 4, xJitter: -0.25, drift: -0.06, scale: 1.05, phaseOffset: 0.72),
        Ember(id: 5, xJitter:  0.18, drift:  0.16, scale: 0.8, phaseOffset: 0.90)
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let cx = w / 2

            for ember in Self.embers {
                let local = (phase + ember.phaseOffset).truncatingRemainder(dividingBy: 1)
                let normalized = local < 0 ? local + 1 : local
                // Vertical travel: starts near the flame's neck and rises
                // toward the top of the canvas.
                let y = h * (0.30 - normalized * 0.28)
                let x = cx + w * (ember.xJitter * 0.18 + ember.drift * normalized)
                let baseR = w * 0.022 * ember.scale
                let opacity = max(0, 1 - normalized * 1.15)
                let rect = CGRect(
                    x: x - baseR, y: y - baseR,
                    width: baseR * 2, height: baseR * 2
                )
                context.opacity = Double(opacity)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .linearGradient(
                        Gradient(colors: [Color.white, MobileTheme.amber, MobileTheme.ember.opacity(0.0)]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                    )
                )
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .blendMode(.plusLighter)
    }
}

// MARK: - LivingFireCanvas
//
// Real fire: 28 deterministic luminance particles spawned at the wick,
// drifting upward in a cone, expanding and cooling over their lifetime.
// Drawn in a Canvas with `.plusLighter` so overlapping density brightens
// into a continuous flame body.

struct LivingFireCanvas: View {
    let size: CGFloat
    let reduceMotion: Bool

    private struct ParticleSeed {
        let baseSpawn: CGFloat   // 0..1 horizontal jitter at the wick
        let lifeMul: CGFloat     // particle lifetime multiplier
        let phaseOffset: CGFloat // staggers the spawn cycle
        let swayFreq: CGFloat    // horizontal sway frequency
        let swayAmp: CGFloat     // horizontal sway amplitude (relative to width)
        let radiusMul: CGFloat   // base size multiplier
    }

    private static let particles: [ParticleSeed] = (0..<28).map { i in
        // Deterministic pseudo-random — keep the seed stable across
        // re-renders so the flame doesn't flash on layout changes.
        let h = (i &* 2654435761) & 0xFFFF
        let r1 = CGFloat((h >> 1) % 1000) / 1000
        let r2 = CGFloat((h >> 3) % 1000) / 1000
        let r3 = CGFloat((h >> 5) % 1000) / 1000
        let r4 = CGFloat((h >> 7) % 1000) / 1000
        return ParticleSeed(
            baseSpawn: r1 * 2 - 1,                 // -1…1
            lifeMul: 0.85 + r2 * 0.30,             // 0.85…1.15
            phaseOffset: CGFloat(i) / 28.0,
            swayFreq: 1.0 + r3 * 1.2,
            swayAmp: 0.04 + r4 * 0.06,
            radiusMul: 0.8 + r3 * 0.5
        )
    }

    private struct SparkSeed {
        let xJitter: CGFloat
        let phaseOffset: CGFloat
        let color: Color
    }

    private static let sparks: [SparkSeed] = [
        SparkSeed(xJitter: -0.10, phaseOffset: 0.00, color: Color(hex: "FA5053")),
        SparkSeed(xJitter:  0.18, phaseOffset: 0.27, color: Color(hex: "FFA800")),
        SparkSeed(xJitter: -0.20, phaseOffset: 0.55, color: Color(hex: "E86100")),
        SparkSeed(xJitter:  0.06, phaseOffset: 0.78, color: Color(hex: "FA5053"))
    ]

    var body: some View {
        if reduceMotion {
            staticFire
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: false)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                renderFire(time: t)
            }
        }
    }

    private var staticFire: some View {
        renderFire(time: 0.4)
    }

    private func renderFire(time: TimeInterval) -> some View {
        let s = size
        return Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let cx = w / 2
            let baseY = h * 0.86

            // Particles
            for seed in Self.particles {
                // Phase: each particle has a 1.6s life, staggered.
                let life: TimeInterval = 1.6 * Double(seed.lifeMul)
                let local = ((time + Double(seed.phaseOffset) * life)
                    .truncatingRemainder(dividingBy: life)) / life
                let p = CGFloat(local) // 0..1 over the particle's life

                // Vertical: starts at the wick, rises to ~tip
                let y = baseY - h * 0.78 * p
                // Horizontal: spawn jitter + sine sway, narrowed at top (cone)
                let cone = 1.0 - p * 0.55
                let sway = sin((p + seed.phaseOffset) * .pi * 2 * seed.swayFreq) * seed.swayAmp
                let x = cx + (seed.baseSpawn * w * 0.10 + sway * w) * cone

                // Radius: small at base, expand mid-life, fade at top
                let bell = sin(p * .pi)               // 0…1…0
                let r = w * 0.18 * seed.radiusMul * (0.35 + bell * 0.65)

                // Color over life: white-yellow → amber → ember → blaze fade
                let color = colorForFireLife(p)
                let opacity = max(0, (1 - p)) * 0.75

                // Stamp: large blurred halo + sharper inner core
                stamp(context: context,
                      x: x, y: y, radius: r * 1.6,
                      color: color.opacity(opacity * 0.45))
                stamp(context: context,
                      x: x, y: y, radius: r,
                      color: color.opacity(opacity))
            }

            // Sparks
            for seed in Self.sparks {
                let life: TimeInterval = 1.2
                let local = ((time + Double(seed.phaseOffset) * life)
                    .truncatingRemainder(dividingBy: life)) / life
                let p = CGFloat(local)
                let y = h * 0.34 - h * 0.28 * p
                let x = cx + seed.xJitter * w * (1 - p * 0.2)
                let r = w * 0.022 * (1.0 - p * 0.6)
                let opacity = max(0, 1 - p)
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                context.opacity = Double(opacity)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [Color.white, seed.color, seed.color.opacity(0.0)]),
                        center: CGPoint(x: rect.midX, y: rect.midY),
                        startRadius: 0,
                        endRadius: r
                    )
                )
            }
        }
        .frame(width: s, height: s)
        .blendMode(.plusLighter)
    }

    private func stamp(
        context: GraphicsContext,
        x: CGFloat,
        y: CGFloat,
        radius: CGFloat,
        color: Color
    ) {
        let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
        var ctx = context
        ctx.opacity = 1.0
        ctx.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [color, color.opacity(0.0)]),
                center: CGPoint(x: rect.midX, y: rect.midY),
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    /// Particle color mapped to lifetime: brand white-yellow → amber →
    /// ember → blaze. Designed to match the rest of the design system.
    private func colorForFireLife(_ p: CGFloat) -> Color {
        switch p {
        case ..<0.18: return Color.white
        case ..<0.42: return Color(hex: "FFE08C")
        case ..<0.65: return Color(hex: "FFA800")     // amber
        case ..<0.85: return Color(hex: "E86100")     // blaze
        default:      return Color(hex: "FA5053")     // ember
        }
    }
}

// MARK: - DormantEmberFlame
//
// Off-state for the Burn icon. Never feels dead: a calm muted teardrop
// outline + a soft coal pulse at the wick + a single ember that drifts
// up every couple of seconds and fades.

struct DormantEmberFlame: View {
    let size: CGFloat
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            // Outline silhouette
            IgnisFlameShape(tier: 0, flicker: 0)
                .stroke(
                    MobileTheme.Colors.textMuted.opacity(0.85),
                    style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round, lineJoin: .round)
                )

            // Soft inner smolder (warm tint that pulses)
            if reduceMotion {
                IgnisFlameShape(tier: 1, flicker: 0)
                    .fill(MobileTheme.ember.opacity(0.16))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12, paused: false)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let pulse = 0.10 + 0.10 * (0.5 + 0.5 * sin(t * 1.3))
                    IgnisFlameShape(tier: 1, flicker: 0)
                        .fill(MobileTheme.ember.opacity(pulse))
                }
            }

            // Coal glow at the wick — small bright dot that pulses
            if reduceMotion {
                Circle()
                    .fill(MobileTheme.ember.opacity(0.55))
                    .frame(width: size * 0.10, height: size * 0.10)
                    .position(x: size / 2, y: size * 0.84)
                    .blur(radius: size * 0.04)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12, paused: false)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let pulse = 0.45 + 0.30 * (0.5 + 0.5 * sin(t * 1.6))
                    let scale = 0.85 + 0.20 * (0.5 + 0.5 * sin(t * 1.2 + 0.6))
                    Circle()
                        .fill(MobileTheme.ember.opacity(pulse))
                        .frame(width: size * 0.10, height: size * 0.10)
                        .scaleEffect(scale)
                        .position(x: size / 2, y: size * 0.84)
                        .blur(radius: size * 0.04)
                        .blendMode(.plusLighter)
                }
            }

            // Single drifting ember every ~2.4s — the icon never feels dead
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 12, paused: false)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let life: TimeInterval = 2.4
                    let local = (t.truncatingRemainder(dividingBy: life)) / life
                    let p = CGFloat(local)
                    let y = size * (0.84 - 0.50 * p)
                    let x = size / 2 + sin(p * .pi * 1.5) * size * 0.06
                    let r = size * 0.018 * (1.0 - p * 0.4)
                    let opacity = max(0, 1 - p) * 0.85
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.white, MobileTheme.amber, MobileTheme.ember.opacity(0)],
                                center: .center,
                                startRadius: 0,
                                endRadius: r
                            )
                        )
                        .frame(width: r * 2, height: r * 2)
                        .opacity(opacity)
                        .position(x: x, y: y)
                        .blendMode(.plusLighter)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 3. Streams (Vintage Antenna TV)
//
// A boxy retro TV cabinet with two rabbit-ear antennae at the top. When
// selected the screen "powers on": a CRT scanline expands from the center
// outward (vertical → horizontal sweep), and three signal bars resolve
// inside the screen. Tapping an unselected tab plays the power-on; leaving
// the tab fades the screen back to standby.
//
// Geometry frame of reference:
//   • Cabinet:  rounded rect, occupies the lower 64% of the canvas
//   • Screen:   inner rounded rect, ~76% of the cabinet
//   • Antennae: two short diagonal lines + tiny knobs at the top
//   • Foot:     two stubby legs hanging below the cabinet

/// Outer cabinet body of the TV (rounded rectangle).
struct StreamsTVCabinetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cabinetRect = StreamsTVMetrics.cabinet(in: rect)
        return Path(roundedRect: cabinetRect, cornerRadius: rect.width * 0.10)
    }
}

/// Inner screen region — a slightly inset rounded rectangle that takes the
/// brand gradient when powered on.
struct StreamsTVScreenShape: Shape {
    func path(in rect: CGRect) -> Path {
        let screenRect = StreamsTVMetrics.screen(in: rect)
        return Path(roundedRect: screenRect, cornerRadius: rect.width * 0.06)
    }
}

/// Two diagonal rabbit-ear antennae rising from the top of the cabinet.
/// `lift` 0…1 nudges the tips slightly outward and upward when on.
struct StreamsTVAntennaShape: Shape {
    var lift: CGFloat

    var animatableData: CGFloat {
        get { lift }
        set { lift = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let cabinetTop = StreamsTVMetrics.cabinet(in: rect).minY
        let cx = w / 2
        let baseSpread = w * 0.08
        let baseY = cabinetTop + 1
        // Antenna lengths
        let tipDX = w * (0.30 + lift * 0.04)
        let tipDY = w * (0.32 + lift * 0.05)

        var path = Path()
        // Left antenna
        path.move(to: CGPoint(x: cx - baseSpread, y: baseY))
        path.addLine(to: CGPoint(x: cx - baseSpread - tipDX, y: baseY - tipDY))
        // Right antenna
        path.move(to: CGPoint(x: cx + baseSpread, y: baseY))
        path.addLine(to: CGPoint(x: cx + baseSpread + tipDX, y: baseY - tipDY))
        return path
    }
}

/// Two tiny tip-knobs that cap the antennae. Drawn separately because we
/// fill them, not stroke them.
struct StreamsTVAntennaTipsShape: Shape {
    var lift: CGFloat

    var animatableData: CGFloat {
        get { lift }
        set { lift = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let cabinetTop = StreamsTVMetrics.cabinet(in: rect).minY
        let cx = w / 2
        let baseSpread = w * 0.08
        let baseY = cabinetTop + 1
        let tipDX = w * (0.30 + lift * 0.04)
        let tipDY = w * (0.32 + lift * 0.05)
        let r = w * 0.035

        var path = Path()
        path.addEllipse(in: CGRect(
            x: cx - baseSpread - tipDX - r,
            y: baseY - tipDY - r,
            width: r * 2, height: r * 2
        ))
        path.addEllipse(in: CGRect(
            x: cx + baseSpread + tipDX - r,
            y: baseY - tipDY - r,
            width: r * 2, height: r * 2
        ))
        return path
    }
}

/// Two stubby legs that hang below the cabinet — completes the silhouette.
struct StreamsTVFeetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let cabinet = StreamsTVMetrics.cabinet(in: rect)
        let footY = cabinet.maxY
        let footH = w * 0.06
        let footW = w * 0.08
        var path = Path()
        path.addRoundedRect(
            in: CGRect(
                x: cabinet.midX - cabinet.width * 0.30 - footW / 2,
                y: footY,
                width: footW, height: footH
            ),
            cornerSize: CGSize(width: w * 0.018, height: w * 0.018)
        )
        path.addRoundedRect(
            in: CGRect(
                x: cabinet.midX + cabinet.width * 0.30 - footW / 2,
                y: footY,
                width: footW, height: footH
            ),
            cornerSize: CGSize(width: w * 0.018, height: w * 0.018)
        )
        return path
    }
}

/// CRT power-on sweep — a thin bright bar that expands from the screen's
/// center, first as a vertical hairline, then sweeping out horizontally.
/// `progress` 0…1: 0 = invisible, 0.4 = vertical line, 1 = fully open.
struct StreamsTVScanlineShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let screen = StreamsTVMetrics.screen(in: rect)
        // First half: vertical hairline grows in height. Second half: hairline
        // becomes a horizontal sweep that opens to fill the screen.
        let p = max(0, min(1, progress))
        let firstHalf = min(1, p / 0.45)            // 0…1 over progress 0…0.45
        let secondHalf = max(0, (p - 0.45) / 0.55)  // 0…1 over progress 0.45…1

        // The sweep's height grows from 0 → screen.height during firstHalf
        let openH = screen.height * firstHalf
        // The sweep's width grows from a hairline → screen.width during secondHalf
        let minSweepW = screen.height * 0.06
        let openW = minSweepW + (screen.width - minSweepW) * secondHalf

        let sweepRect = CGRect(
            x: screen.midX - openW / 2,
            y: screen.midY - openH / 2,
            width: openW, height: openH
        )
        return Path(roundedRect: sweepRect, cornerRadius: rect.width * 0.018)
    }
}

/// Reserved for future bar-based screen content. The active TV uses
/// `StreamsTVColorBarsShape` instead, but we keep this entry here in case
/// future product flows want a vertical bar-graph-style fallback.
struct StreamsTVSignalBarsShape: Shape {
    var phase: CGFloat
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let screen = StreamsTVMetrics.screen(in: rect)
        let count: CGFloat = 4
        let inset = screen.width * 0.16
        let usable = screen.width - inset * 2
        let gap = usable * 0.08
        let barWidth = (usable - gap * (count - 1)) / count
        let baseY = screen.maxY - screen.height * 0.18
        let maxBarH = screen.height * 0.62
        let baseRatios: [CGFloat] = [0.42, 0.78, 0.55, 0.92]

        var path = Path()
        for i in 0..<Int(count) {
            let cosOffset = cos(phase * .pi * 2 + CGFloat(i) * .pi * 0.55)
            let ratio = max(0.30, min(1.0, baseRatios[i] + cosOffset * 0.10))
            let h = maxBarH * ratio
            let x = screen.minX + inset + (barWidth + gap) * CGFloat(i)
            let r = CGRect(x: x, y: baseY - h, width: barWidth, height: h)
            path.addRoundedRect(
                in: r,
                cornerSize: CGSize(width: rect.width * 0.014, height: rect.width * 0.014)
            )
        }
        return path
    }
}

/// Combined silhouette of TV (cabinet + antennae + feet) — used for halo glow.
struct StreamsGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = StreamsTVCabinetShape().path(in: rect)
        path.addPath(StreamsTVAntennaTipsShape(lift: 0).path(in: rect))
        path.addPath(StreamsTVFeetShape().path(in: rect))
        return path
    }
}

/// Shared cabinet/screen metrics — defined once so all sub-shapes line up
/// pixel-perfectly even when the size changes (28pt sidebar vs 22pt tray).
enum StreamsTVMetrics {
    static func cabinet(in rect: CGRect) -> CGRect {
        let w = rect.width
        let h = rect.height
        let cabinetW = w * 0.84
        let cabinetH = h * 0.56
        let cabinetX = (w - cabinetW) / 2
        let cabinetY = h * 0.30
        return CGRect(x: cabinetX, y: cabinetY, width: cabinetW, height: cabinetH)
    }

    static func screen(in rect: CGRect) -> CGRect {
        let cab = cabinet(in: rect)
        return cab.insetBy(dx: cab.width * 0.10, dy: cab.height * 0.16)
    }
}

/// Color test pattern — a single rectangle the size of the inner screen.
/// We fill it with a multi-stop linear gradient that visually reads as
/// 7 vertical color bars (SMPTE-style).
struct StreamsTVColorBarsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let screen = StreamsTVMetrics.screen(in: rect)
        return Path(screen)
    }
}

/// Glossy specular curve over the screen — sells the convex CRT glass.
struct StreamsTVScreenGlossShape: Shape {
    func path(in rect: CGRect) -> Path {
        let screen = StreamsTVMetrics.screen(in: rect)
        var path = Path()
        // Curved highlight covering the upper-left quadrant of the screen.
        let topLeft = CGPoint(x: screen.minX + screen.width * 0.06, y: screen.minY + screen.height * 0.10)
        let topRight = CGPoint(x: screen.minX + screen.width * 0.92, y: screen.minY + screen.height * 0.16)
        let dipMid = CGPoint(x: screen.midX, y: screen.minY + screen.height * 0.42)
        path.move(to: topLeft)
        path.addQuadCurve(to: topRight,
                          control: CGPoint(x: screen.midX, y: screen.minY + screen.height * 0.02))
        path.addQuadCurve(to: topLeft,
                          control: dipMid)
        path.closeSubpath()
        return path
    }
}

/// The leading edge of the CRT power-on sweep — a thin horizontal line that
/// sits at the top + bottom of the opening rectangle while it expands. We
/// only animate it during the second-half horizontal phase (when the open
/// rect actually has a meaningful width); the vertical hairline phase is
/// covered by the bar growth itself.
struct StreamsTVScanlineEdgeShape: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let screen = StreamsTVMetrics.screen(in: rect)
        let p = max(0, min(1, progress))
        let secondHalf = max(0, (p - 0.45) / 0.55)
        let openH = screen.height * min(1, p / 0.45)
        let minSweepW = screen.height * 0.06
        let openW = minSweepW + (screen.width - minSweepW) * secondHalf

        let topY = screen.midY - openH / 2
        let bottomY = screen.midY + openH / 2
        let leftX = screen.midX - openW / 2
        let rightX = screen.midX + openW / 2

        var path = Path()
        path.move(to: CGPoint(x: leftX, y: topY))
        path.addLine(to: CGPoint(x: rightX, y: topY))
        path.move(to: CGPoint(x: leftX, y: bottomY))
        path.addLine(to: CGPoint(x: rightX, y: bottomY))
        return path
    }
}

// MARK: - 4. Hermes (Friendly Robot Head)
//
// A characterful little robot: rounded helmet head, padded headphones with
// circular earcups, a heart-tipped antenna, two big expressive pupils, a
// gentle smile arc, and rosy cheek dots that brighten when selected. When
// the tab activates, the eyes wake up coral, the cheeks blush, the antenna
// heart pulses, and a tiny "happy curve" appears under each pupil so the
// robot reads as smiling-with-its-eyes.
//
// Geometry frame of reference:
//   • Head:        rounded squircle, slightly squat
//   • Headphones:  band over the top + earcups on each side
//   • Eyes:        two large rounded-rect pupils centered horizontally
//   • Smile arc:   curved arc that widens when selected
//   • Cheeks:      two faint circles flanking the smile
//   • Antenna:     stalk + heart tip rising from the helmet's crown

enum HermesRobotMetrics {
    static func head(in rect: CGRect) -> CGRect {
        let w = rect.width
        let h = rect.height
        let headW = w * 0.66
        let headH = h * 0.56
        let headX = (w - headW) / 2
        let headY = h * 0.30
        return CGRect(x: headX, y: headY, width: headW, height: headH)
    }
}

/// Helmet body — soft rounded squircle.
struct HermesHeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        return Path(roundedRect: head, cornerRadius: head.width * 0.36)
    }
}

/// Two earcup circles flanking the helmet (the headphones' speakers).
struct HermesEarcupsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let cy = head.midY
        let r = head.width * 0.13
        var path = Path()
        path.addEllipse(in: CGRect(
            x: head.minX - r * 0.6, y: cy - r,
            width: r * 2, height: r * 2
        ))
        path.addEllipse(in: CGRect(
            x: head.maxX - r * 1.4, y: cy - r,
            width: r * 2, height: r * 2
        ))
        return path
    }
}

/// Antenna stalk that rises from the crown of the helmet.
struct HermesAntennaShape: Shape {
    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let cx = head.midX
        let baseY = head.minY + 1
        let tipY = max(rect.minY + rect.height * 0.05, baseY - rect.height * 0.20)
        var path = Path()
        path.move(to: CGPoint(x: cx, y: baseY))
        path.addLine(to: CGPoint(x: cx, y: tipY))
        return path
    }
}

/// Heart-shaped tip on the antenna (replaces a plain knob — friendlier).
struct HermesAntennaHeartShape: Shape {
    var pulse: CGFloat
    var animatableData: CGFloat {
        get { pulse }
        set { pulse = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let cx = head.midX
        let tipY = max(rect.minY + rect.height * 0.05, head.minY - rect.height * 0.20)
        let scale = 1.0 + pulse * 0.18
        let w = rect.width * 0.13 * scale
        let h = w * 0.92
        let centerY = tipY - h * 0.45

        // Classic heart constructed from two arcs + a bottom V.
        var path = Path()
        let leftCenter = CGPoint(x: cx - w * 0.25, y: centerY - h * 0.05)
        let rightCenter = CGPoint(x: cx + w * 0.25, y: centerY - h * 0.05)
        let lobeR = w * 0.30

        path.move(to: CGPoint(x: cx, y: centerY))
        path.addArc(
            center: leftCenter, radius: lobeR,
            startAngle: .degrees(0), endAngle: .degrees(180),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: cx, y: centerY + h * 0.55))
        path.addLine(to: CGPoint(x: cx + lobeR * 2, y: centerY))
        path.addArc(
            center: rightCenter, radius: lobeR,
            startAngle: .degrees(0), endAngle: .degrees(180),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

/// Two large pupils (rounded rects, not dots) so the robot reads as having
/// eyes, not just LEDs. `glow` grows them slightly on activation.
struct HermesEyesShape: Shape {
    var glow: CGFloat
    var animatableData: CGFloat {
        get { glow }
        set { glow = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let cy = head.minY + head.height * 0.40
        let xOffset = head.width * 0.20
        let baseW = head.width * 0.18
        let baseH = head.height * 0.20
        let scale = 1.0 + glow * 0.10
        let w = baseW * scale
        let h = baseH * scale
        let r = w * 0.40

        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: head.midX - xOffset - w / 2, y: cy - h / 2, width: w, height: h),
            cornerSize: CGSize(width: r, height: r)
        )
        path.addRoundedRect(
            in: CGRect(x: head.midX + xOffset - w / 2, y: cy - h / 2, width: w, height: h),
            cornerSize: CGSize(width: r, height: r)
        )
        return path
    }
}

/// "Smile lines" — small upturned arcs under each pupil that appear when
/// the eyes wake up so the robot reads as smiling with its eyes.
struct HermesEyeSmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let baseY = head.minY + head.height * 0.52
        let xOffset = head.width * 0.20
        let arcW = head.width * 0.18
        let dip = head.height * 0.04

        var path = Path()
        // Left
        path.move(to: CGPoint(x: head.midX - xOffset - arcW / 2, y: baseY))
        path.addQuadCurve(
            to: CGPoint(x: head.midX - xOffset + arcW / 2, y: baseY),
            control: CGPoint(x: head.midX - xOffset, y: baseY + dip)
        )
        // Right
        path.move(to: CGPoint(x: head.midX + xOffset - arcW / 2, y: baseY))
        path.addQuadCurve(
            to: CGPoint(x: head.midX + xOffset + arcW / 2, y: baseY),
            control: CGPoint(x: head.midX + xOffset, y: baseY + dip)
        )
        return path
    }
}

/// Gentle smile arc — wider when selected (`open` = 1) so the robot grins.
struct HermesSmileShape: Shape {
    var open: CGFloat
    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let cy = head.minY + head.height * 0.74
        let baseW = head.width * 0.34
        let w = baseW * (0.85 + open * 0.30)
        let dip = head.height * (0.06 + open * 0.05)

        var path = Path()
        path.move(to: CGPoint(x: head.midX - w / 2, y: cy))
        path.addQuadCurve(
            to: CGPoint(x: head.midX + w / 2, y: cy),
            control: CGPoint(x: head.midX, y: cy + dip)
        )
        return path
    }
}

/// Two small cheek circles flanking the smile — blush dots.
struct HermesCheeksShape: Shape {
    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let cy = head.minY + head.height * 0.74
        let xOffset = head.width * 0.30
        let r = head.width * 0.05
        var path = Path()
        path.addEllipse(in: CGRect(
            x: head.midX - xOffset - r, y: cy - r,
            width: r * 2, height: r * 2
        ))
        path.addEllipse(in: CGRect(
            x: head.midX + xOffset - r, y: cy - r,
            width: r * 2, height: r * 2
        ))
        return path
    }
}

/// Combined silhouette (head + earcups + heart) for halo glow when on.
struct HermesGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = HermesHeadShape().path(in: rect)
        path.addPath(HermesEarcupsShape().path(in: rect))
        path.addPath(HermesAntennaHeartShape(pulse: 0).path(in: rect))
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
    /// Optional photo URL for the `.you` tab. When provided, renders the
    /// signed-in user's avatar instead of the generic glyph.
    var userPhotoURL: URL? = nil
    /// Display name used to derive initials when no photo is available.
    var userDisplayName: String? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var youHaloRotation: Double = 0

    /// Animation driver — 0 at rest, 1 when selected. Drives the
    /// `animatableData` of every shape so the spring on isSelected
    /// becomes the click animation for free.
    private var progress: CGFloat { isSelected ? 1.0 : 0.0 }

    /// Per-icon idle drivers for icons that benefit from a tiny ambient
    /// motion when selected (TV signal bars, robot eye blink). These are
    /// gated on `isSelected` and `reduceMotion` and use TimelineView so they
    /// don't drive view re-renders elsewhere.

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
        case .insights:
            Circle()
                .fill(destination.accent.opacity(0.45))
        case .streams:
            StreamsGlyphShape()
                .fill(destination.accent.opacity(0.45))
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
        case .pulse:    pulseIcon
        case .burn:     burnIcon
        case .insights: insightsIcon
        case .streams:  streamsIcon
        case .hermes:   hermesIcon
        case .you:      youIcon
        }
    }

    private var insightsIcon: some View {
        Image(systemName: "sparkles.tv.fill")
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(
                isSelected ? destination.gradient : LinearGradient(
                    colors: [Color.secondary, Color.secondary.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    // MARK: 1. Pulse — heartbeat curve with a premium brand-gradient fill

    private var pulseIcon: some View {
        ZStack {
            // Area-under-curve fades in with a rich 4-stop ember→amber gradient
            // and a soft peak highlight. The transition combines opacity, a
            // slight upward scale (anchor: .bottom) so it appears to "fill in"
            // from the baseline, and a clipping mask handled implicitly by
            // the shape itself. A subtle white rim at the very top sells the
            // glassy specular finish.
            if isSelected {
                ZStack {
                    VitalisAreaShape()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: MobileTheme.ember.opacity(0.85), location: 0.00),
                                    .init(color: MobileTheme.ember.opacity(0.55), location: 0.35),
                                    .init(color: MobileTheme.amber.opacity(0.32), location: 0.70),
                                    .init(color: Color.clear,                      location: 1.00)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Specular highlight that hugs the upper rim of the curve
                    // so the area reads as a translucent ribbon, not a wash.
                    VitalisAreaShape()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0.42), location: 0.00),
                                    .init(color: Color.white.opacity(0.00), location: 0.18)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.plusLighter)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
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

    // MARK: 2. Burn — Canvas-driven real fire (lit) + warm dormant ember

    @ViewBuilder
    private var burnIcon: some View {
        if isSelected {
            ZStack {
                // Wick anchors the flame at the base.
                IgnisWickShape()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "3A2A1E"), Color(hex: "1A1410")],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Real fire — Canvas particle simulation.
                LivingFireCanvas(size: size, reduceMotion: reduceMotion)
            }
        } else {
            DormantEmberFlame(size: size, reduceMotion: reduceMotion)
        }
    }

    // MARK: 3. Streams — vintage antenna TV with vibrant RGB color bars

    private var streamsIcon: some View {
        let strokeStyle: AnyShapeStyle = isSelected
            ? AnyShapeStyle(destination.gradient)
            : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.85))
        let bodyStroke = size * 0.075
        let detailStroke = size * 0.06

        return ZStack {
            // Antennae + tip knobs. When selected, antennae wiggle subtly.
            antennaeLayer(strokeStyle: strokeStyle, detailStroke: detailStroke)

            // Cabinet outline
            StreamsTVCabinetShape()
                .stroke(strokeStyle,
                        style: StrokeStyle(lineWidth: bodyStroke, lineCap: .round, lineJoin: .round))

            // Screen background. Off: dim slate. On: navy CRT base for the
            // color bars to layer on top of.
            StreamsTVScreenShape()
                .fill(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [Color(hex: "0B0B1A"), Color(hex: "1A1430")],
                                startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.18))
                )

            // Color test pattern — only on when selected. Reveal-mask is a
            // CRT power-on sweep clipped against the screen.
            if isSelected {
                streamsContent
                    .mask(
                        StreamsTVScanlineShape(progress: progress)
                            .fill(Color.white)
                    )
                    .mask(StreamsTVScreenShape())
            }

            // Bright scanline edge that hugs the sweep while it animates —
            // sells the CRT power-on flash. Fades after the sweep completes.
            StreamsTVScanlineEdgeShape(progress: progress)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.0), Color.white.opacity(0.95), Color.white.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: detailStroke * 0.7)
                )
                .opacity(isSelected ? max(0, 1 - progress) : 0)
                .blendMode(.plusLighter)
                .mask(StreamsTVScreenShape())

            // Specular curve on the screen glass — sells the CRT bulge.
            StreamsTVScreenGlossShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isSelected ? 0.30 : 0.15),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.plusLighter)

            // Feet — same stroke color as cabinet, filled.
            StreamsTVFeetShape()
                .fill(strokeStyle)
        }
    }

    /// Animated screen content while selected — full SMPTE-style color
    /// bars + a scrolling channel-flip flicker. Wrapped in a TimelineView so
    /// the bars dance and the flicker scrolls without re-rendering the
    /// surrounding layout.
    @ViewBuilder
    private var streamsContent: some View {
        if reduceMotion || !isSelected {
            colorBars(phase: 0.5)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: false)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = CGFloat((t.truncatingRemainder(dividingBy: 2.4)) / 2.4)
                ZStack {
                    colorBars(phase: phase)
                    // Channel-flip flicker: a thin horizontal band that
                    // slides downward across the screen every cycle.
                    channelFlicker(phase: phase)
                }
            }
        }
    }

    private func colorBars(phase: CGFloat) -> some View {
        // SMPTE-inspired vertical bars in vivid CRT primaries. Each bar
        // breathes a tiny saturation modulation off-phase so the test
        // pattern feels alive instead of static.
        StreamsTVColorBarsShape()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: streamsColor("E8C46A", phase: phase, offset: 0.00), location: 0.00),
                        .init(color: streamsColor("E8C46A", phase: phase, offset: 0.00), location: 1.0 / 7),
                        .init(color: streamsColor("60D0D0", phase: phase, offset: 0.18), location: 1.0 / 7),
                        .init(color: streamsColor("60D0D0", phase: phase, offset: 0.18), location: 2.0 / 7),
                        .init(color: streamsColor("60D060", phase: phase, offset: 0.32), location: 2.0 / 7),
                        .init(color: streamsColor("60D060", phase: phase, offset: 0.32), location: 3.0 / 7),
                        .init(color: streamsColor("D060C8", phase: phase, offset: 0.46), location: 3.0 / 7),
                        .init(color: streamsColor("D060C8", phase: phase, offset: 0.46), location: 4.0 / 7),
                        .init(color: streamsColor("D85050", phase: phase, offset: 0.60), location: 4.0 / 7),
                        .init(color: streamsColor("D85050", phase: phase, offset: 0.60), location: 5.0 / 7),
                        .init(color: streamsColor("5070D0", phase: phase, offset: 0.74), location: 5.0 / 7),
                        .init(color: streamsColor("5070D0", phase: phase, offset: 0.74), location: 6.0 / 7),
                        .init(color: streamsColor("E0E0E0", phase: phase, offset: 0.88), location: 6.0 / 7),
                        .init(color: streamsColor("E0E0E0", phase: phase, offset: 0.88), location: 1.00)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }

    private func streamsColor(_ hex: String, phase: CGFloat, offset: CGFloat) -> Color {
        // Subtle ±10% lightness modulation per bar, off-phase per offset, so
        // the pattern shimmers without feeling glitchy.
        let pulse = 0.92 + 0.08 * sin((phase + offset) * .pi * 2)
        return Color(hex: hex).opacity(Double(pulse))
    }

    @ViewBuilder
    private func channelFlicker(phase: CGFloat) -> some View {
        GeometryReader { geo in
            let screen = StreamsTVMetrics.screen(in: geo.frame(in: .local))
            let bandH = screen.height * 0.16
            let travel = screen.height + bandH
            let y = screen.minY + (phase * travel) - bandH
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.55),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: screen.width, height: bandH)
                .position(x: screen.midX, y: y + bandH / 2)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func antennaeLayer(strokeStyle: AnyShapeStyle, detailStroke: CGFloat) -> some View {
        if isSelected, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: false)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let wiggle = CGFloat(sin(t * 1.6)) * 0.5 + 0.5
                StreamsTVAntennaShape(lift: wiggle)
                    .stroke(strokeStyle,
                            style: StrokeStyle(lineWidth: detailStroke, lineCap: .round))
                StreamsTVAntennaTipsShape(lift: wiggle)
                    .fill(strokeStyle)
            }
        } else {
            StreamsTVAntennaShape(lift: progress)
                .stroke(strokeStyle,
                        style: StrokeStyle(lineWidth: detailStroke, lineCap: .round))
            StreamsTVAntennaTipsShape(lift: progress)
                .fill(isSelected
                      ? AnyShapeStyle(destination.gradient)
                      : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.85)))
        }
    }

    // MARK: 4. Hermes — friendly detailed robot with headphones + smile

    private var hermesIcon: some View {
        // Outline color tracks selection. Mercury gradient when on, calm
        // muted gray when off. Stroke width is tuned so the icon reads
        // crisp at 22pt (tray) and 28pt (sidebar).
        let outlineStyle: AnyShapeStyle = isSelected
            ? AnyShapeStyle(MobileTheme.mercuryGradient)
            : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.88))
        let bodyStroke = size * 0.07
        let detailStroke = size * 0.05

        return ZStack {
            // Antenna stalk
            HermesAntennaShape()
                .stroke(outlineStyle,
                        style: StrokeStyle(lineWidth: detailStroke, lineCap: .round))

            // Heart antenna tip — pulses when active. Halo behind it so it
            // reads as glowing light when on.
            ZStack {
                if isSelected {
                    HermesAntennaHeartShape(pulse: progress)
                        .fill(MobileTheme.ember.opacity(0.55))
                        .blur(radius: size * 0.06)
                        .scaleEffect(1.5 + progress * 0.3)
                }
                HermesAntennaHeartShape(pulse: progress)
                    .fill(isSelected
                          ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [MobileTheme.ember, MobileTheme.amber],
                                    startPoint: .top,
                                    endPoint: .bottom))
                          : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.78)))
            }

            // Earcups (drawn before head so the head's outline rims them)
            HermesEarcupsShape()
                .fill(isSelected
                      ? AnyShapeStyle(
                          LinearGradient(
                              colors: [
                                  MobileTheme.Colors.surfaceElevated,
                                  MobileTheme.Colors.surface
                              ],
                              startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.16)))
                .overlay(
                    HermesEarcupsShape()
                        .stroke(outlineStyle,
                                style: StrokeStyle(lineWidth: detailStroke, lineCap: .round))
                )

            // Helmet body — sheen fill + outline
            HermesHeadShape()
                .fill(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    MobileTheme.Colors.surfaceElevated.opacity(0.95),
                                    MobileTheme.Colors.surface.opacity(0.70)
                                ],
                                startPoint: .top,
                                endPoint: .bottom))
                        : AnyShapeStyle(MobileTheme.Colors.surfaceElevated.opacity(0.18))
                )
                .overlay(
                    HermesHeadShape()
                        .stroke(outlineStyle,
                                style: StrokeStyle(lineWidth: bodyStroke, lineCap: .round, lineJoin: .round))
                )

            // Cheek blush — visible all the time but brighter when selected.
            HermesCheeksShape()
                .fill(
                    isSelected
                        ? AnyShapeStyle(MobileTheme.ember.opacity(0.55))
                        : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.28))
                )
                .blur(radius: isSelected ? size * 0.018 : 0)

            // Eye halo bloom — only when selected
            if isSelected {
                HermesEyesShape(glow: progress)
                    .fill(MobileTheme.ember.opacity(0.50))
                    .blur(radius: size * 0.08)
                    .scaleEffect(1.5)
            }

            // Eye pupils — coral radial gradient when on, muted when off.
            HermesEyesShape(glow: progress)
                .fill(
                    isSelected
                        ? AnyShapeStyle(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(0.95),
                                    MobileTheme.ember,
                                    MobileTheme.ember.opacity(0.85)
                                ],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: size * 0.13))
                        : AnyShapeStyle(MobileTheme.Colors.textPrimary.opacity(0.78))
                )

            // Eye smile arcs (under the pupils) — appear when active so the
            // robot reads as smiling with its eyes too.
            if isSelected {
                HermesEyeSmileShape()
                    .stroke(MobileTheme.ember.opacity(0.85),
                            style: StrokeStyle(lineWidth: detailStroke * 0.65, lineCap: .round))
                    .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .center)))
            }

            // Smile arc — wider when selected
            HermesSmileShape(open: progress)
                .stroke(outlineStyle,
                        style: StrokeStyle(lineWidth: detailStroke * 0.85, lineCap: .round))
        }
    }

    // MARK: 5. You — actual user avatar with a rotating brand halo

    private var youIcon: some View {
        let avatarDiameter = size * 0.84
        let ringInset: CGFloat = size * 0.06
        let ringDiameter = avatarDiameter + ringInset * 2

        return ZStack {
            // Outer rotating brand halo — rendered only when selected. Uses
            // an angular ember→amber→blaze gradient that spins gently. We
            // animate `youHaloRotation` with a `repeatForever` linear spin
            // started in `.onAppear`, gated by reduceMotion.
            if isSelected {
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [
                                MobileTheme.ember,
                                MobileTheme.amber,
                                MobileTheme.blaze,
                                MobileTheme.ember.opacity(0.0),
                                MobileTheme.ember
                            ],
                            center: .center
                        ),
                        lineWidth: max(1.4, size * 0.06)
                    )
                    .frame(width: ringDiameter, height: ringDiameter)
                    .rotationEffect(.degrees(youHaloRotation))
                    .shadow(color: MobileTheme.ember.opacity(0.5), radius: size * 0.18)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .onAppear { startYouHalo() }
                    .onDisappear { youHaloRotation = 0 }
            } else {
                // Idle: a simple muted ring so the avatar still reads as
                // "you" without competing visual noise.
                Circle()
                    .stroke(
                        MobileTheme.Colors.border.opacity(0.45),
                        lineWidth: max(0.8, size * 0.04)
                    )
                    .frame(width: ringDiameter, height: ringDiameter)
            }

            // Avatar core. Photo if available, gradient + initials otherwise.
            Group {
                if let url = userPhotoURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            initialsAvatar
                        }
                    }
                } else {
                    initialsAvatar
                }
            }
            .frame(width: avatarDiameter, height: avatarDiameter)
            .clipShape(Circle())
            .overlay(
                Circle().stroke(
                    Color.white.opacity(colorScheme == .dark ? 0.22 : 0.55),
                    lineWidth: 0.5
                )
            )
        }
    }

    private var initialsAvatar: some View {
        ZStack {
            Circle().fill(MobileTheme.primaryGradient)
            Text(userInitials)
                .font(.system(size: size * 0.40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
    }

    private var userInitials: String {
        // Build up to two-letter initials from `userDisplayName` (split on
        // whitespace, take first char of first two tokens). Fall back to a
        // single dot when the name is empty so the avatar still reads.
        let trimmed = (userDisplayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "•" }
        let parts = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let chars = parts.compactMap { $0.first }.map { String($0).uppercased() }
        return chars.isEmpty ? String(trimmed.prefix(1)).uppercased() : chars.joined()
    }

    private func startYouHalo() {
        guard !reduceMotion else { return }
        // Continuous slow spin — implicit, no value-driven animation needed.
        withAnimation(.linear(duration: 16).repeatForever(autoreverses: false)) {
            youHaloRotation = 360
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
