import SwiftUI
import OpenBurnBarCore

// MARK: - Cloud Tier Components (free state)
//
// The redesigned plan surface for the Cloud destination. Replaces the flat
// four-row list with a billing-period toggle, two membership "tier cards"
// (Cloud + the flagship Cloud Pro), and a refined à-la-carte top-up strip.
//
// All product data is sourced unchanged from `OpenBurnBarProductCatalog`;
// purchases call `store.purchase(productID:)` exactly as before. The chrome
// is the adaptive `membershipCard` (obsidian foil in dark, gold-leaf
// letterpress in light).

enum CloudBillingPeriod: String, CaseIterable, Identifiable, Hashable {
    case monthly
    case annual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthly: return "Monthly"
        case .annual:  return "Annual"
        }
    }

    var cadenceMatch: String {
        switch self {
        case .monthly: return "Monthly"
        case .annual:  return "Annual"
        }
    }

    /// Per-period suffix shown beside the price numeral.
    var priceSuffix: String {
        switch self {
        case .monthly: return "/ month"
        case .annual:  return "/ year"
        }
    }
}

// MARK: - Billing Period Toggle

struct CloudBillingPeriodToggle: View {
    @Binding var period: CloudBillingPeriod

    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("CHOOSE YOUR MEMBERSHIP")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
                    .tracking(2.4)
                    .foregroundStyle(ProTheme.Membership.foilLeaf)
                Spacer(minLength: 0)
                Text("APPLE BILLING")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(ProTheme.Membership.engraving)
                    .background(Capsule().fill(ProTheme.Membership.surfaceElevated))
                    .overlay(Capsule().stroke(ProTheme.Membership.foilLeaf.opacity(0.45), lineWidth: 0.7))
            }

            HStack(spacing: 4) {
                ForEach(CloudBillingPeriod.allCases) { option in
                    segment(option)
                }
            }
            .padding(4)
            .background(
                Capsule(style: .continuous)
                    .fill(ProTheme.Membership.surfaceElevated)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(ProTheme.Membership.foilEdge, lineWidth: 0.8)
            )
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: CloudBillingPeriod) -> some View {
        let isSelected = period == option
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : MobileTheme.Animation.snappy) {
                period = option
            }
        } label: {
            HStack(spacing: 6) {
                Text(option.title)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                if option == .annual {
                    Text("SAVE 17%")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(isSelected ? ProTheme.Membership.surface : ProTheme.Membership.foilLeaf)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(isSelected ? AnyShapeStyle(ProTheme.Membership.foilEdge) : AnyShapeStyle(ProTheme.Membership.foilLeaf.opacity(0.16)))
                        )
                }
            }
            .foregroundStyle(isSelected ? ProTheme.Membership.engraving : ProTheme.Membership.engravingMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(ProTheme.Membership.surface)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(ProTheme.Membership.foilEdge, lineWidth: 1)
                            )
                            .matchedGeometryEffect(id: "billingIndicator", in: indicator)
                            .shadow(color: ProTheme.Membership.foilLeaf.opacity(0.20), radius: 8, y: 3)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title) billing\(option == .annual ? ", save 17 percent" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Tier Lineup

struct CloudTierLineup: View {
    @Bindable var store: HostedQuotaSubscriptionStore
    let billingPeriod: CloudBillingPeriod
    var showsCloudPlan = true

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            if showsCloudPlan, let cloud = plan(title: "BurnBar Cloud") {
                CloudTierCard(
                    plan: cloud,
                    priceText: store.displayPrice(for: cloud),
                    tier: .cloud,
                    billingPeriod: billingPeriod,
                    isPurchasing: store.isPurchasing
                ) {
                    Haptics.medium()
                    Task { await store.purchase(productID: cloud.id) }
                }
            }

            if let pro = plan(title: "BurnBar Cloud Pro") {
                CloudTierCard(
                    plan: pro,
                    priceText: store.displayPrice(for: pro),
                    tier: .pro,
                    billingPeriod: billingPeriod,
                    isPurchasing: store.isPurchasing
                ) {
                    Haptics.medium()
                    Task { await store.purchase(productID: pro.id) }
                }
            }

            // Cloud Ultra — the flagship top tier, mirrors the marketing site's
            // fourth plan. Rendered after Cloud Pro so the lineup reads
            // Cloud → Pro → Ultra in ascending order.
            if let ultra = plan(title: "BurnBar Cloud Ultra") {
                CloudTierCard(
                    plan: ultra,
                    priceText: store.displayPrice(for: ultra),
                    tier: .ultra,
                    billingPeriod: billingPeriod,
                    isPurchasing: store.isPurchasing
                ) {
                    Haptics.medium()
                    Task { await store.purchase(productID: ultra.id) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func plan(title: String) -> OpenBurnBarStoreProduct? {
        OpenBurnBarProductCatalog.subscriptions.first {
            $0.title == title && $0.cadence == billingPeriod.cadenceMatch
        }
    }
}

// MARK: - Tier Card

/// One delineated benefit row on a tier card — a meaningful glyph paired with
/// its promise. The icon gives each benefit a distinct silhouette so the value
/// stack reads as four concrete capabilities, not an undifferentiated checklist.
struct CloudTierBenefit: Identifiable {
    let icon: String
    let text: String
    var id: String { text }
}

struct CloudTierCard: View {
    enum Tier { case cloud, pro, ultra }

    let plan: OpenBurnBarStoreProduct
    let priceText: String
    let tier: Tier
    let billingPeriod: CloudBillingPeriod
    let isPurchasing: Bool
    let onSubscribe: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cloud Pro and Cloud Ultra are the "flagship" power tiers — they wear the
    /// heavier foil stroke and the flagship interior glow.
    private var isFlagship: Bool { tier != .cloud }

    private var features: [CloudTierBenefit] { CloudTierCard.features(for: tier) }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            header
            priceRow
            trialRibbon
            Divider().overlay(ProTheme.Membership.hairline.opacity(0.35))
            featureList
            FoilCTAButton(
                title: ctaTitle,
                subtitle: "\(priceText) \(billingPeriod.priceSuffix)",
                icon: ctaIcon,
                isLoading: isPurchasing,
                action: onSubscribe
            )
            .padding(.top, MobileTheme.Spacing.xs)
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(flagshipGlow)
        .membershipCard(strokeWidth: isFlagship ? 1.4 : 1.0)
        .overlay(holographicAccent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("cloudStore.tier.\(plan.id)")
    }

    @ViewBuilder
    private var flagshipGlow: some View {
        if isFlagship && !reduceMotion {
            Rectangle()
                .fill(ProTheme.Membership.flagshipGlow)
                .blur(radius: 8)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Holographic accent
    //
    // Every paid tier wears a faint iridescent ghost of its own crest — the
    // signature "holographic" look from the marketing site (`--holo-grad`). The
    // crest art is used as an alpha mask over a per-tier multi-stop gradient and
    // composited with `.plusLighter` at very low opacity, so it reads as a shiny
    // silhouette sheen on the card while keeping every line of copy fully
    // legible. The look is fully static, so it respects reduce-motion by design.
    @ViewBuilder
    private var holographicAccent: some View {
        HolographicCrestAura(
            crestImageName: crestImageName,
            gradient: holoGradient,
            intensity: .card
        )
        .clipShape(RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous))
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Per-tier iridescent palette mirroring the website's `--holo-grad`.
    private var holoGradient: LinearGradient {
        let stops: [Color]
        switch tier {
        case .cloud:
            // Warm ember.
            stops = [Color(hex: "FFD56B"), Color(hex: "FF8A3D"), Color(hex: "FF5C8A"), Color(hex: "B06BFF")]
        case .pro:
            // Cool aqua.
            stops = [Color(hex: "5EF0C9"), Color(hex: "38D6F3"), Color(hex: "4F8BFF"), Color(hex: "8EF0A8")]
        case .ultra:
            // Full-spectrum premium.
            stops = [Color(hex: "FFD56B"), Color(hex: "7DD3FC"), Color(hex: "C084FC"), Color(hex: "5EEAD4"), Color(hex: "FF9EC7")]
        }
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var crestImageName: String {
        switch tier {
        case .cloud: return "CloudTierCrest"
        case .pro:   return "CloudTierCrestPro"
        case .ultra: return "CloudTierCrestUltra"
        }
    }

    private var headerSubtitle: String {
        switch tier {
        case .cloud: return "Your agent memory, everywhere"
        case .pro:   return "The complete control plane"
        case .ultra: return "10× private agent memory"
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
            Image(crestImageName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 52, height: 52)
                .shadow(color: ProTheme.Membership.foilLeaf.opacity(0.35), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.title.replacingOccurrences(of: "BurnBar ", with: ""))
                    .font(ProTheme.Typography.titleSerif)
                    .foregroundStyle(ProTheme.Membership.engraving)
                    .fixedSize(horizontal: false, vertical: true)
                Text(headerSubtitle)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Membership.engravingSoft)
            }
            Spacer(minLength: 0)
            if let sealText = headerSealText {
                MembershipSeal(text: sealText, systemImage: "crown.fill", prominent: true)
            }
        }
    }

    /// Only the top tier wears the prominent crest seal so hierarchy reads at a
    /// glance: Cloud (none) → Pro ("MOST POWERFUL" no longer, see below) →
    /// Ultra ("ULTIMATE"). Pro keeps a quieter "MOST POWERFUL" seal so it still
    /// stands out from the base Cloud tier.
    private var headerSealText: String? {
        switch tier {
        case .cloud: return nil
        case .pro:   return "MOST POPULAR"
        case .ultra: return "ULTIMATE"
        }
    }

    private var priceRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(priceText)
                .font(.system(size: 34, weight: .heavy, design: .serif))
                .foregroundStyle(ProTheme.Membership.engraving)
                .overlay(
                    ProTheme.Membership.foilEdge
                        .mask(Text(priceText).font(.system(size: 34, weight: .heavy, design: .serif)))
                        .opacity(0.45)
                )
            Text(billingPeriod.priceSuffix)
                .font(MobileTheme.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(ProTheme.Membership.engravingSoft)
            Spacer(minLength: 0)
            if billingPeriod == .annual {
                MembershipSeal(text: "BEST VALUE")
            }
        }
    }

    @ViewBuilder
    private var trialRibbon: some View {
        // Only base Cloud carries the introductory free trial; Pro and Ultra
        // have no trial, matching the App Store Connect configuration.
        if tier == .cloud {
            HStack(spacing: 6) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("14-day free trial for new subscribers")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(ProTheme.Membership.foilLeaf)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm + 2) {
            ForEach(features) { benefit in
                HStack(alignment: .center, spacing: MobileTheme.Spacing.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(ProTheme.Membership.foilLeaf.opacity(0.16))
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(ProTheme.Membership.foilLeaf.opacity(0.30), lineWidth: 0.75)
                        Image(systemName: benefit.icon)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(ProTheme.Membership.foilLeaf)
                    }
                    .frame(width: 30, height: 30)
                    Text(benefit.text)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(ProTheme.Membership.engraving)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var ctaTitle: String {
        switch tier {
        case .cloud: return "Become a Member"
        case .pro:   return "Go Pro"
        case .ultra: return "Go Ultra"
        }
    }

    private var ctaIcon: String {
        switch tier {
        case .cloud: return "sparkles"
        case .pro:   return "crown.fill"
        case .ultra: return "sparkles.rectangle.stack.fill"
        }
    }

    private var accessibilityText: String {
        "\(plan.title), \(billingPeriod.title), \(priceText) \(billingPeriod.priceSuffix). \(plan.included) \(plan.disclosure)"
    }

    static func features(for tier: Tier) -> [CloudTierBenefit] {
        switch tier {
        case .cloud:
            return [
                CloudTierBenefit(icon: "arrow.triangle.2.circlepath",
                                 text: "Cross-device sync & encrypted history backup"),
                CloudTierBenefit(icon: "magnifyingglass",
                                 text: "Cloud search across every agent run"),
                CloudTierBenefit(icon: "newspaper.fill",
                                 text: "Hosted Intelligence Brief fallback"),
                CloudTierBenefit(icon: "antenna.radiowaves.left.and.right",
                                 text: "Hermes remote relay & Hosted Remote MCP")
            ]
        case .pro:
            return [
                CloudTierBenefit(icon: "infinity",
                                 text: "Everything in BurnBar Cloud"),
                CloudTierBenefit(icon: "laptopcomputer.and.iphone",
                                 text: "Floo live phone-to-Mac control & calls"),
                CloudTierBenefit(icon: "cpu.fill",
                                 text: "Supervised Agent Control + 500 hosted actions"),
                CloudTierBenefit(icon: "arrow.up.arrow.down",
                                 text: "50 relay GB, file transfer & shared clipboard")
            ]
        case .ultra:
            return [
                CloudTierBenefit(icon: "infinity",
                                 text: "Everything in BurnBar Cloud Pro"),
                CloudTierBenefit(icon: "brain.head.profile",
                                 text: "10× agent memory: 15 sources · 50,000 chunks · 250 MB"),
                CloudTierBenefit(icon: "lock.shield.fill",
                                 text: "Sealed on-device — hosted recall is opt-in, and structural patterns stay visible"),
                CloudTierBenefit(icon: "arrow.up.arrow.down",
                                 text: "Same hosted Agent Control & relay allowance as Pro")
            ]
        }
    }
}

// MARK: - Holographic Crest Aura
//
// The signature "holographic" accent. Fills the tier crest's silhouette with a
// per-tier iridescent gradient and floats it, very faintly, behind the card —
// an elegant shiny ghost of the logo. Mirrors the marketing site's
// `.plan__holo` (crest used as a mask over `--holo-grad`). The crest art is an
// opaque-knockout PNG, so we use it directly as the gradient's mask.
//
// Two intensities (reused by the feature-gating unlock experience):
//   • `.card` — opacity ~12%, no glow, the faint ghost behind a tier card.
//   • `.hero` — opacity ~0.4 with a soft per-tier glow, the glowing crest at
//     the top of the unlock sheet / locked-feature veil.
// The look is fully static, so it respects reduce-motion automatically.
struct HolographicCrestAura: View {
    enum Intensity {
        case card
        case hero

        var opacity: Double {
            switch self {
            case .card: return 0.14
            case .hero: return 0.42
            }
        }

        /// Soft outer glow radius (0 for the resting card aura).
        var glowRadius: CGFloat {
            switch self {
            case .card: return 0
            case .hero: return 26
            }
        }
    }

    let crestImageName: String
    let gradient: LinearGradient
    var intensity: Intensity = .card

    var body: some View {
        GeometryReader { geo in
            let crest = gradient
                .mask(
                    Image(crestImageName)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: geo.size.width * 1.32, height: geo.size.height * 1.32)
                        .position(x: geo.size.width * 0.5, y: geo.size.height * 0.42)
                )
                .saturation(1.2)
            ZStack {
                // Soft bloom underlay only in the hero variant — a diffuse
                // halo of the same iridescent crest so it *glows*.
                if intensity == .hero {
                    crest
                        .blur(radius: intensity.glowRadius)
                        .opacity(intensity.opacity * 0.8)
                }
                crest
                    .blur(radius: 0.5)
                    .opacity(intensity.opacity)
            }
        }
        .clipped()
    }
}

// MARK: - Tier holographic palette (shared)
//
// The per-tier iridescent `--holo-grad` mirrored from the marketing site,
// exposed so the unlock experience renders the *required* tier's hero crest
// with the exact same palette as that tier's store card.
extension CloudTier {
    /// Per-tier iridescent gradient mirroring the website's `--holo-grad`.
    var holoGradient: LinearGradient {
        let stops: [Color]
        switch self {
        case .none, .cloud:
            // Warm ember.
            stops = [Color(hex: "FFD56B"), Color(hex: "FF8A3D"), Color(hex: "FF5C8A"), Color(hex: "B06BFF")]
        case .pro:
            // Cool aqua.
            stops = [Color(hex: "5EF0C9"), Color(hex: "38D6F3"), Color(hex: "4F8BFF"), Color(hex: "8EF0A8")]
        case .ultra:
            // Full-spectrum premium.
            stops = [Color(hex: "FFD56B"), Color(hex: "7DD3FC"), Color(hex: "C084FC"), Color(hex: "5EEAD4"), Color(hex: "FF9EC7")]
        }
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The store-facing membership name shown on chips and CTAs. For the
    /// implicit floor tier (`.none`) this returns the entry tier's name so
    /// "Available on Cloud" never reads as "Available on ".
    var membershipName: String {
        switch self {
        case .none, .cloud: return "Cloud"
        case .pro: return "Cloud Pro"
        case .ultra: return "Cloud Ultra"
        }
    }
}

// MARK: - À-la-carte Top-Up Strip (free state)

struct CloudTopUpStrip: View {
    @Bindable var store: HostedQuotaSubscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("CLOUD PRO TOP-UPS")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
                    .tracking(2.4)
                    .foregroundStyle(ProTheme.Membership.foilLeaf)
                Spacer(minLength: 0)
                if !store.isActivePro {
                    Label("Unlocks with Pro", systemImage: "lock.fill")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(ProTheme.Membership.engravingMuted)
                }
            }

            HStack(spacing: MobileTheme.Spacing.md) {
                ForEach(OpenBurnBarProductCatalog.topUps) { topUp in
                    CloudTopUpChip(
                        catalogProduct: topUp,
                        priceText: store.displayPrice(for: topUp),
                        isDisabled: !store.isActivePro,
                        isPurchasing: store.isPurchasing
                    ) {
                        Haptics.medium()
                        Task { await store.purchase(productID: topUp.id) }
                    }
                }
            }

            if !store.isActivePro {
                Text("Top-ups unlock after BurnBar Cloud Pro is active.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Membership.engravingMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .membershipCard()
        .accessibilityElement(children: .contain)
    }
}

struct CloudTopUpChip: View {
    let catalogProduct: OpenBurnBarStoreProduct
    let priceText: String
    let isDisabled: Bool
    let isPurchasing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                HStack(alignment: .top) {
                    Image(artName)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 46, height: 46)
                        .opacity(isDisabled ? 0.5 : 1.0)
                        .saturation(isDisabled ? 0.0 : 1.0)
                    Spacer(minLength: 0)
                    if isDisabled {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ProTheme.Membership.engravingMuted)
                    }
                }
                Text(catalogProduct.title)
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(ProTheme.Membership.engraving)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(catalogProduct.cadence)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Membership.engravingSoft)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(priceText)
                        .font(.system(size: 18, weight: .bold, design: .serif))
                        .foregroundStyle(ProTheme.Membership.engraving)
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isDisabled ? ProTheme.Membership.engravingMuted : ProTheme.Membership.foilLeaf)
                }
                .padding(.top, 2)
            }
            .padding(MobileTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(ProTheme.Membership.surfaceElevated.opacity(isDisabled ? 0.5 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .stroke(ProTheme.Membership.foilLeaf.opacity(isDisabled ? 0.18 : 0.45), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing || isDisabled)
        .accessibilityIdentifier("cloudStore.product.\(catalogProduct.id)")
        .accessibilityLabel("\(catalogProduct.title), \(catalogProduct.cadence), \(priceText). \(catalogProduct.disclosure)")
    }

    private var artName: String {
        catalogProduct.topUpKind?.contains("floo") == true ? "CloudChipFloo" : "CloudChipAgent"
    }
}
