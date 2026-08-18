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
                    .font(MobileScaledFont.system(size: 12, weight: .bold, design: .rounded))
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
                        .font(MobileScaledFont.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(isSelected ? ProTheme.Membership.letterpress : ProTheme.Membership.foilLeaf)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(isSelected ? AnyShapeStyle(ProTheme.Membership.foilEdge) : AnyShapeStyle(ProTheme.Membership.foilLeaf.opacity(0.16)))
                        )
                        .overlay(
                            HoloSheenSweep(
                                tint: ProTheme.Membership.foilHighlight,
                                period: 6.4,
                                bandOpacity: 0.5
                            )
                            .clipShape(Capsule(style: .continuous))
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
                    isPurchasing: store.isPurchasing,
                    monthlyEquivalentText: store.monthlyEquivalentDisplayPrice(for: cloud),
                    annualFreeMonths: annualFreeMonths(title: "BurnBar Cloud")
                ) {
                    // FoilCTAButton owns the tactile (it fires Haptics.medium()).
                    Task { await store.purchase(productID: cloud.id) }
                }
            }

            if let pro = plan(title: "BurnBar Cloud Pro") {
                CloudTierCard(
                    plan: pro,
                    priceText: store.displayPrice(for: pro),
                    tier: .pro,
                    billingPeriod: billingPeriod,
                    isPurchasing: store.isPurchasing,
                    monthlyEquivalentText: store.monthlyEquivalentDisplayPrice(for: pro),
                    annualFreeMonths: annualFreeMonths(title: "BurnBar Cloud Pro")
                ) {
                    // FoilCTAButton owns the tactile (it fires Haptics.medium()).
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
                    isPurchasing: store.isPurchasing,
                    monthlyEquivalentText: store.monthlyEquivalentDisplayPrice(for: ultra),
                    annualFreeMonths: annualFreeMonths(title: "BurnBar Cloud Ultra")
                ) {
                    // FoilCTAButton owns the tactile (it fires Haptics.medium()).
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

    /// Whole months the annual plan hands back versus monthly billing, for
    /// the "(N) MONTHS FREE" seal. `nil` outside the annual period or when
    /// the saving comes to less than one month.
    private func annualFreeMonths(title: String) -> Int? {
        guard billingPeriod == .annual,
              let monthly = OpenBurnBarProductCatalog.subscriptions.first(where: { $0.title == title && $0.cadence == "Monthly" }),
              let annual = OpenBurnBarProductCatalog.subscriptions.first(where: { $0.title == title && $0.cadence == "Annual" })
        else { return nil }
        return store.annualFreeMonths(monthly: monthly, annual: annual)
    }
}

// MARK: - Tier Card

/// The tier card's living crest — the artwork floats gently on a breathing
/// per-tier iridescent halo, so every card carries a quiet pulse of life
/// without competing with its copy. Static under reduce-motion.
private struct TierCrestEmblem: View {
    let imageName: String
    let gradient: LinearGradient
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(gradient)
                .frame(width: 58, height: 58)
                .blur(radius: 16)
                .opacity(breathe ? 0.42 : 0.20)
            Image(imageName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 52, height: 52)
                .shadow(color: accent.opacity(0.45), radius: breathe ? 9 : 5, y: 2)
                .offset(y: breathe ? -1.5 : 1.5)
        }
        .frame(width: 56, height: 56)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.8).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

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
    /// "≈ $20.75" per-month equivalent, shown beneath an annual price.
    var monthlyEquivalentText: String?
    /// Whole months effectively free vs monthly billing ("2 MONTHS FREE" seal).
    var annualFreeMonths: Int?
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
            .accessibilityIdentifier("cloudStore.tier.\(plan.id).subscribe")
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(flagshipGlow)
        .membershipCard(enableShimmer: false, strokeWidth: isFlagship ? 1.4 : 1.0)
        .overlay(holographicAccent)
        .overlay(flagshipChromaticRim)
        // Keep the purchase button as its own accessibility element. Combining
        // the whole card collapses the CTA into static card copy on iPad and
        // prevents VoiceOver and UI automation from activating the purchase.
        .accessibilityElement(children: .contain)
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
        // Concentrate the ghost behind the header and fade it out before the
        // benefit list so the copy never sits on a busy iridescent field.
        .mask(
            LinearGradient(
                colors: [.white, .white.opacity(0.0)],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.66)
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous))
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A faint per-tier iridescent rim layered over the foil stroke — only the
    /// power tiers wear it, so Pro and Ultra read as the chromatic flagships
    /// at a glance.
    @ViewBuilder
    private var flagshipChromaticRim: some View {
        if isFlagship {
            RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous)
                .stroke(holoGradient, lineWidth: 1.1)
                .opacity(0.4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The shared `CloudTier` palette equivalent of this card's tier.
    private var cloudTier: CloudTier {
        switch tier {
        case .cloud: return .cloud
        case .pro:   return .pro
        case .ultra: return .ultra
        }
    }

    /// Per-tier iridescent palette mirroring the website's `--holo-grad`.
    private var holoGradient: LinearGradient { cloudTier.holoGradient }

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
            TierCrestEmblem(
                imageName: crestImageName,
                gradient: holoGradient,
                accent: cloudTier.holoStops.first ?? ProTheme.Membership.foilLeaf
            )
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
        let priceFont = MobileScaledFont.system(size: 34, weight: .heavy, design: .serif, relativeTo: .largeTitle)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(priceText)
                    .font(priceFont)
                    .foregroundStyle(ProTheme.Membership.engraving)
                    .overlay(
                        ProTheme.Membership.foilEdge
                            .mask(Text(priceText).font(priceFont))
                            .opacity(0.45)
                    )
                Text(billingPeriod.priceSuffix)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(ProTheme.Membership.engravingSoft)
                Spacer(minLength: 0)
                if billingPeriod == .annual {
                    MembershipSeal(text: annualSealText)
                }
            }
            if billingPeriod == .annual, let monthlyEquivalentText {
                Text("≈ \(monthlyEquivalentText) / month, billed once a year")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(ProTheme.Membership.engravingSoft)
            }
        }
    }

    /// "2 MONTHS FREE" when the annual maths really hands back whole months;
    /// the generic value seal otherwise. Derived from live or catalog prices —
    /// never asserted. Static + internal so tests pin the copy selection.
    static func annualSealText(freeMonths: Int?) -> String {
        guard let freeMonths else { return "BEST VALUE" }
        return freeMonths == 1 ? "1 MONTH FREE" : "\(freeMonths) MONTHS FREE"
    }

    private var annualSealText: String { Self.annualSealText(freeMonths: annualFreeMonths) }

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
                            .font(MobileScaledFont.system(size: 14, weight: .bold))
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
                                 text: "Every conversation synced & backed up, encrypted — ready on all your devices"),
                CloudTierBenefit(icon: "magnifyingglass",
                                 text: "Find any answer from weeks ago — cloud search across every run"),
                CloudTierBenefit(icon: "newspaper.fill",
                                 text: "Your Intelligence Brief keeps arriving, even while your Mac sleeps"),
                CloudTierBenefit(icon: "antenna.radiowaves.left.and.right",
                                 text: "Hermes remote relay & Hosted Remote MCP, from anywhere")
            ]
        case .pro:
            return [
                CloudTierBenefit(icon: "infinity",
                                 text: "Everything in BurnBar Cloud"),
                CloudTierBenefit(icon: "laptopcomputer.and.iphone",
                                 text: "Floo: see, touch, and run your Mac live from your phone — calls included"),
                CloudTierBenefit(icon: "cpu.fill",
                                 text: "Supervised Agent Control — every step in plain sight, 500 hosted actions"),
                CloudTierBenefit(icon: "arrow.up.arrow.down",
                                 text: "Files & one shared clipboard across devices, plus 50 GB of Floo relay")
            ]
        case .ultra:
            return [
                CloudTierBenefit(icon: "infinity",
                                 text: "Everything in BurnBar Cloud Pro"),
                CloudTierBenefit(icon: "brain.head.profile",
                                 text: "10× agent memory: 100 sources · 500,000 chunks · 10 GB"),
                CloudTierBenefit(icon: "lock.shield.fill",
                                 text: "Sealed on-device — hosted recall is opt-in, and structural patterns stay visible"),
                CloudTierBenefit(icon: "arrow.up.arrow.down",
                                 text: "Same hosted Agent Control & relay allowance as Pro")
            ]
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
                Text("Top-ups unlock after BurnBar Cloud Pro or Ultra is active.")
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
                            .font(MobileScaledFont.system(size: 12, weight: .bold))
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
                        .font(MobileScaledFont.system(size: 18, weight: .bold, design: .serif))
                        .foregroundStyle(ProTheme.Membership.engraving)
                    Image(systemName: "plus.circle.fill")
                        .font(MobileScaledFont.system(size: 14, weight: .bold))
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
        switch catalogProduct.topUpKind {
        case "floo_relay_50gb":
            return "CloudChipFloo"
        case "elder_wand_searches_100", "elder_wand_searches_500":
            return "CloudCapSessionSearch"
        default:
            return "CloudChipAgent"
        }
    }
}
