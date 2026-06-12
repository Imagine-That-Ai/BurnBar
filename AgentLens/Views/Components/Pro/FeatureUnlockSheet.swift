import SwiftUI
import AppKit
import OpenBurnBarCore

// MARK: - Feature Gating & Evocative Upsell (macOS)
//
// Canonical spec: docs/FEATURE_GATING_SPEC.md (§3 copy, §4 anatomy, §5 entry
// points). This file is the macOS unlock experience that consumes the shared
// `GatedFeature` catalog in `OpenBurnBarCore`. iOS/iPadOS render the same copy
// from the same catalog with their own native chrome.
//
// What lives here:
//   • `MacGatedTierStyle` — the per-tier holographic palette + accent, mirrored
//     1:1 with the website's `--holo-grad` and `CloudStoreSettingsView`'s tier
//     cards (cloud → warm ember, pro → cool aqua, ultra → full-spectrum).
//   • `TierLockBadge` — the resting "premium shimmer-lock" chip on a gated row
//     or card (inline + corner sizes), never a grey padlock.
//   • `TierCrestHero` — the glowing required-tier crest, reusing the holographic
//     silhouette technique so the hero wears the marketing aesthetic.
//   • `FeatureUnlockSheet` — the `.sheet`-presented unlock moment for a row /
//     button / card (spec §4.4 anatomy).
//   • `FeatureLockedVeil` — the full-screen blurred-teaser equivalent for whole
//     gated screens (spec §4.4), tier + feature aware.
//   • `.gatedFeature(...)` / `.tierLockBadge(...)` — one-liner SwiftUI modifiers.
//
// Honesty guardrails are carried verbatim by the catalog; this UI never adds
// claims of its own. Prices come live from StoreKit — the unlock footer shows
// only the tier name and routes to the Cloud store, never a hardcoded amount.

// MARK: - Per-tier holographic style

/// Maps a `CloudTier` to its holographic palette + accent so every gating
/// surface paints the same iridescence as the marketing site and the Cloud
/// store tier cards. Cloud = warm ember, Pro = cool aqua, Ultra = full-spectrum.
enum MacGatedTierStyle {
    /// Iridescent gradient stops for the tier's holographic silhouette — mirrors
    /// the website's per-tier `--holo-grad` and `MacPricingTierModel.holoPalette`.
    static func holoPalette(for tier: CloudTier) -> [Color] {
        switch tier {
        case .none, .cloud:
            return [
                Color(hex: "FFD56B"),
                Color(hex: "FF8A3D"),
                Color(hex: "FF5C8A"),
                Color(hex: "B06BFF")
            ]
        case .pro:
            return [
                Color(hex: "5EF0C9"),
                Color(hex: "38D6F3"),
                Color(hex: "4F8BFF"),
                Color(hex: "8EF0A8")
            ]
        case .ultra:
            return [
                Color(hex: "FFD56B"),
                Color(hex: "7DD3FC"),
                Color(hex: "C084FC"),
                Color(hex: "5EEAD4"),
                Color(hex: "FF9EC7")
            ]
        }
    }

    /// The solid accent that tints chips, glows, and bullet glyphs for the tier.
    static func accent(for tier: CloudTier) -> Color {
        switch tier {
        case .none, .cloud: return DesignSystem.Colors.ember
        case .pro:          return DesignSystem.Colors.whimsy
        case .ultra:        return DesignSystem.Colors.amber
        }
    }
}

// MARK: - Tier holographic crest accent (reusable silhouette)

/// The signature look: the required tier's transparent crest, used as a
/// silhouette MASK over a slowly-drifting iridescent gradient. Rendered as a
/// faint backdrop on cards/badges, or at hero opacity behind the unlock crest.
/// Native SwiftUI mirror of the website's `.plan__holo` technique and the
/// private `TierHolographicAccent` in `CloudStoreSettingsView` — kept public so
/// every gating surface shares one implementation.
struct TierHolographicCrestAccent: View {
    let crestAsset: String
    let palette: [Color]
    var heroOpacity: Double = 0.13
    var reduceMotion: Bool = false
    var alignment: Alignment = .center
    var horizontalOffsetFraction: CGFloat = 0
    var verticalOffsetFraction: CGFloat = 0

    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let side = min(max(geo.size.width, geo.size.height) * 0.92, 360)
            iridescentGradient
                .frame(width: side, height: side)
                .mask(
                    Image(crestAsset)
                        .resizable()
                        .scaledToFit()
                        .frame(width: side, height: side)
                )
                .opacity(reduceMotion ? heroOpacity * 0.62 : heroOpacity)
                .blur(radius: 0.5)
                .frame(width: geo.size.width, height: geo.size.height, alignment: alignment)
                .offset(x: geo.size.width * horizontalOffsetFraction, y: geo.size.height * verticalOffsetFraction)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 11).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .accessibilityHidden(true)
    }

    private var iridescentGradient: some View {
        let stops = palette.isEmpty ? [Color.white.opacity(0.4)] : palette
        let looped = stops + stops.reversed() + [stops.first ?? .white]
        return AngularGradient(
            gradient: Gradient(colors: looped),
            center: .center,
            angle: .degrees(reduceMotion ? 0 : Double(phase) * 360)
        )
        .saturation(1.2)
    }
}

