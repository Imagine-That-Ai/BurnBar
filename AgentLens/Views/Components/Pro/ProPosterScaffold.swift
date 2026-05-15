import SwiftUI

// MARK: - Pro Poster Scaffold (macOS)
//
// Cinematic stage for Pro destination views. Mirrors the iOS variant.

struct ProPosterScaffold<Content: View>: View {
    var includeGrain: Bool = true
    var includeRibbon: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Rectangle()
                .fill(ProTheme.Palette.obsidian)
                .ignoresSafeArea()

            if includeRibbon {
                Rectangle()
                    .fill(ProTheme.Palette.darkAuroraRibbon)
                    .frame(maxWidth: .infinity)
                    .frame(height: 320)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }

            RadialGradient(
                colors: [
                    ProTheme.Palette.aureate.opacity(0.14),
                    Color.clear
                ],
                center: UnitPoint(x: 0.5, y: 0.16),
                startRadius: 0,
                endRadius: 320
            )
            .blendMode(.plusLighter)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if includeGrain {
                GrainOverlay()
                    .opacity(0.05)
                    .blendMode(.overlay)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            content
        }
    }
}

private struct GrainOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            let density: CGFloat = 0.14
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

#Preview("Pro Poster Scaffold (macOS)") {
    ProPosterScaffold {
        VStack(spacing: 12) {
            Text("CLOUD")
                .font(.caption.weight(.semibold))
                .tracking(3)
                .foregroundStyle(ProTheme.Palette.aureate)
            Text("Your agents, unbound.")
                .font(ProTheme.Typography.displaySerif)
                .foregroundStyle(ProTheme.Palette.mercury)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
    .frame(width: 720, height: 480)
}
