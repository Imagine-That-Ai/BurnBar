import SwiftUI

// MARK: - Elder Wand foil (macOS)
//
// The "foil world" motion primitives — a periodic specular sheen and drifting
// iridescent sparks — ported from the membership cards (the iOS-only
// `CloudTierComponents`) into AgentLens, tuned to The Elder Wand's warm ember
// identity rather than a tier palette.
//
// Brand rule: the foil world stays GLASSLESS. `ElderWandFoilBackdrop` is an
// obsidian foil plate (its own dark base + iridescent wash), NOT a Liquid Glass
// surface — it is reserved for the celebratory receipt hero, the one moment the
// fusion-spend feature earns a foil treatment. Everything else (line items,
// quota ring) stays in glass. Both motion layers self-gate on Reduce Motion.

enum ElderWandFoil {
    /// Warm ember-iridescent stops — gold → amber → ember → violet. On-brand for
    /// The Elder Wand (vs the cool aqua of the Pro tier card), mirroring the
    /// website's warm `--holo-grad`.
    static let holoStops: [Color] = [
        Color(hex: "FFD56B"), // gold
        Color(hex: "FF8A3D"), // amber-ember
        Color(hex: "F45B69"), // ember
        Color(hex: "B06BFF")  // whimsy violet
    ]

    static let gradient = LinearGradient(
        colors: holoStops,
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The obsidian base the iridescence floats on, so the foil reads as minted
    /// metal regardless of the sheet backdrop.
    static let obsidian = LinearGradient(
        colors: [Color(hex: "1A1320"), Color(hex: "120D17"), Color(hex: "0C0810")],
        startPoint: .top,
        endPoint: .bottom
    )
}

/// A narrow specular band that sweeps the container on a slow loop; most of each
/// cycle rests off-canvas so it reads as a periodic glint on minted metal.
struct ElderWandFoilSheen: View {
    var tint: Color = .white
    var period: Double = 5.2
    var bandOpacity: Double = 0.30

    @State private var phase: CGFloat = -1.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, tint.opacity(bandOpacity), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.45, height: geo.size.height * 1.8)
            .rotationEffect(.degrees(16))
            .offset(x: phase * geo.size.width, y: -geo.size.height * 0.4)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                phase = 1.6
            }
        }
    }
}

/// Tiny iridescent sparks drifting upward — the living dust around the crest.
/// Canvas at 20 fps; renders nothing under Reduce Motion.
struct ElderWandFoilSparks: View {
    var colors: [Color] = ElderWandFoil.holoStops
    var count: Int = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || colors.isEmpty {
            Color.clear.allowsHitTesting(false)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                Canvas { ctx, size in
                    let t = context.date.timeIntervalSinceReferenceDate
                    for i in 0..<count {
                        let seed = Double(i) * 1.618
                        let phase = (t * 0.16 + seed).truncatingRemainder(dividingBy: 1.0)
                        let drift = sin((t * 0.5) + seed * 7.3) * 0.04
                        let x = size.width * (0.12 + ((sin(seed * 5.7) + 1) * 0.38) + drift)
                        let y = size.height * (0.92 - 0.74 * phase)
                        let radius = 1.0 + 1.0 * CGFloat((sin(seed * 9.1) + 1) / 2)
                        ctx.opacity = (1.0 - phase) * 0.6
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                            with: .color(colors[i % colors.count])
                        )
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The composed obsidian foil plate: dark base + a low iridescent wash + the
/// sheen sweep + drifting sparks, clipped to a rounded rect. Pass content to lay
/// over it (the hero's crest + total). Glassless by design.
struct ElderWandFoilBackdrop<Content: View>: View {
    var cornerRadius: CGFloat = DesignSystem.Radius.lg
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    ElderWandFoil.obsidian
                    // A soft iridescent bloom from the top — the foil's color.
                    ElderWandFoil.gradient
                        .opacity(0.22)
                        .blur(radius: 28)
                        .blendMode(.plusLighter)
                    // A grounded iridescent rim wash.
                    ElderWandFoil.gradient
                        .opacity(0.10)
                    ElderWandFoilSparks()
                    ElderWandFoilSheen(tint: Color(hex: "FFE2A8"), bandOpacity: 0.28)
                }
            }
            .clipShape(shape)
            .overlay {
                // A hairline iridescent edge so the plate reads as minted.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color(hex: "FF8A3D").opacity(0.22), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: Color(hex: "FF6A3D").opacity(0.22), radius: 22, y: 10)
    }
}
