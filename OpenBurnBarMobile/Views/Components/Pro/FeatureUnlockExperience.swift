import SwiftUI
import OpenBurnBarCore

// MARK: - Feature Unlock Experience
//
// The tier+feature-aware "oh, I want that" moment. One shared anatomy, two
// presentations, plus the resting denotation chip — all driven by the
// `GatedFeature` catalog in OpenBurnBarCore (copy verbatim from the gating
// spec §3). Reuses the existing premium design language: the per-tier
// holographic crest (`HolographicCrestAura`), the serif Pro voice
// (`ProTheme.Typography`), `FoilCTAButton`, and `ProTheme.Palette` obsidian.
//
// Honesty by construction: every line of copy comes from the catalog, which
// is the honesty-checked §3 data. This file never hardcodes a benefit string,
// a price, or a tier name beyond `CloudTier.membershipName`.
//
//   • `FeatureUnlockHero`     — the glowing required-tier crest + chip + serif
//                               feature name + one-liner.
//   • `FeatureUnlockBenefits` — the "What you'll unlock" bullet list.
//   • `FeatureUnlockFooter`   — the single FoilCTAButton + quiet "Maybe later".
//   • `FeatureUnlockContent`  — the three stacked into the full sheet body.
//   • `FeatureUnlockSheet`    — the `.sheet`-presented version (row/button gates).
//   • `TierLockBadge`         — the resting holographic tier chip on a row/card.
//   • `View.gatedFeature(_:tier:perform:)` — the one-liner gate modifier.
//   • `View.tierLockBadge(_:tier:)`        — attaches the resting chip when locked.
//   • `LockedFeatureVeil(feature:tier:…)`  — full-screen veil overload (§4.4).

// MARK: - Presentation identity
//
// `GatedFeatureID` lives in OpenBurnBarCore (pure Foundation) and is not
// `Identifiable`. This presentation-only wrapper lets a `@State
// GatedFeatureID?` drive a `.sheet(item:)` without retroactively conforming a
// type from another module.
struct GatedFeaturePresentation: Identifiable, Hashable {
    let id: GatedFeatureID
    var feature: GatedFeature { GatedFeature.gatedFeature(id) }
}

extension GatedFeatureID {
    /// Wrap for `.sheet(item:)` presentation.
    var presentation: GatedFeaturePresentation { GatedFeaturePresentation(id: self) }
}

// MARK: - Aspirational subheader / CTA copy

private extension CloudTier {
    /// "Available on Cloud Pro" — the quiet aspirational subheader.
    var availabilityLine: String { "Available on \(membershipName)" }

    /// "Unlock with Cloud Pro" — the single soft CTA label.
    var unlockCTALabel: String { "Unlock with \(membershipName)" }
}

// MARK: - Live price lookup
//
// Prices come live from StoreKit — never hardcoded. We surface the *entry*
// (monthly) product's display price for the required tier when the store has
// loaded it, falling back to the catalog's documented price only as the
// StoreKit-mandated placeholder until metadata arrives.
enum TierPricing {
    /// The monthly subscription product backing each tier, used to read the
    /// live StoreKit display price for the unlock footer.
    static func entryProductID(for tier: CloudTier) -> String? {
        switch tier {
        case .none, .cloud: return OpenBurnBarProductCatalog.cloudMonthlyProductID
        case .pro:          return OpenBurnBarProductCatalog.cloudProMonthlyProductID
        case .ultra:        return OpenBurnBarProductCatalog.cloudUltraMonthlyProductID
        }
    }

    /// Live "from $24.99/mo" line for the footer, or `nil` when no price is
    /// resolvable (the footer then shows only the availability subheader).
    @MainActor
    static func priceLine(for tier: CloudTier, store: HostedQuotaSubscriptionStore?) -> String? {
        guard let id = entryProductID(for: tier),
              let catalog = OpenBurnBarProductCatalog.product(for: id) else { return nil }
        let price = store?.displayPrice(for: catalog) ?? catalog.fallbackDisplayPrice
        return "From \(price)/mo"
    }
}

// MARK: - Hero

/// The glowing required-tier crest, a small tier chip, the serif feature name,
/// and the one-liner beneath. Reused by the sheet and the full-screen veil.
struct FeatureUnlockHero: View {
    let feature: GatedFeature
    var crestSize: CGFloat = 120

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tier: CloudTier { feature.requiredTier }

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            heroCrest
            TierLockBadge(tier: tier, style: .pill)
            VStack(spacing: MobileTheme.Spacing.sm) {
                Text(feature.publicName)
                    .font(ProTheme.Typography.titleSerif)
                    .foregroundStyle(ProTheme.Palette.mercury)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(feature.oneLineBenefit)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.74))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, MobileTheme.Spacing.sm)
        }
        .frame(maxWidth: .infinity)
    }

    // The required tier's iridescent crest, glowing — the hero variant of the
    // store-card aura. The feature's SF Symbol floats inside as a quiet anchor.
    private var heroCrest: some View {
        ZStack {
            HolographicCrestAura(
                crestImageName: tier.crestAssetName,
                gradient: tier.holoGradient,
                intensity: .hero
            )
            Image(tier.crestAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: crestSize * 0.62, height: crestSize * 0.62)
                .shadow(color: ProTheme.Palette.aureate.opacity(0.40), radius: 10, y: 3)
            Image(systemName: feature.iconSystemName)
                .font(.system(size: crestSize * 0.18, weight: .semibold))
                .foregroundStyle(ProTheme.Palette.mercury)
                .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                .accessibilityHidden(true)
        }
        .frame(width: crestSize, height: crestSize)
    }
}

