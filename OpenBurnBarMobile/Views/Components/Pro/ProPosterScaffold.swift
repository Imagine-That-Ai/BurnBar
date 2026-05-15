import SwiftUI
import OpenBurnBarCore

// MARK: - Pro Poster Scaffold
//
// Pro vocabulary — the cinematic stage. Obsidian base + darkened aurora
// ribbon descending from the top + subtle film grain. Wraps any content
// so it sits in the Pro world rather than the utilitarian shell.

struct ProPosterScaffold<Content: View>: View {
    var includeGrain: Bool = true
    var includeRibbon: Bool = true
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle()
                .fill(ProTheme.Palette.obsidian)
                .ignoresSafeArea()

            if includeRibbon {
                Rectangle()
                    .fill(ProTheme.Palette.darkAuroraRibbon)
                    .frame(maxWidth: .infinity)
                    .frame(height: 360)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }

            // Soft upper-center halo to anchor the eye.
            RadialGradient(
                colors: [
                    ProTheme.Palette.aureate.opacity(0.14),
                    Color.clear
                ],
                center: UnitPoint(x: 0.5, y: 0.18),
                startRadius: 0,
                endRadius: 320
            )
            .blendMode(.plusLighter)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if includeGrain {
                GrainOverlay()
                    .opacity(0.06)
                    .blendMode(.overlay)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            content
        }
    }
}

// MARK: - Grain Overlay
//
// Deterministic pseudo-random film grain. Cheap to render; avoids the
// repeating-pattern artifacts of a static noise image.

private struct GrainOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            let density: CGFloat = 0.16
            let count = Int(size.width * size.height * density / 600)
            var seed: UInt64 = 0xC0FFEE_BEEF
            for _ in 0..<count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let x = CGFloat(seed % 10_000) / 10_000 * size.width
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let y = CGFloat(seed % 10_000) / 10_000 * size.height
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let alpha = 0.06 + CGFloat(seed % 1000) / 1000.0 * 0.18
                ctx.fill(
                    Path(CGRect(x: x, y: y, width: 1, height: 1)),
                    with: .color(Color.white.opacity(alpha))
                )
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Preview

#Preview("Pro Poster Scaffold") {
    ProPosterScaffold {
        VStack(spacing: 12) {
            Text("CLOUD")
                .font(MobileTheme.Typography.tiny)
                .tracking(3)
                .foregroundStyle(ProTheme.Palette.aureate)
            Text("Your agents, unbound.")
                .font(ProTheme.Typography.displaySerif)
                .foregroundStyle(ProTheme.Palette.mercury)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
