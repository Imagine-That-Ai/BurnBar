import FirebaseCore
import OpenBurnBarKernel
import OpenBurnBarUI
import StoreKit
import SwiftUI

// MARK: - Trust

struct CloudStoreTrustCard: View {
    private let bullets: [(art: String, title: String, detail: String)] = [
        ("CloudSealApple", "Apple-verified", "Every transaction JWS is checked against Apple's root certificates server-side."),
        ("CloudSealUID", "UID-bound", "Each purchase is bound to your Firebase UID via a signed appAccountToken."),
        ("CloudSealCancel", "Cancel anytime", "Managed by Apple in Settings → Apple ID. We never store payment details.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("THE TRUST MODEL")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(2.4)
                .foregroundStyle(MobileTheme.ember)

            ForEach(bullets, id: \.title) { item in
                HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                    Image(item.art)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(item.detail)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                Link(destination: URL(staticString: "https://burnbar.ai/pricing")) {
                    HStack(spacing: 6) {
                        Text("Read the BurnBar Cloud pricing details")
                        Image(systemName: "arrow.up.right.square.fill")
                    }
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.ember)
                }
                CloudStoreLegalLinks(alignment: .leading)
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MercuryFoilCardModifier())
    }
}

// MARK: - Subscription Details (free state — Apple disclosure)

struct CloudStoreSubscriptionDetails: View {
    let priceText: String

    private var rows: [(String, String)] {
        [
            ("Service", CloudSubscriptionDisclosure.title),
            ("Length", CloudSubscriptionDisclosure.period),
            ("Price", "\(priceText) per month"),
            ("Includes", CloudSubscriptionDisclosure.included),
            ("Available subscriptions", CloudSubscriptionDisclosure.reviewVisiblePlanSummary),
            ("Billing", CloudSubscriptionDisclosure.billing)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            Text("SUBSCRIPTION DETAILS")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.bold)
                .tracking(1.2)
                .foregroundStyle(MobileTheme.ember)

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0)
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                            .tracking(0.4)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Text(row.1)
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CloudStoreLegalLinks(alignment: .leading, verboseLabels: true)
                    .padding(.top, MobileTheme.Spacing.xs)
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MercuryFoilCardModifier())
        .accessibilityIdentifier("cloudStore.subscriptionDisclosure")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Subscription details. \(CloudSubscriptionDisclosure.title). \(CloudSubscriptionDisclosure.period). \(priceText) per month. Includes \(CloudSubscriptionDisclosure.included) \(CloudSubscriptionDisclosure.billing)")
    }
}

// MARK: - Action Bar (free state)

struct CloudStoreActionBar: View {
    @Bindable var store: HostedQuotaSubscriptionStore
    let isSignedIn: Bool
    let onSignInRequired: () -> Void

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            Button {
                Haptics.medium()
                Task { await store.purchase() }
            } label: {
                HStack(spacing: MobileTheme.Spacing.sm) {
                    if store.isPurchasing {
                        MiningPickLoader(.inline, tint: MobileTheme.Colors.textPrimary)
                    } else {
                        Image(systemName: "creditcard.fill")
                            .font(MobileTheme.Typography.headline)
                    }
                    Text(primaryButtonTitle)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.aurora(.primary, fullWidth: true))
            .disabled(store.isPurchasing)
            .accessibilityIdentifier("cloudStore.subscribe.summary")
            .accessibilityLabel(primaryButtonTitle)

            if let error = store.error {
                CloudStoreErrorCard(message: error)
                    .accessibilityIdentifier("cloudStore.purchaseError")
            }

            Button {
                guard isSignedIn else {
                    onSignInRequired()
                    return
                }
                Task { await store.restorePurchases() }
            } label: {
                HStack(spacing: MobileTheme.Spacing.sm) {
                    Image(systemName: "arrow.clockwise")
                    Text("Restore Purchases")
                }
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
            }
            .buttonStyle(.aurora(.secondary, fullWidth: true))
            .disabled(store.isLoading || store.isPurchasing)
            .accessibilityIdentifier("cloudStore.restore")

            CloudStoreLegalLinks(alignment: .center, verboseLabels: true)
        }
        .padding(MobileTheme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(ProTheme.Membership.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(ProTheme.Membership.foilEdge, lineWidth: 1)
        )
        .shadow(color: ProTheme.Membership.foilLeaf.opacity(0.18), radius: 18, y: 10)
    }

    private var primaryButtonTitle: String {
        if store.isPurchasing {
            return "Purchasing..."
        }
        guard let product = store.product else {
            return "Subscribe with App Store"
        }
        return "Subscribe for \(product.displayPrice) / month"
    }
}

// MARK: - Legal Links

private struct CloudStoreLegalLinks: View {
    enum AlignmentMode: Equatable {
        case center
        case leading
        case trailing
    }

    var alignment: AlignmentMode = .center
    var verboseLabels = false