// MARK: - Benefits

/// "What you'll unlock" — the 3-4 catalog bullets, each with a foil checkmark.
struct FeatureUnlockBenefits: View {
    let feature: GatedFeature

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("WHAT YOU'LL UNLOCK")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(2.0)
                .foregroundStyle(ProTheme.Palette.mercury.opacity(0.55))

            ForEach(Array(feature.benefitBullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(ProTheme.Palette.aureate.opacity(0.16))
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(ProTheme.Palette.aureate.opacity(0.30), lineWidth: 0.75)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(ProTheme.Palette.aureate)
                    }
                    .frame(width: 26, height: 26)
                    Text(bullet)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Footer

/// The single soft CTA + quiet "Maybe later", with the aspirational
/// availability subheader and a live StoreKit price line.
struct FeatureUnlockFooter: View {
    let tier: CloudTier
    var priceLine: String?
    let onUnlock: () -> Void
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            VStack(spacing: 2) {
                Text(tier.availabilityLine)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.66))
                if let priceLine {
                    Text(priceLine)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.46))
                }
            }

            FoilCTAButton(
                title: tier.unlockCTALabel,
                icon: "sparkles",
                fillWidth: false,
                action: onUnlock
            )
            .frame(maxWidth: 360)

            if let onDismiss {
                Button("Maybe later", action: onDismiss)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.55))
                    .padding(.top, 2)
                    .accessibilityHint("Dismisses without subscribing")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Full unlock body (shared by the sheet)

