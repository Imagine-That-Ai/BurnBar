import SwiftUI
import OpenBurnBarCore

// MARK: - Locked Feature Veil
//
// Pro vocabulary — frosted mercury veil over a locked feature. The content
// behind is rendered blurred-but-visible (a teaser) so the user *sees*
// what they're missing — the I-WANT-THAT moment. Centered CTA inside an
// obsidian foil card.
//
// Suppressed when the user is a member; the host view should just render
// `background` directly in that case.

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
            // Blurred teaser content — visible enough to be evocative, dim
            // enough that the foil card reads as the focal point.
            background
                .blur(radius: 16)
                .saturation(0.78)
                .opacity(0.7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // Obsidian veil dims the teaser into the Pro palette.
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
                MercuryShimmerOverlay()
                    .blendMode(.plusLighter)
                    .opacity(0.4)
                    .allowsHitTesting(false)
            }

            VStack(spacing: MobileTheme.Spacing.lg) {
                MercuryCrest(size: .large, shimmer: !reduceMotion)

                VStack(spacing: MobileTheme.Spacing.sm) {
                    Text(headline)
                        .font(ProTheme.Typography.titleSerif)
                        .foregroundStyle(ProTheme.Palette.mercury)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, MobileTheme.Spacing.xl)

                FoilCTAButton(title: ctaLabel, icon: icon, fillWidth: false, action: action)
                    .frame(maxWidth: 340)
            }
            .padding(.horizontal, MobileTheme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Preview

#Preview("Locked Feature Veil") {
    LockedFeatureVeil(
        headline: "Insights, surfaced.",
        detail: "Cross-agent patterns, weekly retros, and forecast cohorts — included with OpenBurnBar Cloud.",
        action: {}
    ) {
        // Fake content behind the veil
        VStack(spacing: 16) {
            ForEach(0..<4) { _ in
                RoundedRectangle(cornerRadius: 14)
                    .fill(MobileTheme.Colors.surface)
                    .frame(height: 80)
            }
        }
        .padding(20)
    }
}