    var body: some View {
        HStack(spacing: 8) {
            Link(verboseLabels ? "Privacy Policy" : "Privacy", destination: CloudStoreLegalURLs.privacy)
                .accessibilityIdentifier("cloudStore.privacyPolicyLink")
            Text("·")
                .foregroundStyle(MobileTheme.Colors.textPrimary.opacity(0.5))
            Link(verboseLabels ? "Terms of Use (EULA)" : "Terms", destination: CloudStoreLegalURLs.terms)
                .accessibilityIdentifier("cloudStore.termsOfUseLink")
        }
        .font(MobileTheme.Typography.tiny)
        .foregroundStyle(MobileTheme.ember)
        .frame(maxWidth: alignment == .trailing ? nil : .infinity,
               alignment: stackAlignment)
        .accessibilityElement(children: .contain)
    }

    private var stackAlignment: Alignment {
        switch alignment {
        case .center:   return .center
        case .leading:  return .leading
        case .trailing: return .trailing
        }
    }
}

// MARK: - Member Card
//
// The "certificate" surface. Renders for active subscribers. Mercury foil
// border, animated shimmer + amber sparks, member-since date, manage +
// restore actions. Kept from the previous design — already lives in the
// Pro vocabulary.

struct CloudStoreMemberCard: View {
    @Bindable var store: HostedQuotaSubscriptionStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var showBadgePicker = false
    @State private var badgeBreathe = false

    /// The member's holographic tier for accents — and for the chip label,
    /// which never overstates: base Cloud members wear CLOUD, not PRO.
    /// Delegates to the store's canonical §4.2 tier resolution.
    private var memberTier: CloudTier { store.cloudTier }