// MARK: - Tier crest hero

/// The glowing required-tier crest used at the top of the unlock experiences:
/// a soft radial glow, the iridescent holographic silhouette behind, and the
/// crisp transparent crest asset on top.
struct TierCrestHero: View {
    let tier: CloudTier
    var diameter: CGFloat = 116

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let accent = MacGatedTierStyle.accent(for: tier)
        ZStack {
            RadialGradient(
                colors: [accent.opacity(0.42), accent.opacity(0.14), .clear],
                center: .center,
                startRadius: 0,
                endRadius: diameter * 0.78
            )
            .blendMode(.plusLighter)
            .frame(width: diameter * 1.7, height: diameter * 1.7)

            TierHolographicCrestAccent(
                crestAsset: tier.crestAssetName,
                palette: MacGatedTierStyle.holoPalette(for: tier),
                heroOpacity: 0.42,
                reduceMotion: reduceMotion
            )
            .frame(width: diameter * 1.18, height: diameter * 1.18)

            Image(tier.crestAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: diameter, height: diameter)
                .shadow(color: accent.opacity(0.45), radius: 16, y: 6)
        }
        .frame(width: diameter * 1.7, height: diameter * 1.7)
        .accessibilityHidden(true)
    }
}

// MARK: - Tier chip (the small "CLOUD PRO" pill)

/// A compact holographic tier chip — the tier's mini crest + tier name, with a
/// faint iridescent fill. Used inside the unlock hero and the resting badge.
struct TierChip: View {
    let tier: CloudTier
    var showsCrest: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let accent = MacGatedTierStyle.accent(for: tier)
        HStack(spacing: 5) {
            if showsCrest {
                Image(tier.crestAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(tier.displayName.uppercased())
                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                .tracking(1.2)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            ZStack {
                Capsule(style: .continuous).fill(.ultraThinMaterial)
                Capsule(style: .continuous).fill(accent.opacity(0.14))
                if !reduceMotion {
                    Capsule(style: .continuous)
                        .fill(Color.clear)
                        .mercuryShimmer(active: true)
                        .opacity(0.5)
                }
            }
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(accent.opacity(0.45), lineWidth: 0.7)
        )
        .accessibilityLabel("Available on \(tier.displayName)")
    }
}

// MARK: - Tier lock badge (resting denotation)

/// The resting "premium shimmer-lock" marker on a gated entry point. Inline
/// chips trail a row; corner chips overlay a card/tile. Never a grey padlock —
/// always the tier's iridescent shimmer chip.
struct TierLockBadge: View {
    enum Placement {
        case inline
        case corner
    }

    let tier: CloudTier
    var placement: Placement = .inline

    var body: some View {
        TierChip(tier: tier)
            .shadow(
                color: MacGatedTierStyle.accent(for: tier).opacity(placement == .corner ? 0.30 : 0.0),
                radius: placement == .corner ? 8 : 0,
                y: placement == .corner ? 3 : 0
            )
    }
}

// MARK: - Shared unlock anatomy

/// The shared top→bottom anatomy used by both the sheet and the full-screen
/// veil (spec §4.4): tier crest hero, tier chip, serif feature headline, the
/// one-line benefit, the "What you'll unlock" bullets, and the footer with one
/// soft `FoilCTAButton` ("Unlock with <Tier>") plus a quiet "Maybe later".
private struct FeatureUnlockBody: View {
    let feature: GatedFeature
    var compact: Bool = false
    let onUnlock: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tier: CloudTier { feature.requiredTier }

