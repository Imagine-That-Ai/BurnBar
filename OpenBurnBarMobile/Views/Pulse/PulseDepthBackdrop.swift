import SwiftUI

// MARK: - Pulse Depth Backdrop
//
// A *secondary* aurora layer that lives between `AuroraBackdrop` and the
// Pulse card stack. Where the backdrop sets atmosphere, this layer adds
// **depth**: a stack of soft, brand-tinted halos that drift slowly and
// anchor each card group to a "warm spot" of light. Without it the iPad
// and large-iOS Pulse page reads as a flat list of pale cards stacked on
// the same beige plane.
//
// The halos are purely decorative — `allowsHitTesting(false)` everywhere.
// They respect Reduce Motion (drift becomes static) and Reduce Transparency
// (drops to a single low-opacity tint).

struct PulseDepthBackdrop: View {

    @State private var phase: CGFloat = 0

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Warm "hero" halo — sits behind the top hero card.
                halo(
                    color: MobileTheme.ember,
                    size: max(w * 0.78, 480),
                    blur: 90,
                    intensity: colorScheme == .dark ? 0.40 : 0.24,
                    offset: CGSize(
                        width: -w * 0.18 + drift(amount: 18, freq: 1.0),
                        height: -h * 0.20 + drift(amount: 12, freq: 0.7)
                    )
                )

                // Amber forecast halo — anchors the velocity / forecast band.
                halo(
                    color: MobileTheme.amber,
                    size: max(w * 0.70, 420),
                    blur: 100,
                    intensity: colorScheme == .dark ? 0.30 : 0.18,
                    offset: CGSize(
                        width: w * 0.32 + drift(amount: -22, freq: 0.6),
                        height: -h * 0.04 + drift(amount: 14, freq: 1.3)
                    )
                )

                // Whimsy mid halo — anchors the Trend Atlas / Quota area.
                halo(
                    color: MobileTheme.whimsy,
                    size: max(w * 0.66, 380),
                    blur: 110,
                    intensity: colorScheme == .dark ? 0.22 : 0.12,
                    offset: CGSize(
                        width: -w * 0.22 + drift(amount: 24, freq: 0.9),
                        height: h * 0.18 + drift(amount: -18, freq: 0.5)
                    )
                )

                // Hermes mercury halo — anchors the Hermes / Recents tail.
                halo(
                    color: MobileTheme.hermesMercury,
                    size: max(w * 0.62, 360),
                    blur: 100,
                    intensity: colorScheme == .dark ? 0.20 : 0.10,
                    offset: CGSize(
                        width: w * 0.30 + drift(amount: -16, freq: 0.8),
                        height: h * 0.36 + drift(amount: 20, freq: 0.4)
                    )
                )

                // Blaze foot halo — anchors the bottom of the scroll.
                halo(
                    color: MobileTheme.blaze,
                    size: max(w * 0.74, 420),
                    blur: 120,
                    intensity: colorScheme == .dark ? 0.18 : 0.08,
                    offset: CGSize(
                        width: -w * 0.04 + drift(amount: 14, freq: 1.1),
                        height: h * 0.46 + drift(amount: -12, freq: 0.7)
                    )
                )
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .blendMode(.plusLighter)
            .opacity(reduceTransparency ? 0.55 : 1.0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { startAnimating() }
        .onChange(of: reduceMotion) { _, _ in startAnimating() }
    }

    // MARK: - Halo

    private func halo(color: Color, size: CGFloat, blur: CGFloat, intensity: Double, offset: CGSize) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        color.opacity(intensity),
                        color.opacity(intensity * 0.35),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.55
                )
            )
            .frame(width: size, height: size)
            .blur(radius: blur)
            .offset(offset)
    }

    // MARK: - Drift

    private func drift(amount: CGFloat, freq: CGFloat) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let theta = phase * .pi * 2 * freq
        return CGFloat(sin(theta)) * amount
    }

    private func startAnimating() {
        guard !reduceMotion else { phase = 0; return }
        withAnimation(.linear(duration: 22).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

// MARK: - Section Eyebrow Rule
//
// Thin gradient divider used between major Pulse sections to give the
// stack a sense of vertical rhythm without adding new chrome.

struct PulseSectionRule: View {
    var label: String? = nil
    var accent: Color = MobileTheme.ember

    var body: some View {
        HStack(spacing: 10) {
            if let label {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(2.0)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.55),
                            accent.opacity(0.18),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .padding(.horizontal, AuroraDesign.Layout.cardInset + 4)
        .padding(.top, 2)
        .padding(.bottom, -6)
        .accessibilityHidden(true)
    }
}
