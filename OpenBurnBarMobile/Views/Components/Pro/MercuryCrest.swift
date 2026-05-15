import SwiftUI
import OpenBurnBarCore

// MARK: - Mercury Crest
//
// Pro vocabulary — the medallion. Not a logo, not a record button: an
// engraved foil disk that wants to be **looked at**.
//
// Layers (back to front):
//   1. Obsidian disk + inner bevel shadow → embossed depth
//   2. Guilloché radial sunburst, faintly inscribed in mercury foil
//   3. Outer foil ring with engraved micro-text ("OPENBURNBAR · CLOUD · ✦")
//   4. Aureate hairline bevel separating the ring from the field
//   5. Serif "OBB" monogram in mercury foil with a small flame swash
//   6. Faceted ember cabochon at the center, with an animated specular wink
//   7. Continuous mercury shimmer drifting across the whole disk
//   8. One-shot specular sweep on first appearance
//
// All pure SwiftUI — no SF Symbols, no image assets — so it scales without
// pixel artifacts. Reduces gracefully for `accessibilityReduceMotion`.

struct MercuryCrest: View {
    enum Size {
        case small   // 24pt — nav tray, profile chip
        case medium  // 36pt — list rows, menu-bar footer
        case large   // 48pt — profile hero, locked-feature veil

        var diameter: CGFloat {
            switch self {
            case .small:  return ProTheme.Layout.crestSmall
            case .medium: return ProTheme.Layout.crestMedium
            case .large:  return ProTheme.Layout.crestLarge
            }
        }
    }