    var body: some View {
        VStack(spacing: compact ? 18 : 22) {
            VStack(spacing: 14) {
                TierCrestHero(tier: tier, diameter: compact ? 100 : 120)

                TierChip(tier: tier)

                VStack(spacing: 8) {
                    Text(feature.publicName)
                        .font(ProTheme.Typography.titleSerif)
                        .foregroundStyle(ProTheme.Palette.mercury)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(feature.oneLineBenefit)
                        .font(.system(size: 13.5))
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }
            }

            benefitList

            footer
        }
        .padding(.horizontal, 30)
        .accessibilityElement(children: .contain)
    }

    private var benefitList: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("WHAT YOU'LL UNLOCK")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.8)
                .foregroundStyle(MacGatedTierStyle.accent(for: tier))
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(feature.benefitBullets, id: \.self) { bullet in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MacGatedTierStyle.accent(for: tier))
                        .padding(.top, 2.5)
                    Text(bullet)
                        .font(.system(size: 12.5))
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: 440)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Text("Available on \(tier.displayName)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ProTheme.Palette.mercury.opacity(0.6))

            FoilCTAButton(
                title: "Unlock with \(tier.displayName)",
                icon: feature.iconSystemName,
                fillWidth: false,
                action: onUnlock
            )
            .frame(maxWidth: 360)

            Button(action: onDismiss) {
                Text("Maybe later")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Maybe later. Dismiss.")
        }
    }
}

// MARK: - Feature unlock sheet (row / button / card)

/// The `.sheet`-presented unlock moment for an entry point that isn't a whole
/// screen (a settings row, a Floo entry, a card). Obsidian poster backdrop with
/// the tier holographic silhouette behind the shared anatomy.
struct FeatureUnlockSheet: View {
    let feature: GatedFeature
    /// Invoked when the user taps the soft CTA. Defaults to routing into the
    /// Cloud store; callers can override for a custom destination.
    var onUnlock: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ProTheme.Palette.obsidian.ignoresSafeArea()

            TierHolographicCrestAccent(
                crestAsset: feature.requiredTier.crestAssetName,
                palette: MacGatedTierStyle.holoPalette(for: feature.requiredTier),
                heroOpacity: 0.10,
                reduceMotion: reduceMotion,
                alignment: .top,
                horizontalOffsetFraction: 0.16,
                verticalOffsetFraction: -0.22
            )
            .ignoresSafeArea()

            ProTheme.Palette.darkAuroraRibbon
                .frame(height: 140)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .ignoresSafeArea(edges: .top)

            ScrollView {
                FeatureUnlockBody(
                    feature: feature,
                    onUnlock: {
                        if let onUnlock {
                            onUnlock()
                        } else {
                            FeatureGateRouting.routeToCloudStore()
                        }
                        dismiss()
                    },
                    onDismiss: { dismiss() }
                )
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }

            closeButton
        }
        .frame(width: 480, height: 600)
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                // Glass lives on the system chrome only — the holo/crest card
                // below stays glassless (brand rule).
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.7))
                        .liquidGlassCircleButton(diameter: 28)
                        .padding(10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            Spacer()
        }
    }
}

// MARK: - Feature locked veil (full-screen, blurred teaser)