/// The complete anatomy (hero → benefits → footer), stacked. Used as the body
/// of `FeatureUnlockSheet`. The full-screen veil composes the same three pieces
/// over a blurred teaser instead.
struct FeatureUnlockContent: View {
    let feature: GatedFeature
    var priceLine: String?
    let onUnlock: () -> Void
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            FeatureUnlockHero(feature: feature)
            FeatureUnlockBenefits(feature: feature)
            FeatureUnlockFooter(
                tier: feature.requiredTier,
                priceLine: priceLine,
                onUnlock: onUnlock,
                onDismiss: onDismiss
            )
        }
        .padding(.horizontal, MobileTheme.Spacing.xl)
        .padding(.vertical, MobileTheme.Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Feature Unlock Sheet

/// The `.sheet`-presented unlock moment for row/button entry points that are
/// not whole screens. Obsidian backdrop, a quiet mercury shimmer, and the
/// shared anatomy. Opens `CloudStoreView` to begin the purchase; billing logic
/// is untouched.
struct FeatureUnlockSheet: View {
    let feature: GatedFeature

    @Environment(\.dismiss) private var dismiss
    @Environment(\.cloudSubscriptionStore) private var cloudStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showCloudStore = false

    var body: some View {
        ZStack {
            ProTheme.Palette.obsidian.ignoresSafeArea()
            ProTheme.Palette.darkAuroraRibbon
                .ignoresSafeArea()
                .allowsHitTesting(false)
            if !reduceMotion {
                MercuryShimmerOverlay()
                    .blendMode(.plusLighter)
                    .opacity(0.18)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            ScrollView {
                FeatureUnlockContent(
                    feature: feature,
                    priceLine: TierPricing.priceLine(for: feature.requiredTier, store: cloudStore),
                    onUnlock: {
                        Haptics.medium()
                        showCloudStore = true
                    },
                    onDismiss: { dismiss() }
                )
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showCloudStore) {
            NavigationStack {
                CloudStoreView(onClose: { showCloudStore = false })
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(feature.publicName). \(feature.requiredTier.availabilityLine).")
    }
}

// MARK: - Tier Lock Badge

/// The resting denotation chip on a gated entry point — a compact holographic
/// tier chip (mini crest + tier name), a *premium shimmer-lock*, never a grey
/// padlock. Two styles: an inline trailing chip on a row, and a corner overlay
/// on a card/tile. Reduce-motion → static (the chip is already static).
struct TierLockBadge: View {
    enum Style {
        /// Trailing chip on a row: mini crest + "Cloud Pro" + a soft lock glyph.
        case inline
        /// Compact corner pill (overlay on a card/tile): crest + tier name.
        case corner
        /// Larger pill used inside the unlock hero.
        case pill
    }

    let tier: CloudTier
    var style: Style = .inline

    private var crestSize: CGFloat {
        switch style {
        case .inline: return 16
        case .corner: return 14
        case .pill:   return 18
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(tier.crestAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: crestSize, height: crestSize)
            Text(tier.membershipName)
                .font(.system(size: style == .pill ? 12 : 11, weight: .bold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(ProTheme.Membership.foilLeaf)
            if style == .inline {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ProTheme.Membership.foilLeaf.opacity(0.8))
            }
        }
        .padding(.horizontal, style == .pill ? 12 : 8)
        .padding(.vertical, style == .pill ? 6 : 4)
        .background(chipBackground)
        .overlay(chipBorder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Available on \(tier.membershipName)")
    }

    private var chipBackground: some View {
        Capsule(style: .continuous)
            .fill(ProTheme.Membership.surfaceElevated.opacity(0.9))
            .overlay(
                Capsule(style: .continuous)
                    .fill(tier.holoGradient)
                    .opacity(0.12)
            )
    }

    private var chipBorder: some View {
        Capsule(style: .continuous)
            .stroke(ProTheme.Membership.foilEdge, lineWidth: 0.8)
    }
}

// MARK: - Gating modifiers

private struct GatedFeatureModifier: ViewModifier {
    let feature: GatedFeature
    let tier: CloudTier
    let perform: () -> Void

    @State private var showUnlock = false

    private var isUnlocked: Bool { tier.satisfies(feature.requiredTier) }

    func body(content: Content) -> some View {
        content
            // Intercept the tap: run the real action when entitled, otherwise
            // present the unlock sheet. `highPriorityGesture` wins over an
            // inner Button/NavigationLink's own tap so locked entry points
            // never fire their raw action.
            .modifier(GateTapModifier(isUnlocked: isUnlocked, perform: perform, showUnlock: { showUnlock = true }))
            .sheet(isPresented: $showUnlock) {
                FeatureUnlockSheet(feature: feature)
            }
    }
}

/// Routes a tap to either the real action (entitled) or the unlock sheet
/// (locked). When locked it adds a high-priority tap that suppresses the
/// inner control; when unlocked it leaves the inner control's own action intact
/// and simply layers the supplied `perform` on tap.
private struct GateTapModifier: ViewModifier {
    let isUnlocked: Bool
    let perform: () -> Void
    let showUnlock: () -> Void

    func body(content: Content) -> some View {
        if isUnlocked {
            content
                .simultaneousGesture(TapGesture().onEnded { perform() })
        } else {
            content
                .allowsHitTesting(true)
                .highPriorityGesture(TapGesture().onEnded {
                    Haptics.light()
                    showUnlock()
                })
        }
    }
}

private struct TierLockBadgeModifier: ViewModifier {
    let feature: GatedFeature
    let tier: CloudTier

    private var isLocked: Bool { !tier.satisfies(feature.requiredTier) }

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if isLocked {
                TierLockBadge(tier: feature.requiredTier, style: .corner)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// One-liner gate. When `tier` satisfies the feature's required tier the
    /// tap runs `perform()`; otherwise it presents the `FeatureUnlockSheet` for
    /// that feature. The host control's own navigation/action should be
    /// disabled when locked (callers gate the destination separately for
    /// full-screen features), but the high-priority tap here suppresses an
    /// inner tap so a locked row never fires its raw action.
    func gatedFeature(
        _ id: GatedFeatureID,
        tier: CloudTier,
        perform: @escaping () -> Void
    ) -> some View {
        modifier(GatedFeatureModifier(
            feature: GatedFeature.gatedFeature(id),
            tier: tier,
            perform: perform
        ))
    }

    /// Attaches the resting `TierLockBadge` (corner overlay) when `tier` does
    /// not satisfy the feature's requirement; renders nothing when entitled.
    func tierLockBadge(_ id: GatedFeatureID, tier: CloudTier) -> some View {
        modifier(TierLockBadgeModifier(
            feature: GatedFeature.gatedFeature(id),
            tier: tier
        ))
    }
}

// MARK: - Tier-aware Locked Feature Veil (full-screen)
//
// The full-screen sibling of the sheet for whole-screen gated features
// (Pensieve memory search, Floo live view). Keeps the blurred-teaser pattern
// of the original `LockedFeatureVeil` but renders the SHARED anatomy — the
// required tier's glowing crest, the serif feature name, the catalog bullets,
// and the single FoilCTA — over a blurred teaser of the real feature.

extension LockedFeatureVeil {
    /// Convenience init that drives the veil entirely from a `GatedFeature`
    /// plus a price line, presenting the catalog copy with the required tier's
    /// crest. Use for full-screen gated features.
    init(
        feature: GatedFeature,
        priceLine: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder background: () -> Background
    ) {
        self.init(
            content: .feature(feature, priceLine: priceLine),
            action: action,
            background: background()
        )
    }
}
