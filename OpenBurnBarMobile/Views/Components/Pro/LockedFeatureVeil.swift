import SwiftUI
import OpenBurnBarCore

// MARK: - Locked Feature Veil
//
// Pro vocabulary — frosted mercury veil over a locked feature. The content
// behind is rendered blurred-but-visible (a teaser) so the user *sees*
// what they're missing — the I-WANT-THAT moment. Centered CTA inside an
// obsidian foil card.
//
// Two content modes:
//   • `.legacy` — the original headline/detail/MercuryCrest anatomy (still used
//     by the cloud-tier Insights / Streams teasers). Default `ctaLabel`
//     "Open Cloud".
//   • `.feature(GatedFeature)` — the tier+feature-aware anatomy: the required
//     tier's glowing holographic crest, the serif `publicName`, the
//     `oneLineBenefit`, the catalog `benefitBullets`, and a
//     "Unlock with <Tier>" FoilCTA, with an "Available on <Tier>" subheader.
//     Driven entirely by the honesty-checked catalog copy.
//
// Suppressed when the user is a member; the host view should just render
// `background` directly in that case.

struct LockedFeatureVeil<Background: View>: View {
    enum Content {
        case legacy(headline: String, detail: String, ctaLabel: String, icon: String)
        case feature(GatedFeature, priceLine: String?)
    }

    let content: Content
    let action: () -> Void
    let background: Background

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Designated init

    init(content: Content, action: @escaping () -> Void, background: Background) {
        self.content = content
        self.action = action
        self.background = background
    }

    // MARK: Legacy init (preserves existing call sites)

    init(
        headline: String,
        detail: String,
        ctaLabel: String = "Open Cloud",
        icon: String = "sparkle",
        action: @escaping () -> Void,
        @ViewBuilder background: () -> Background
    ) {
        self.content = .legacy(headline: headline, detail: detail, ctaLabel: ctaLabel, icon: icon)
        self.action = action
        self.background = background()
    }

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

            switch content {
            case let .legacy(headline, detail, ctaLabel, icon):
                legacyBody(headline: headline, detail: detail, ctaLabel: ctaLabel, icon: icon)
            case let .feature(feature, priceLine):
                featureBody(feature: feature, priceLine: priceLine)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: Legacy anatomy

    @ViewBuilder
    private func legacyBody(headline: String, detail: String, ctaLabel: String, icon: String) -> some View {
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

    // MARK: Feature anatomy — the shared unlock content over the teaser

    @ViewBuilder
    private func featureBody(feature: GatedFeature, priceLine: String?) -> some View {
        ScrollView {
            FeatureUnlockContent(
                feature: feature,
                priceLine: priceLine,
                onUnlock: action,
                onDismiss: nil
            )
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Preview

#Preview("Locked Feature Veil — legacy") {
    LockedFeatureVeil(
        headline: "Insights, surfaced.",
        detail: "Cross-agent patterns, weekly retros, and forecast cohorts — included with OpenBurnBar Cloud.",
        action: {}
    ) {
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

#Preview("Locked Feature Veil — feature (Data Vault)") {
    LockedFeatureVeil(
        feature: GatedFeature.gatedFeature(.dataVault),
        priceLine: "From $24.99/mo",
        action: {}
    ) {
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
