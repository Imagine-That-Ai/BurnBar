import SwiftUI

// MARK: - Mercury Divider
//
// Hairline divider with a slow mercury sheen. Used to separate Hermes
// surfaces and section blocks where a plain Divider would feel cheap.

struct MercuryDivider: View {
    var height: CGFloat = 1

    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(MobileTheme.Colors.border.opacity(0.5))
                Rectangle()
                    .fill(AuroraDesign.Gradients.mercuryFoil)
                    .frame(width: geo.size.width * 0.4)
                    .blur(radius: 6)
                    .offset(x: reduceMotion ? 0 : phase * (geo.size.width + geo.size.width * 0.4) - geo.size.width * 0.6)
                    .opacity(0.7)
                    .blendMode(.plusLighter)
            }
            .clipped()
        }
        .frame(height: height)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(AuroraDesign.Motion.mercuryShimmer) {
                phase = 1
            }
        }
    }
}