    var size: Size = .small
    var shimmer: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: shimmer && !reduceMotion ? 1.0/30.0 : .infinity)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t * 0.30).truncatingRemainder(dividingBy: 1.0)  // 0..1 over ~3.3s
            let winkPhase = (sin(t * 1.6) + 1) / 2  // 0..1 ease

            ZStack {
                obsidianDisk
                guillocheLayer
                outerRing
                innerBevelGlow
                monogram
                gemstone(wink: winkPhase)
                shimmerSweep(phase: phase)
            }
            .frame(width: size.diameter, height: size.diameter)
            .shadow(color: Color.black.opacity(0.45), radius: size.diameter * 0.08, x: 0, y: size.diameter * 0.04)
        }
        .accessibilityHidden(true)
    }

    // MARK: 1 — Obsidian disk with subtle inner shadow

    private var obsidianDisk: some View {
        ZStack {
            Circle().fill(ProTheme.Palette.obsidian)
            // Inner shadow (top-inside) — makes the surface feel concave
            Circle()
                .stroke(Color.black.opacity(0.65), lineWidth: size.diameter * 0.04)
                .blur(radius: size.diameter * 0.035)
                .padding(size.diameter * 0.04)
                .mask(Circle())
            // Bottom highlight bevel — catches "studio light"
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color.clear, ProTheme.Palette.aureate.opacity(0.35)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: size.diameter * 0.03
                )
                .padding(size.diameter * 0.02)
                .mask(Circle())
        }
    }

    // MARK: 2 — Guilloché radial sunburst

    private var guillocheLayer: some View {
        Canvas { ctx, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = canvasSize.width / 2 * 0.78
            let inner = canvasSize.width / 2 * 0.32
            let spokes = 40

            for i in 0..<spokes {
                let angle = Double(i) * (2 * .pi / Double(spokes))
                var path = Path()
                let p1 = CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner)
                let p2 = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                path.move(to: p1)
                path.addLine(to: p2)
                let alpha = 0.04 + 0.05 * (i % 2 == 0 ? 1.0 : 0.0)
                ctx.stroke(
                    path,
                    with: .color(ProTheme.Palette.aureate.opacity(alpha)),
                    lineWidth: 0.4
                )
            }

            // Concentric foil arcs every 12% radius
            for ringIndex in stride(from: 0.40, through: 0.74, by: 0.12) {
                let r = canvasSize.width / 2 * CGFloat(ringIndex)
                let arc = Path { p in
                    p.addArc(center: center, radius: r, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                }
                ctx.stroke(arc, with: .color(ProTheme.Palette.mercury.opacity(0.06)), lineWidth: 0.4)
            }
        }
        .mask(Circle().padding(size.diameter * 0.07))
        .blendMode(.plusLighter)
    }

    // MARK: 3 — Outer foil ring with engraved micro-text

    private var outerRing: some View {
        ZStack {
            // The foil ring itself — gradient stroke, beveled
            Circle()
                .stroke(ProTheme.Palette.aureateStroke, lineWidth: size.diameter * 0.045)

            // Micro-text engraving — visible at medium/large only
            if size.diameter >= ProTheme.Layout.crestMedium {
                CircularMicrocopy(
                    text: "OPENBURNBAR · CLOUD · ✦ ",
                    radius: size.diameter / 2 - size.diameter * 0.045,
                    fontSize: size.diameter * 0.066
                )
            }

            // Inner hairline (separates ring from field)
            Circle()
                .stroke(Color.black.opacity(0.6), lineWidth: 0.5)
                .padding(size.diameter * 0.09)

            // Outer hairline
            Circle()
                .stroke(ProTheme.Palette.aureate.opacity(0.6), lineWidth: 0.5)
        }
    }

    // MARK: 4 — Inner bevel glow (catches light)

    private var innerBevelGlow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        ProTheme.Palette.aureate.opacity(0.10),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.38, y: 0.30),
                    startRadius: 0,
                    endRadius: size.diameter * 0.45
                )
            )
            .padding(size.diameter * 0.10)
            .blendMode(.plusLighter)
    }

    // MARK: 5 — Serif OBB monogram

    @ViewBuilder
    private var monogram: some View {
        if size.diameter >= ProTheme.Layout.crestSmall {
            Text("OBB")
                .font(.system(size: size.diameter * 0.26, weight: .heavy, design: .serif))
                .tracking(-size.diameter * 0.006)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            ProTheme.Palette.mercury,
                            ProTheme.Palette.aureate,
                            ProTheme.Palette.mercury
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.black.opacity(0.55), radius: 0.5, x: 0, y: 0.5)
                .offset(y: -size.diameter * 0.04)
        }
    }

    // MARK: 6 — Faceted gemstone cabochon

    @ViewBuilder
    private func gemstone(wink: Double) -> some View {
        let gemSize = size.diameter * 0.18
        ZStack {
            // The jewel body
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            ProTheme.Palette.emberPop.opacity(0.95),
                            ProTheme.Palette.emberPop.opacity(0.45),
                            Color(red: 0.55, green: 0.10, blue: 0.10)
                        ],
                        center: UnitPoint(x: 0.35, y: 0.30),
                        startRadius: 0.5,
                        endRadius: gemSize * 0.9
                    )
                )
                .frame(width: gemSize, height: gemSize)

            // Outer bezel
            Circle()
                .stroke(ProTheme.Palette.aureateStroke, lineWidth: gemSize * 0.10)
                .frame(width: gemSize, height: gemSize)

            // Inner highlight (specular)
            Circle()
                .fill(Color.white.opacity(0.55 * wink))
                .frame(width: gemSize * 0.30, height: gemSize * 0.30)
                .offset(x: -gemSize * 0.16, y: -gemSize * 0.18)
                .blur(radius: 0.4)

            // Soft outer glow
            Circle()
                .fill(ProTheme.Palette.emberPop.opacity(0.4))
                .frame(width: gemSize * 1.6, height: gemSize * 1.6)
                .blur(radius: gemSize * 0.5)
                .opacity(0.55)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .offset(y: size.diameter * 0.24)
    }

    // MARK: 7 — Continuous shimmer sweep

    @ViewBuilder
    private func shimmerSweep(phase: Double) -> some View {
        if shimmer && !reduceMotion {
            GeometryReader { geo in
                let bandWidth = geo.size.width * 0.45
                let travel = geo.size.width + bandWidth
                let offset = travel * CGFloat(phase) - bandWidth
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: Color.white.opacity(0.14), location: 0.45),
                                .init(color: ProTheme.Palette.aureate.opacity(0.18), location: 0.50),
                                .init(color: Color.white.opacity(0.14), location: 0.55),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: bandWidth)
                    .rotationEffect(.degrees(12))
                    .offset(x: offset)
            }
            .mask(Circle())
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Circular Microcopy
//
// Lays out a repeating string around the inside edge of the outer foil ring.
// Pure SwiftUI — each character is a rotated, individually-placed `Text` at
// the same radial offset. Cheap to render; readable from medium size up.

private struct CircularMicrocopy: View {
    let text: String
    let radius: CGFloat
    let fontSize: CGFloat

    var body: some View {
        let chars = Array(text)
        let stepAngle = 360.0 / Double(chars.count)
        return ZStack {
            ForEach(0..<chars.count, id: \.self) { idx in
                let angle = Double(idx) * stepAngle - 90  // start at top
                Text(String(chars[idx]))
                    .font(.system(size: fontSize, weight: .bold, design: .serif))
                    .foregroundStyle(ProTheme.Palette.obsidian.opacity(0.85))
                    .rotationEffect(.degrees(angle + 90))
                    .offset(y: -radius * 0.94)
                    .rotationEffect(.degrees(angle))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Preview

#Preview("Mercury Crest Sizes") {
    ZStack {
        ProTheme.Palette.obsidian.ignoresSafeArea()
        HStack(spacing: 32) {
            MercuryCrest(size: .small)
            MercuryCrest(size: .medium)
            MercuryCrest(size: .large)
        }
    }
}

#Preview("Mercury Crest (XL)") {
    ZStack {
        ProTheme.Palette.obsidian.ignoresSafeArea()
        MercuryCrest(size: .large)
            .scaleEffect(3)
    }
}
