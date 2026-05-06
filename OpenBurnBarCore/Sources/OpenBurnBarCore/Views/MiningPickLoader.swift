import SwiftUI

// MARK: - Mining Pick Loader
//
// The canonical OpenBurnBar loading indicator. Replaces every plain
// `ProgressView()` spinner across the iOS, iPadOS, and macOS apps with the
// brand's swinging pickaxe + reactive ore + spark burst animation.
//
// Why a re-implementation instead of the SVG?
// SwiftUI's `Image(<svg>)` flattens the document and never runs CSS
// keyframes. To preserve the original animation (pickaxe swing, ore
// impact, spark burst) we ship two precomposed SVG layers
// (`MiningPickIconPickaxe`, `MiningPickIconOre`) and animate them in
// SwiftUI directly, plus draw the spark burst in a Canvas.
//
// Both apps' asset catalogs include the split SVGs (preserved as vector).
// The loader looks them up by name from `Bundle.main` so it works
// identically on iOS, iPadOS, and macOS.

public struct MiningPickLoader: View {
    public enum Style {
        /// Inline spinner (~20pt). Use for buttons, header refreshes,
        /// status rows.
        case inline
        /// Page-level loader (~56pt). Use for full-screen "loading…" or
        /// modal in-flight states. Optional label below the icon.
        case panel
        /// Hero loader (~96pt). Use for prominent first-run / onboarding
        /// "we're working on it" moments.
        case hero
    }

    public let style: Style
    public let label: String?
    public let tint: Color?

