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

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            if let cloud = plan(title: "BurnBar Cloud") {
                CloudTierCard(
                    plan: cloud,
                    priceText: store.displayPrice(for: cloud),
                    features: CloudTierCard.features(for: .cloud),
                    isFlagship: false,
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
                    features: CloudTierCard.features(for: .pro),
                    isFlagship: true,
                    billingPeriod: billingPeriod,
                    isPurchasing: store.isPurchasing
                ) {
                    Haptics.medium()
                    Task { await store.purchase(productID: pro.id) }
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

struct CloudTierCard: View {
    enum Tier { case cloud, pro }

    let plan: OpenBurnBarStoreProduct
    let priceText: String
    let features: [String]
    let isFlagship: Bool
    let billingPeriod: CloudBillingPeriod
    let isPurchasing: Bool
    let onSubscribe: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                icon: isFlagship ? "crown.fill" : "sparkles",
                isLoading: isPurchasing,
                action: onSubscribe
            )
            .padding(.top, MobileTheme.Spacing.xs)
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(flagshipGlow)
        .membershipCard(strokeWidth: isFlagship ? 1.4 : 1.0)
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

    private var header: some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
            Image(isFlagship ? "CloudTierCrestPro" : "CloudTierCrest")
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
                Text(isFlagship ? "The complete control plane" : "Your agent memory, everywhere")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Membership.engravingSoft)
            }
            Spacer(minLength: 0)
            if isFlagship {
                MembershipSeal(text: "MOST POWERFUL", systemImage: "crown.fill", prominent: true)
            }
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
        if !isFlagship {
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
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            ForEach(features, id: \.self) { feature in
                HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(ProTheme.Membership.foilLeaf)
                        .padding(.top, 1)
                    Text(feature)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(ProTheme.Membership.engraving)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var ctaTitle: String {
        isFlagship ? "Go Pro" : "Become a Member"
    }

    private var accessibilityText: String {
        "\(plan.title), \(billingPeriod.title), \(priceText) \(billingPeriod.priceSuffix). \(plan.included) \(plan.disclosure)"
    }

    static func features(for tier: Tier) -> [String] {
        switch tier {
        case .cloud:
            return [
                "Cross-device sync & encrypted history backup",
                "Cloud search across every agent run",
                "Hosted Intelligence Brief fallback",
                "Hermes remote relay & Hosted Remote MCP"
            ]
        case .pro:
            return [
                "Everything in BurnBar Cloud",
                "Floo live phone-to-Mac control & calls",
                "Supervised Agent Control + 500 hosted actions",
                "50 relay GB, file transfer & shared clipboard"
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