/// The full-screen unlock surface for whole gated screens — the blurred-teaser
/// `LockedFeatureVeil` pattern made tier + feature aware. The real feature is
/// rendered blurred behind the veil so the user *sees* what they're unlocking,
/// while the shared anatomy explains the benefit and offers one soft CTA.
struct FeatureLockedVeil<Background: View>: View {
    let feature: GatedFeature
    var onUnlock: (() -> Void)?
    @ViewBuilder var background: Background

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            background
                .blur(radius: 18)
                .saturation(0.76)
                .opacity(0.68)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            LinearGradient(
                colors: [
                    ProTheme.Palette.obsidian.opacity(0.58),
                    ProTheme.Palette.obsidian.opacity(0.86)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            TierHolographicCrestAccent(
                crestAsset: feature.requiredTier.crestAssetName,
                palette: MacGatedTierStyle.holoPalette(for: feature.requiredTier),
                heroOpacity: 0.10,
                reduceMotion: reduceMotion,
                alignment: .top,
                horizontalOffsetFraction: 0.18,
                verticalOffsetFraction: -0.18
            )
            .allowsHitTesting(false)

            ScrollView {
                FeatureUnlockBody(
                    feature: feature,
                    onUnlock: {
                        if let onUnlock {
                            onUnlock()
                        } else {
                            FeatureGateRouting.routeToCloudStore()
                        }
                    },
                    onDismiss: {}
                )
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension FeatureLockedVeil where Background == Color {
    /// Convenience for a veil with no teaser canvas behind it.
    init(feature: GatedFeature, onUnlock: (() -> Void)? = nil) {
        self.init(feature: feature, onUnlock: onUnlock) { ProTheme.Palette.obsidian }
    }
}

// MARK: - Routing into the Cloud store

/// Centralizes the "open the Cloud store" hand-off so every gating surface
/// parks the deep-link tab the same way `CloudWhisperStrip` does. The Settings
/// window consumes `settings.pendingTab` on appear; when the window is already
/// open we also post a notification so the live router jumps immediately.
enum FeatureGateRouting {
    static let openCloudStoreNotification = Notification.Name("openburnbar.openCloudStore")

    @MainActor
    static func routeToCloudStore() {
        UserDefaults.standard.set(SettingsTab.cloud.rawValue, forKey: "settings.pendingTab")
        NotificationCenter.default.post(name: openCloudStoreNotification, object: nil)
    }
}

// MARK: - Gating modifiers (one-liner application)

/// Wraps content in a `.sheet`-driven gate. Tapping runs `action` when the
/// member's tier satisfies the requirement; otherwise it presents the
/// `FeatureUnlockSheet`. Apply to a tappable row/button/card.
private struct GatedFeatureModifier: ViewModifier {
    let feature: GatedFeature
    let tier: CloudTier
    let onUnlocked: () -> Void
    var customUnlock: (() -> Void)?

    @State private var isPresentingUnlock = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                if tier.satisfies(feature.requiredTier) {
                    onUnlocked()
                } else {
                    isPresentingUnlock = true
                }
            }
            .sheet(isPresented: $isPresentingUnlock) {
                FeatureUnlockSheet(feature: feature, onUnlock: customUnlock)
            }
    }
}

/// Trails a `TierLockBadge` on a row when the member's tier doesn't yet satisfy
/// the feature requirement; renders nothing once the gate is satisfied.
private struct TierLockBadgeModifier: ViewModifier {
    let feature: GatedFeature
    let tier: CloudTier
    var placement: TierLockBadge.Placement

    func body(content: Content) -> some View {
        if tier.satisfies(feature.requiredTier) {
            content
        } else if placement == .corner {
            content.overlay(alignment: .topTrailing) {
                TierLockBadge(tier: feature.requiredTier, placement: .corner)
                    .padding(8)
            }
        } else {
            HStack(spacing: 8) {
                content
                TierLockBadge(tier: feature.requiredTier, placement: .inline)
            }
        }
    }
}

extension View {
    /// Gate a tappable entry point. When `tier` satisfies the feature's
    /// requirement, a tap runs `action`; otherwise it presents the evocative
    /// `FeatureUnlockSheet`. Pass `unlock` to override the CTA destination
    /// (defaults to routing into the Cloud store).
    func gatedFeature(
        _ id: GatedFeatureID,
        tier: CloudTier,
        unlock: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        modifier(
            GatedFeatureModifier(
                feature: GatedFeature.gatedFeature(id),
                tier: tier,
                onUnlocked: action,
                customUnlock: unlock
            )
        )
    }

    /// Trail (or overlay) the resting `TierLockBadge` on a gated entry point
    /// when `tier` doesn't yet satisfy the requirement.
    func tierLockBadge(
        _ id: GatedFeatureID,
        tier: CloudTier,
        placement: TierLockBadge.Placement = .inline
    ) -> some View {
        modifier(
            TierLockBadgeModifier(
                feature: GatedFeature.gatedFeature(id),
                tier: tier,
                placement: placement
            )
        )
    }
}

// MARK: - Previews

#Preview("Feature Unlock Sheet — Agent Control") {
    FeatureUnlockSheet(feature: GatedFeature.gatedFeature(.agentControl))
}

#Preview("Feature Unlock Sheet — Data Vault") {
    FeatureUnlockSheet(feature: GatedFeature.gatedFeature(.dataVault))
}

#Preview("Feature Locked Veil — Floo") {
    FeatureLockedVeil(feature: GatedFeature.gatedFeature(.floo)) {
        VStack(spacing: 14) {
            ForEach(0..<4) { _ in
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignSystem.Colors.surface)
                    .frame(height: 72)
            }
        }
        .padding(20)
    }
    .frame(width: 640, height: 620)
}

#Preview("Tier Lock Badges") {
    ZStack {
        ProTheme.Palette.obsidian.ignoresSafeArea()
        VStack(alignment: .leading, spacing: 18) {
            TierLockBadge(tier: .cloud)
            TierLockBadge(tier: .pro)
            TierLockBadge(tier: .ultra)
        }
        .padding(40)
    }
    .frame(width: 320, height: 240)
}