    public init(_ style: Style = .panel, label: String? = nil, tint: Color? = nil) {
        self.style = style
        self.label = label
        self.tint = tint
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGFloat {
        switch style {
        case .inline: return 20
        case .panel:  return 56
        case .hero:   return 96
        }
    }

    private var labelFont: Font {
        switch style {
        case .inline: return .system(size: 11, weight: .medium, design: .rounded)
        case .panel:  return .system(size: 13, weight: .medium, design: .rounded)
        case .hero:   return .system(size: 16, weight: .semibold, design: .rounded)
        }
    }

    public var body: some View {
        VStack(spacing: spacing) {
            iconStack
            if let label, !label.isEmpty {
                Text(label)
                    .font(labelFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label ?? "Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var spacing: CGFloat {
        switch style {
        case .inline: return 4
        case .panel:  return 10
        case .hero:   return 14
        }
    }

    @ViewBuilder
    private var iconStack: some View {
        if reduceMotion {
            // Static frame — keeps the brand visual without motion.
            ZStack {
                Image("MiningPickIconOre")
                    .resizable()
                    .scaledToFit()
                Image("MiningPickIconPickaxe")
                    .resizable()
                    .scaledToFit()
                    .rotationEffect(.degrees(-20),
                                    anchor: UnitPoint(x: 0.08, y: 0.72))
            }
            .frame(width: size, height: size)
            .opacity(0.92)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: false)) { context in
                let p = phase(at: context.date)
                let swing = pickaxeSwing(p)
                let impact = oreImpactScale(p)
                let translate = oreImpactTranslate(p)
                let sparkAlpha = sparkAlpha(p)

                ZStack {
                    Image("MiningPickIconOre")
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(impact, anchor: UnitPoint(x: 0.72, y: 0.60))
                        .offset(x: translate.x, y: translate.y)

                    Image("MiningPickIconPickaxe")
                        .resizable()
                        .scaledToFit()
                        .rotationEffect(.degrees(swing),
                                        anchor: UnitPoint(x: 0.08, y: 0.72))

                    if sparkAlpha > 0 {
                        SparkBurstCanvas(progress: sparkAlpha, size: size)
                    }
                }
                .frame(width: size, height: size)
            }
            .frame(width: size, height: size)
        }
    }

    // MARK: - Animation curves
    //
    // The original SVG uses a 2s loop with three independent keyframe
    // tracks (pickaxe swing, ore impact, spark burst). We reproduce them
    // here as deterministic functions of `phase ∈ [0, 1)` so a single
    // TimelineView drives all three layers in sync.

    private func phase(at date: Date) -> Double {
        let period: TimeInterval = 2.0
        let t = date.timeIntervalSinceReferenceDate
        return (t.truncatingRemainder(dividingBy: period)) / period
    }

    /// Pickaxe rotation (degrees). Matches the SVG keyframes:
    ///   0%   -20°
    ///   30%   35°
    ///   35%   30°  (recoil)
    ///   40%   35°  (settle)
    ///   60%  -20°
    ///   100% -20°
    private func pickaxeSwing(_ p: Double) -> Double {
        switch p {
        case ..<0.30:
            // Wind-up: -20° → 35° with ease-in-out
            return interpolate(from: -20, to: 35, t: ease(p / 0.30))
        case ..<0.35:
            return interpolate(from: 35, to: 30, t: (p - 0.30) / 0.05)
        case ..<0.40:
            return interpolate(from: 30, to: 35, t: (p - 0.35) / 0.05)
        case ..<0.60:
            // Recovery: 35° → -20° with ease-in-out
            return interpolate(from: 35, to: -20, t: ease((p - 0.40) / 0.20))
        default:
            return -20
        }
    }

    /// Ore reactive scale — small impact bump centered around p=0.30…0.40.
    private func oreImpactScale(_ p: Double) -> Double {
        switch p {
        case ..<0.29: return 1.0
        case ..<0.30: return interpolate(from: 1.0, to: 1.05, t: (p - 0.29) / 0.01)
        case ..<0.35: return interpolate(from: 1.05, to: 0.98, t: (p - 0.30) / 0.05)
        case ..<0.40: return interpolate(from: 0.98, to: 1.0, t: (p - 0.35) / 0.05)
        default: return 1.0
        }
    }

    /// Ore reactive translate — tiny shake at impact.
    private func oreImpactTranslate(_ p: Double) -> CGPoint {
        let off: CGFloat = size / 250.0
        switch p {
        case ..<0.30: return .zero
        case ..<0.35:
            let t = (p - 0.30) / 0.05
            return CGPoint(x: 5 * off * (1 - t), y: 2 * off * (1 - t))
        case ..<0.40:
            let t = (p - 0.35) / 0.05
            return CGPoint(x: -1 * off * (1 - t), y: -1 * off * (1 - t))
        default:
            return .zero
        }
    }

    /// Spark burst lifetime — 1.0 at impact (p≈0.30), fading to 0 by p≈0.50.
    private func sparkAlpha(_ p: Double) -> Double {
        guard p >= 0.30, p <= 0.50 else { return 0 }
        let local = (p - 0.30) / 0.20
        return 1 - local
    }

    // MARK: - Math helpers

    private func interpolate(from a: Double, to b: Double, t: Double) -> Double {
        let clamped = max(0, min(1, t))
        return a + (b - a) * clamped
    }

    private func ease(_ t: Double) -> Double {
        // Cubic ease-in-out, matches CSS `ease-in-out` closely enough for
        // a 2s loop.
        let clamped = max(0, min(1, t))
        return clamped < 0.5
            ? 4 * clamped * clamped * clamped
            : 1 - pow(-2 * clamped + 2, 3) / 2
    }
}

// MARK: - Spark burst canvas
//
// 8 spark particles in 4 brand color families: ember (coral), amber
// (gold), blaze (orange), whimsy (purple). Each particle drifts outward
// from the impact point at a unique angle + distance. We use Canvas so a
// single render pass draws all 8 particles without spawning views.

private struct SparkBurstCanvas: View {
    let progress: Double  // 1.0 at impact, 0 at end of life
    let size: CGFloat

    private struct Spark {
        let dx: CGFloat
        let dy: CGFloat
        let radius: CGFloat
        let color: Color
    }

    private static let sparks: [Spark] = [
        // Coral / ember (top-left & top-right launches)
        Spark(dx: -0.30, dy: -0.34, radius: 5.0, color: Color(red: 0.957, green: 0.357, blue: 0.412)),
        Spark(dx: -0.16, dy: -0.42, radius: 7.0, color: Color(red: 0.980, green: 0.314, blue: 0.325)),
        // Amber / gold
        Spark(dx: -0.04, dy: -0.46, radius: 6.0, color: Color(red: 0.831, green: 0.565, blue: 0.000)),
        Spark(dx:  0.16, dy: -0.38, radius: 8.0, color: Color(red: 1.000, green: 0.659, blue: 0.000)),
        // Blaze / orange
        Spark(dx: -0.38, dy: -0.20, radius: 5.0, color: Color(red: 0.831, green: 0.345, blue: 0.000)),
        Spark(dx: -0.46, dy: -0.08, radius: 6.0, color: Color(red: 0.910, green: 0.380, blue: 0.000)),
        // Whimsy / purple
        Spark(dx: -0.24, dy: -0.50, radius: 5.0, color: Color(red: 0.416, green: 0.353, blue: 0.804)),
        Spark(dx:  0.08, dy: -0.30, radius: 7.0, color: Color(red: 0.545, green: 0.498, blue: 0.910))
    ]

    var body: some View {
        Canvas { context, canvasSize in
            // Impact point — derived from the SVG's spark transform-origin
            // (175, 130) of a 250x250 canvas.
            let cx = canvasSize.width * (175.0 / 250.0)
            let cy = canvasSize.height * (130.0 / 250.0)
            // Each spark grows out fast, then collapses as it travels.
            // `scale` tracks the SVG's keyframe: jumps to 1.5–2.5x at
            // impact (progress=1), shrinks to 0 as progress→0.
            for spark in Self.sparks {
                let life = max(0, min(1, progress))
                let drift = (1 - life)
                let x = cx + spark.dx * canvasSize.width * drift
                let y = cy + spark.dy * canvasSize.height * drift
                let scale = 0.4 + life * 1.6
                let r = spark.radius * scale * (canvasSize.width / 250.0)
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)

                context.opacity = life
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color.white.opacity(0.92),
                            spark.color,
                            spark.color.opacity(0.0)
                        ]),
                        center: CGPoint(x: rect.midX, y: rect.midY),
                        startRadius: 0,
                        endRadius: r
                    )
                )
            }
        }
        .frame(width: size, height: size)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

// MARK: - Convenience adapters

public extension MiningPickLoader {
    /// Inline-style loader that mirrors the look of `ProgressView()` —
    /// drop-in replacement for a small "loading…" indicator.
    static var inline: MiningPickLoader { MiningPickLoader(.inline) }
}

#if DEBUG
#Preview("Loader styles") {
    VStack(spacing: 36) {
        MiningPickLoader(.inline)
        MiningPickLoader(.panel, label: "Loading…")
        MiningPickLoader(.hero, label: "Crunching usage…")
    }
    .padding(40)
}
#endif
