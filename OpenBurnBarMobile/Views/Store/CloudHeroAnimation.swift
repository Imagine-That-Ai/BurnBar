import SwiftUI
import OpenBurnBarCore

// MARK: - Cloud Hero Animation
//
// Premium hero composition for the OpenBurnBar Cloud store screen.
// Three orbiting glyphs (cloud, mercury orb, flame) circle a glowing
// brand mark while a `Canvas` paints rising amber/blaze sparks behind
// them. Reduce-motion replaces the orbit + sparks with a static stacked
// composition so the screen never feels "broken" with motion off.
//
// The composition is fully `accessibilityHidden(true)` — VoiceOver users
// hear the hero header text instead.

struct CloudHeroAnimation: View {
    var size: CGFloat = 220

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            haloLayer
            if !reduceMotion {
                animatedSparkLayer
                animatedOrbitLayer
            } else {
                staticOrbitLayer
            }
            brandMark
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Halo

    private var haloLayer: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            UnifiedDesignSystem.Colors.ember.opacity(colorScheme == .dark ? 0.55 : 0.30),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.55
                    )
                )
                .blur(radius: 24)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            UnifiedDesignSystem.Colors.amber.opacity(colorScheme == .dark ? 0.30 : 0.18),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.42
                    )
                )
                .blur(radius: 18)
        }
    }

    // MARK: - Sparks

    private var animatedSparkLayer: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            Canvas { ctx, canvasSize in
                let t = context.date.timeIntervalSinceReferenceDate
                var localCtx = ctx
                Self.drawSparks(into: &localCtx, canvasSize: canvasSize, time: t)
            }
            .opacity(reduceTransparency ? 0.4 : 0.85)
            .blendMode(.plusLighter)
        }
    }

    private static func drawSparks(
        into ctx: inout GraphicsContext,
        canvasSize: CGSize,
        time t: TimeInterval
    ) {
        let sparkCount = 14
        for i in 0..<sparkCount {
            let seed = Double(i) * 0.737
            let phase = (t * 0.32 + seed).truncatingRemainder(dividingBy: 1.0)
            let x = canvasSize.width * (0.18 + ((sin(seed * 7.3) + 1) * 0.32))
            let yStart = canvasSize.height * 0.92
            let yEnd = canvasSize.height * 0.18
            let y = yStart + (yEnd - yStart) * CGFloat(phase)
            let alpha = 1.0 - phase
            let radius: CGFloat = 1.4 + CGFloat(i % 3) * 0.6
            let color: Color
            switch i % 3 {
            case 0: color = UnifiedDesignSystem.Colors.ember
            case 1: color = UnifiedDesignSystem.Colors.amber
            default: color = UnifiedDesignSystem.Colors.blaze
            }
            let rect = CGRect(
                x: x - radius,
                y: y - radius,
                width: radius * 2,
                height: radius * 2
            )
            ctx.opacity = alpha * 0.85
            ctx.fill(
                Path(ellipseIn: rect),
                with: .color(color)
            )
        }
    }

    // MARK: - Orbit

    private var animatedOrbitLayer: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angleA = (t * 0.18).truncatingRemainder(dividingBy: 2 * .pi)
            let angleB = angleA + (2 * .pi / 3)
            let angleC = angleA + (4 * .pi / 3)
            ZStack {
                orbitRing
                orbitGlyph(systemName: "cloud.fill", tint: UnifiedDesignSystem.Colors.ember, angle: angleA)
                orbitGlyph(systemName: "drop.fill", tint: UnifiedDesignSystem.Colors.hermesAureate, angle: angleB, glassy: true)
                orbitGlyph(systemName: "flame.fill", tint: UnifiedDesignSystem.Colors.blaze, angle: angleC)
            }
        }
    }

    private var staticOrbitLayer: some View {
        ZStack {
            orbitRing
            orbitGlyph(systemName: "cloud.fill", tint: UnifiedDesignSystem.Colors.ember, angle: -.pi / 2)
            orbitGlyph(systemName: "drop.fill", tint: UnifiedDesignSystem.Colors.hermesAureate, angle: -.pi / 2 + (2 * .pi / 3), glassy: true)
            orbitGlyph(systemName: "flame.fill", tint: UnifiedDesignSystem.Colors.blaze, angle: -.pi / 2 + (4 * .pi / 3))
        }
    }

    private var orbitRing: some View {
        Circle()
            .strokeBorder(
                AngularGradient(
                    colors: [
                        UnifiedDesignSystem.Colors.ember.opacity(0.55),
                        UnifiedDesignSystem.Colors.amber.opacity(0.45),
                        UnifiedDesignSystem.Colors.hermesAureate.opacity(0.35),
                        UnifiedDesignSystem.Colors.ember.opacity(0.55)
                    ],
                    center: .center
                ),
                lineWidth: 1.2
            )
            .frame(width: size * 0.78, height: size * 0.78)
            .blur(radius: 0.4)
    }

    private func orbitGlyph(
        systemName: String,
        tint: Color,
        angle: Double,
        glassy: Bool = false
    ) -> some View {
        let radius = size * 0.39
        let x = cos(angle) * radius
        let y = sin(angle) * radius
        let glyphSize = size * 0.18
        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Circle().stroke(
                        LinearGradient(
                            colors: [tint.opacity(0.7), tint.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                )
                .shadow(color: tint.opacity(0.45), radius: 10, y: 0)
            Image(systemName: systemName)
                .font(.system(size: glyphSize * 0.5, weight: .bold))
                .foregroundStyle(
                    glassy
                        ? AnyShapeStyle(UnifiedDesignSystem.mercuryGradient)
                        : AnyShapeStyle(tint)
                )
        }
        .frame(width: glyphSize, height: glyphSize)
        .offset(x: x, y: y)
    }

    // MARK: - Brand mark

    private var brandMark: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            UnifiedDesignSystem.Colors.ember,
                            UnifiedDesignSystem.Colors.amber
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 0.34, height: size * 0.34)
                .shadow(color: UnifiedDesignSystem.Colors.ember.opacity(0.55), radius: 16, y: 4)

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.7),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .frame(width: size * 0.34, height: size * 0.34)

            Image(systemName: "cloud.fill")
                .font(.system(size: size * 0.13, weight: .bold))
                .foregroundStyle(.white)
                .offset(y: -size * 0.018)

            Image(systemName: "flame.fill")
                .font(.system(size: size * 0.075, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .offset(y: size * 0.06)
        }
    }
}

#Preview("Animated") {
    ZStack {
        UnifiedDesignSystem.Colors.background.ignoresSafeArea()
        CloudHeroAnimation(size: 240)
    }
}
