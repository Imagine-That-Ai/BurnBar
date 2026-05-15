import SwiftUI

// MARK: - Mercury Foil Card (macOS)
//
// Pro vocabulary — obsidian card with foil edge and continuous mercury
// shimmer. Mirrors the iOS variant; uses the existing AgentLens
// `.mercuryShimmer(active:)` modifier instead of an overlay view.

struct MercuryFoilCard<Content: View>: View {
    enum Tone {
        case obsidian
        case obsidianElevated
    }

    var tone: Tone = .obsidian
    var cornerRadius: CGFloat = ProTheme.Layout.cardRadius
    var enableSpecular: Bool = true
    var enableShimmer: Bool = true

    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var specularPhase: CGFloat = -1.4
    @State private var didFireSpecular = false

    var body: some View {
        content
            .background(backgroundLayers)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ProTheme.Palette.aureateStroke, lineWidth: ProTheme.Layout.foilStroke)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: ProTheme.Palette.aureate.opacity(0.18), radius: 20, y: 9)
            .onAppear(perform: fireSpecularIfNeeded)
    }

    @ViewBuilder
    private var backgroundLayers: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tone == .obsidian ? ProTheme.Palette.obsidian : ProTheme.Palette.obsidianElevated)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            ProTheme.Palette.aureate.opacity(0.12),
                            Color.clear
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 320
                    )
                )
                .blendMode(.plusLighter)

            if enableShimmer && !reduceMotion {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.clear)
                    .mercuryShimmer(active: true)
                    .opacity(0.55)
                    .allowsHitTesting(false)
            }

            if enableSpecular && !reduceMotion {
                SpecularSweepLayer(phase: specularPhase)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
        }
    }

    private func fireSpecularIfNeeded() {
        guard enableSpecular, !reduceMotion, !didFireSpecular else { return }
        didFireSpecular = true
        specularPhase = -1.4
        withAnimation(ProTheme.Motion.specular.delay(0.15)) {
            specularPhase = 1.4
        }
    }
}

private struct SpecularSweepLayer: View {
    let phase: CGFloat

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    Color.clear,
                    ProTheme.Palette.aureate.opacity(0.22),
                    Color.white.opacity(0.22),
                    ProTheme.Palette.aureate.opacity(0.22),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.55, height: geo.size.height * 1.6)
            .rotationEffect(.degrees(18))
            .offset(x: phase * geo.size.width, y: -geo.size.height * 0.3)
        }
        .accessibilityHidden(true)
    }
}

#Preview("Mercury Foil Card (macOS)") {
    ZStack {
        ProTheme.Palette.obsidian.ignoresSafeArea()
        MercuryFoilCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("OpenBurnBar Cloud")
                    .font(ProTheme.Typography.titleSerif)
                    .foregroundStyle(ProTheme.Palette.mercury)
                Text("Your agents, unbound.")
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.7))
            }
            .padding(24)
            .frame(maxWidth: 400, alignment: .leading)
        }
        .padding(24)
    }
    .frame(width: 520, height: 320)
}