    private var memberTierLabel: String {
        switch memberTier {
        case .ultra:        return "ULTRA"
        case .pro:          return "PRO"
        case .none, .cloud: return "CLOUD"
        }
    }

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            // Aurora burst membership card — vivid multi-stop gradient,
            // animated aurora ribbon, helmet sitting in a halo. Matches the
            // YouTab member row, just turned up for the destination.
            ZStack(alignment: .top) {
                memberAuroraBackdrop

                VStack(spacing: MobileTheme.Spacing.lg) {
                    Button {
                        Haptics.selection()
                        showBadgePicker = true
                    } label: {
                        // The badge floats on a breathing tier-colored halo —
                        // the certificate's living centerpiece.
                        ZStack {
                            Circle()
                                .fill(memberTier.holoGradient)
                                .frame(width: 96, height: 96)
                                .blur(radius: 26)
                                .opacity(badgeBreathe ? 0.55 : 0.30)
                                .scaleEffect(badgeBreathe ? 1.08 : 0.92)
                            CloudBadge(size: .large)
                                .offset(y: badgeBreathe ? -2 : 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Change Cloud badge")
                    .padding(.top, MobileTheme.Spacing.xl)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 4.2).repeatForever(autoreverses: true)) {
                            badgeBreathe = true
                        }
                    }

                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Text(memberTierLabel)
                                .font(MobileScaledFont.system(size: 12, weight: .heavy, design: .rounded))
                                .tracking(1.8)
                                .foregroundStyle(ProTheme.Membership.letterpress)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(memberTier.holoGradient))
                                .overlay(
                                    HoloSheenSweep(tint: .white, period: 6.0, bandOpacity: 0.5)
                                        .clipShape(Capsule(style: .continuous))
                                )
                            Text("OPENBURNBAR CLOUD")
                                .font(MobileTheme.Typography.tiny)
                                .fontWeight(.heavy)
                                .tracking(2.4)
                                .foregroundStyle(ProTheme.Membership.foilLeaf)
                        }
                        Text("Member")
                            .font(ProTheme.Typography.displaySerif)
                            .foregroundStyle(ProTheme.Membership.engraving)
                            .overlay(
                                ProTheme.Membership.foilEdge
                                    .mask(Text("Member").font(ProTheme.Typography.displaySerif))
                                    .opacity(0.5)
                            )
                    }

                    statusRow
                    if let serial = memberSerialText {
                        serialChip(serial)
                    }
                }
                .padding(.horizontal, MobileTheme.Spacing.xl)
                .padding(.bottom, MobileTheme.Spacing.xl)
                .frame(maxWidth: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(ProTheme.Membership.foilEdge, lineWidth: 1.4)
            )
            .shadow(color: ProTheme.Membership.foilLeaf.opacity(0.32), radius: 28, y: 14)
            .shadow(color: Color.black.opacity(0.22), radius: 18, y: 8)

            // "Change badge" link — quiet, unobtrusive. Tapping the badge
            // itself also opens the picker; this is the labelled affordance
            // for discoverability.
            Button {
                Haptics.selection()
                showBadgePicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rosette")
                        .font(MobileScaledFont.system(size: 13, weight: .semibold))
                    Text("Change badge")
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(ProTheme.Membership.foilLeaf)
            }
            .buttonStyle(.plain)

            actionRow
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .sheet(isPresented: $showBadgePicker) {
            NavigationStack {
                CloudBadgePicker()
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var memberAuroraBackdrop: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(ProTheme.Membership.surface)
            // Foil-leaf wash for depth — gold in light, platinum in dark.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            ProTheme.Membership.foilLeaf.opacity(0.22),
                            ProTheme.Membership.surfaceElevated.opacity(0.0),
                            ProTheme.Membership.foilHighlight.opacity(0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            // The member's tier crest as a faint iridescent ghost behind the
            // certificate header — replaces the old hard-edged foil band.
            HolographicCrestAura(
                crestImageName: memberTier.crestAssetName,
                gradient: memberTier.holoGradient,
                intensity: .card
            )
            .mask(
                LinearGradient(
                    colors: [.white, .white.opacity(0.0)],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.72)
                )
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            // Living dust + a slow glint across the whole certificate.
            HoloSparksOverlay(colors: memberTier.holoStops)
            HoloSheenSweep(tint: .white, period: 7.5, bandOpacity: 0.16)
            // Halo behind the crest.
            RadialGradient(
                colors: [
                    ProTheme.Membership.foilHighlight.opacity(0.40),
                    UnifiedDesignSystem.Colors.ember.opacity(0.18),
                    Color.clear
                ],
                center: UnitPoint(x: 0.5, y: 0.30),
                startRadius: 0,
                endRadius: 220
            )
            .blendMode(.plusLighter)
        }
    }

    /// Single warm status pill — renews relative for near-term, absolute
    /// month/year for far-horizon / sentinel dates so we never display
    /// "Renews in 73 years".
    private var statusRow: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .font(MobileScaledFont.system(size: 13, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.success)
            Text("Active")
                .font(MobileTheme.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("·")
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text(renewLine)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(
            Capsule(style: .continuous)
                .fill(MobileTheme.Colors.success.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(MobileTheme.Colors.success.opacity(0.35), lineWidth: 0.5)
        )
    }

    /// Quiet subscription serial — small, monospaced, paired with a seal
    /// glyph. Reads as a real receipt line, not a costume.
    private func serialChip(_ serial: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.shield")
                .font(MobileScaledFont.system(size: 12, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text(serial)
                .font(MobileTheme.Typography.monoTiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
    }

    private var actionRow: some View {
        // Both actions wear the membership vocabulary — the foil CTA and a
        // quiet engraved secondary — instead of the utilitarian Aurora
        // buttons, so the certificate stays one coherent object.
        HStack(spacing: MobileTheme.Spacing.md) {
            FoilCTAButton(title: "Manage", icon: "creditcard.fill") {
                openURL(URL(staticString: "https://apps.apple.com/account/subscriptions"))
            }
            .accessibilityLabel("Manage subscription in App Store")

            Button {
                Task { await store.restorePurchases() }
            } label: {
                HStack(spacing: 6) {
                    if store.isLoading {
                        MiningPickLoader(.inline, tint: ProTheme.Membership.engraving)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(MobileScaledFont.system(size: 14, weight: .semibold))
                    }
                    Text("Restore")
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(ProTheme.Membership.engraving)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MobileTheme.Spacing.md + 2)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .fill(ProTheme.Membership.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(ProTheme.Membership.foilEdge, lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
            .accessibilityIdentifier("cloudStore.member.restore")
            .accessibilityLabel("Restore purchases")
            .settingsAnchor(SettingsAnchor.cloudRestore)
        }
    }

    // MARK: - Derived strings

    private var renewLine: String {
        guard let expiration = store.expirationDate else { return "Renews monthly" }
        let interval = expiration.timeIntervalSinceNow
        if interval > 0, interval < 90 * 24 * 60 * 60 {
            return "Renews \(expiration.formatted(.relative(presentation: .named)))"
        }
        return "Renews monthly · through \(expiration.formatted(.dateTime.month(.abbreviated).year()))"
    }

    /// Real receipt-style serial drawn from the StoreKit transaction id.
    /// `nil` when we don't have a transaction yet (server-only restore,
    /// previews) — so we never invent a fake number.
    private var memberSerialText: String? {
        guard let tx = store.latestTransactionID else { return nil }
        let raw = String(tx)
        let suffix = String(raw.suffix(8))
        let padded = String(repeating: "0", count: max(0, 8 - suffix.count)) + suffix
        let grouped = padded.enumerated().map { idx, ch in
            (idx > 0 && idx % 4 == 0 ? "·" : "") + String(ch)
        }.joined()
        return "Receipt · \(grouped)"
    }

    private var accessibilitySummary: String {
        var parts: [String] = ["OpenBurnBar Cloud member"]
        parts.append(renewLine)
        if let purchase = store.purchaseDate {
            let fmt = purchase.formatted(.dateTime.month(.wide).year())
            parts.append("Member since \(fmt)")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Error Card

struct CloudStoreErrorCard: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.error)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(MobileTheme.Colors.error)
        }
        .padding(MobileTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.Colors.error.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .stroke(MobileTheme.Colors.error.opacity(0.45), lineWidth: 0.5)
        )
    }
}

// MARK: - Previews

#Preview("Locked") {
    NavigationStack {
        CloudStoreView()
    }
}
