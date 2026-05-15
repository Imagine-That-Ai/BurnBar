import SwiftUI

// MARK: - Locked Feature Veil (macOS)
//
// Frosted mercury veil over a locked workspace canvas (Insights, Hermes
// Square premium filters). The content behind is rendered blurred but
// visible so the user *sees* what they're missing.

struct LockedFeatureVeil<Background: View>: View {
    let headline: String
    let detail: String
    var ctaLabel: String = "Open Cloud"
    var icon: String = "sparkle"
    let action: () -> Void
    @ViewBuilder var background: Background

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            background
                .blur(radius: 16)
                .saturation(0.78)
                .opacity(0.7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            LinearGradient(
                colors: [
                    ProTheme.Palette.obsidian.opacity(0.55),
                    ProTheme.Palette.obsidian.opacity(0.82)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            if !reduceMotion {
                Rectangle()
                    .fill(Color.clear)
                    .mercuryShimmer(active: true)
                    .opacity(0.4)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 18) {
                MercuryCrest(size: .large, shimmer: !reduceMotion)
                VStack(spacing: 10) {
                    Text(headline)
                        .font(ProTheme.Typography.titleSerif)
                        .foregroundStyle(ProTheme.Palette.mercury)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 28)

                FoilCTAButton(title: ctaLabel, icon: icon, fillWidth: false, action: action)
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Locked Feature Veil (macOS)") {
    LockedFeatureVeil(
        headline: "Insights, surfaced.",
        detail: "Cross-agent patterns, weekly retros, and forecast cohorts — included with OpenBurnBar Cloud.",
        action: {}
    ) {
        VStack(spacing: 14) {
            ForEach(0..<4) { _ in
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignSystem.Colors.surface)
                    .frame(height: 72)
            }
        }
        .padding(20)
    }
    .frame(width: 640, height: 480)
}
