import SwiftUI

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
        SparkSeed(xJitter: 0.18, phaseOffset: 0.27, color: Color(hex: "FFA800")),
        SparkSeed(xJitter: -0.20, phaseOffset: 0.55, color: Color(hex: "E86100")),
        SparkSeed(xJitter: 0.06, phaseOffset: 0.78, color: Color(hex: "FA5053"))
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
