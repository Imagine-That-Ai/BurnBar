import SwiftUI
import StoreKit
import OpenBurnBarCore

// MARK: - Cloud Store View
//
// Premium paywall + member home for the OpenBurnBar Cloud subscription
// (Apple-verified `com.openburnbar.hostedQuotaSync.monthly`). Branded as
// "OpenBurnBar Cloud" in the chrome with the literal StoreKit product name
// shown small near the plan tiles for receipt parity.
//
// Surfaces:
//   • Locked  — hero, plan picker (Monthly active, Yearly "Coming soon"),
//               capability cards, comparison strip, trust footnote, action
//               bar (Subscribe + Restore).
//   • Member  — hero, member-status card with mercury shimmer + amber
//               sparks, capability cards (with active checks), comparison
//               strip, trust footnote, Manage + Restore.
//
// Reads the shared store from `@Environment(\.cloudSubscriptionStore)` when
// available; otherwise falls back to a screen-local instance (previews and
// any deep-link case where the screen is mounted before root injection).

struct CloudStoreView: View {

    var onClose: (() -> Void)? = nil

    @Environment(\.cloudSubscriptionStore) private var sharedStore
    @Environment(\.dismiss) private var dismiss
    @State private var localStore = HostedQuotaSubscriptionStore()
    @State private var didLoadLocal = false

    private var store: HostedQuotaSubscriptionStore {
        sharedStore ?? localStore
    }

    var body: some View {
        ZStack {
            EmberSurfaceBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: MobileTheme.Spacing.xl) {
                    CloudStoreHeroSection(store: store)
                        .staggeredEntrance(delay: 0.0)

                    if store.isActive {
                        CloudStoreMemberCard(store: store)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                            .staggeredEntrance(delay: 0.05)
                    } else {
                        CloudStorePlanPicker(store: store)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                            .staggeredEntrance(delay: 0.05)
                    }

                    CloudStoreCapabilitySection(isActive: store.isActive)
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .staggeredEntrance(delay: 0.10)

                    CloudStoreComparisonCard()
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .staggeredEntrance(delay: 0.15)

                    CloudStoreTrustCard()
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .staggeredEntrance(delay: 0.20)

                    if let error = store.error {
                        CloudStoreErrorCard(message: error)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.top, MobileTheme.Spacing.md)
                .padding(.bottom, store.isActive ? MobileTheme.Spacing.xl : 140)
            }

            if !store.isActive {
                CloudStoreActionBar(store: store)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .navigationTitle("OpenBurnBar Cloud")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if onClose != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onClose?()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .task {
            // Load only when we own the local instance; the shared store has
            // already been hydrated at root.
            if sharedStore == nil, !didLoadLocal {
                didLoadLocal = true
                await localStore.load()
            }
        }
        .animation(MobileTheme.Animation.gentle, value: store.isActive)
        .animation(MobileTheme.Animation.gentle, value: store.error)
    }
}

// MARK: - Hero Section

private struct CloudStoreHeroSection: View {
    let store: HostedQuotaSubscriptionStore

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            CloudHeroAnimation(size: 220)
                .padding(.top, MobileTheme.Spacing.lg)

            VStack(spacing: MobileTheme.Spacing.xs) {
                Text("OpenBurnBar")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(2.4)
                    .foregroundStyle(MobileTheme.Colors.textMuted)

                Text("Cloud")
                    .font(MobileTheme.Typography.displayLarge)
                    .fontWeight(.bold)
                    .foregroundStyle(MobileTheme.primaryGradient)
                    .accessibilityAddTraits(.isHeader)

                Text(store.isActive
                     ? "Quota in your pocket. Hermes anywhere. Backups for every byte."
                     : "Quota in your pocket. Hermes anywhere. Backups for every byte.")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, MobileTheme.Spacing.xl)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Plan Picker

private struct CloudStorePlanPicker: View {
    let store: HostedQuotaSubscriptionStore

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                CloudPlanTile(
                    kind: .monthly,
                    priceText: store.product?.displayPrice ?? "$2.99",
                    cadence: "/ month",
                    caption: "Most flexible",
                    isSelected: true,
                    isDisabled: false
                )

                CloudPlanTile(
                    kind: .yearly,
                    priceText: "—",
                    cadence: "Coming soon",
                    caption: "Save more, billed yearly",
                    isSelected: false,
                    isDisabled: true
                )
            }

            Text("Billed monthly through Apple — Hosted Quota Sync · Monthly. Cancel anytime in Settings → Apple ID.")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MobileTheme.Spacing.sm)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CloudPlanTile: View {
    enum Kind { case monthly, yearly }

    let kind: Kind
    let priceText: String
    let cadence: String
    let caption: String
    let isSelected: Bool
    let isDisabled: Bool

    private var title: String {
        switch kind {
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack(spacing: 6) {
                Text(title)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(0.8)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer(minLength: 0)
                if kind == .monthly {
                    Text("CURRENT")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(MobileTheme.Colors.success.opacity(0.18))
                        .foregroundStyle(MobileTheme.Colors.success)
                        .clipShape(Capsule())
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(priceText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        kind == .monthly
                            ? AnyShapeStyle(MobileTheme.primaryGradient)
                            : AnyShapeStyle(MobileTheme.Colors.textMuted)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if kind == .monthly {
                    Text(cadence)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }

            if kind == .yearly {
                Text(cadence)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }

            Text(caption)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MobileTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(planBackground)
        .overlay(planBorder)
        .opacity(isDisabled ? 0.6 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(kind == .yearly ? "Yearly plan coming soon" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityText: String {
        switch kind {
        case .monthly:
            return "Monthly plan, \(priceText) per month, currently selected"
        case .yearly:
            return "Yearly plan, coming soon"
        }
    }

    @ViewBuilder
    private var planBackground: some View {
        if kind == .monthly {
            ZStack {
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(MobileTheme.cardGradient)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(MobileTheme.Colors.surface.opacity(0.55))
                DiagonalHashOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))
                    .opacity(0.35)
            }
        }
    }

    @ViewBuilder
    private var planBorder: some View {
        if kind == .monthly {
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.primaryGradient, lineWidth: 1.2)
        } else {
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
        }
    }
}

// MARK: - Diagonal Hash Overlay (yearly tile)

private struct DiagonalHashOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            let stripeSpacing: CGFloat = 8
            let count = Int((size.width + size.height) / stripeSpacing) + 4
            ctx.opacity = 0.15
            for i in 0..<count {
                let x = CGFloat(i) * stripeSpacing - size.height
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(
                    path,
                    with: .color(UnifiedDesignSystem.Colors.textMuted),
                    lineWidth: 1
                )
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Capability Section

private struct CloudStoreCapabilitySection: View {
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            sectionHeader

            VStack(spacing: MobileTheme.Spacing.md) {
                CloudCapabilityCard(
                    icon: "cloud.fill",
                    iconStyle: .ember,
                    title: "Hosted Codex Quota",
                    details: "Refresh Codex quota from any signed-in device with one tap. We run the runner; you get the dial.",
                    isActive: isActive
                )
                CloudCapabilityCard(
                    icon: "arrow.triangle.2.circlepath",
                    iconStyle: .amber,
                    title: "Conversation Backup & Resume",
                    details: "Back up chat titles, previews, and message bodies — encrypted in transit, restored across iPhone, iPad, and Mac.",
                    isActive: isActive
                )
                CloudCapabilityCard(
                    icon: "text.alignleft",
                    iconStyle: .blaze,
                    title: "Full Session-Log Sync",
                    details: "Mirror complete agent runs into the cloud — every tool call, every chunk, every cost line — searchable on every device.",
                    isActive: isActive
                )
                CloudCapabilityCard(
                    icon: "antenna.radiowaves.left.and.right",
                    iconStyle: .mercury,
                    title: "Hermes Remote Relay",
                    details: "Reach your Mac's Hermes from anywhere over a verified WebSocket. App Check + Apple JWS gated end-to-end.",
                    isActive: isActive
                )
            }
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("WHAT'S INCLUDED")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.6)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Spacer()
            if isActive {
                Label("Active", systemImage: "checkmark.seal.fill")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.success)
            }
        }
    }
}

private struct CloudCapabilityCard: View {
    enum IconStyle { case ember, amber, blaze, mercury }

    let icon: String
    let iconStyle: IconStyle
    let title: String
    let details: String
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
            iconDisc
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(MobileTheme.Colors.success)
                            .accessibilityHidden(true)
                    }
                }
                Text(details)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(MobileTheme.cardGradient)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(borderStyle, lineWidth: 0.6)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)\(isActive ? ", active" : ""). \(details)")
    }

    @ViewBuilder
    private var iconDisc: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(discFill)
                .shadow(color: shadowTint, radius: 10, y: 4)
            if iconStyle == .mercury {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .overlay(MercuryShimmerOverlay())
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(
                    iconStyle == .mercury
                        ? AnyShapeStyle(.white)
                        : AnyShapeStyle(.white)
                )
        }
    }

    private var discFill: AnyShapeStyle {
        switch iconStyle {
        case .ember:
            return AnyShapeStyle(LinearGradient(
                colors: [UnifiedDesignSystem.Colors.ember, UnifiedDesignSystem.Colors.ember.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        case .amber:
            return AnyShapeStyle(LinearGradient(
                colors: [UnifiedDesignSystem.Colors.amber, UnifiedDesignSystem.Colors.amber.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        case .blaze:
            return AnyShapeStyle(LinearGradient(
                colors: [UnifiedDesignSystem.Colors.blaze, UnifiedDesignSystem.Colors.blaze.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        case .mercury:
            return AnyShapeStyle(UnifiedDesignSystem.mercuryGradient)
        }
    }

    private var shadowTint: Color {
        switch iconStyle {
        case .ember:   return UnifiedDesignSystem.Colors.ember.opacity(0.45)
        case .amber:   return UnifiedDesignSystem.Colors.amber.opacity(0.40)
        case .blaze:   return UnifiedDesignSystem.Colors.blaze.opacity(0.35)
        case .mercury: return UnifiedDesignSystem.Colors.hermesAureate.opacity(0.45)
        }
    }

    private var borderStyle: AnyShapeStyle {
        if iconStyle == .mercury {
            return AnyShapeStyle(UnifiedDesignSystem.mercuryGradient)
        }
        return AnyShapeStyle(MobileTheme.Colors.border.opacity(0.6))
    }
}

// MARK: - Comparison Card

private struct CloudStoreComparisonCard: View {
    private struct Row: Identifiable, Hashable {
        let id = UUID()
        let label: String
        let free: String
        let cloud: String
    }

    private let rows: [Row] = [
        Row(label: "Quota refresh",       free: "Local-only",       cloud: "On-demand, anywhere"),
        Row(label: "Chat backup",         free: "Metadata only",    cloud: "Full content"),
        Row(label: "Session logs",        free: "Manifest only",    cloud: "Full chunks"),
        Row(label: "Hermes Remote Relay", free: "Local network",    cloud: "Anywhere")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FREE VS CLOUD")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.6)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .padding(.horizontal, MobileTheme.Spacing.lg)
                .padding(.top, MobileTheme.Spacing.lg)
                .padding(.bottom, MobileTheme.Spacing.sm)

            VStack(spacing: 0) {
                headerRow
                Divider().background(MobileTheme.Colors.border.opacity(0.5))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    comparisonRow(row)
                    if index < rows.count - 1 {
                        Divider().background(MobileTheme.Colors.border.opacity(0.3))
                    }
                }
            }
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(MobileTheme.cardGradient)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
        )
    }

    private var headerRow: some View {
        HStack {
            Text("Capability")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.0)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("FREE")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.4)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .frame(width: 90, alignment: .trailing)
            Text("CLOUD")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(1.4)
                .foregroundStyle(MobileTheme.primaryGradient)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.vertical, MobileTheme.Spacing.sm)
    }

    private func comparisonRow(_ row: Row) -> some View {
        HStack {
            Text(row.label)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.free)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .frame(width: 90, alignment: .trailing)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            Text(row.cloud)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .frame(width: 110, alignment: .trailing)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.label). Free: \(row.free). Cloud: \(row.cloud).")
    }
}

// MARK: - Trust Card

private struct CloudStoreTrustCard: View {
    private let bullets: [(String, String, String)] = [
        ("checkmark.shield.fill", "Apple-verified", "Every transaction JWS is checked against Apple's root certificates server-side."),
        ("server.rack",            "UID-bound",     "Each purchase is bound to your Firebase UID via a signed `appAccountToken`."),
        ("hand.raised.fill",       "Cancel anytime","Managed by Apple in Settings → Apple ID. We never store payment details."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("THE TRUST MODEL")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.6)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            ForEach(bullets, id: \.1) { item in
                HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                    Image(systemName: item.0)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MobileTheme.Colors.success)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.1)
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(item.2)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let url = URL(string: "https://openburnbar.com/cloud") {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Text("Read the Hosted Quota Sync technical doc")
                        Image(systemName: "arrow.up.right.square.fill")
                    }
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.accent)
                }
                .padding(.top, 2)
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
        )
    }
}

// MARK: - Action Bar

private struct CloudStoreActionBar: View {
    @Bindable var store: HostedQuotaSubscriptionStore

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            subscribeButton
            Button {
                Task { await store.restorePurchases() }
            } label: {
                Text("Restore Purchases")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
            .disabled(store.isLoading)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.top, MobileTheme.Spacing.md)
        .padding(.bottom, MobileTheme.Spacing.lg)
        .background(
            LinearGradient(
                colors: [
                    MobileTheme.Colors.background.opacity(0.0),
                    MobileTheme.Colors.background.opacity(0.85),
                    MobileTheme.Colors.background.opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private var subscribeButton: some View {
        let priceCopy = store.product?.displayPrice ?? "$2.99"
        Button {
            Haptics.medium()
            Task { await store.purchase() }
        } label: {
            HStack(spacing: MobileTheme.Spacing.sm) {
                if store.isLoading {
                    MiningPickLoader(.inline, tint: .white)
                    Text("Processing…")
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                    Text("Subscribe — \(priceCopy)/mo")
                        .fontWeight(.semibold)
                }
            }
            .font(MobileTheme.Typography.body)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, MobileTheme.Spacing.md)
            .background(
                Capsule()
                    .fill(MobileTheme.primaryGradient)
                    .shadow(color: UnifiedDesignSystem.Colors.ember.opacity(0.45), radius: 18, y: 8)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.isLoading || store.product == nil)
    }
}

// MARK: - Member Card

private struct CloudStoreMemberCard: View {
    @Bindable var store: HostedQuotaSubscriptionStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            backgroundLayers

            VStack(spacing: MobileTheme.Spacing.lg) {
                laurelHeader
                renewalLine
                memberMetaLine
                actionRow
            }
            .padding(MobileTheme.Spacing.xl)
        }
        .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.xl, style: .continuous)
                .stroke(UnifiedDesignSystem.mercuryGradient, lineWidth: 1.2)
        )
        .shadow(color: UnifiedDesignSystem.Colors.ember.opacity(0.18), radius: 24, y: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var laurelHeader: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            Image(systemName: "laurel.leading")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(UnifiedDesignSystem.mercuryGradient)
            VStack(spacing: 2) {
                Text("CLOUD")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(2.4)
                    .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)
                Text("Member")
                    .font(MobileTheme.Typography.display)
                    .fontWeight(.bold)
                    .foregroundStyle(UnifiedDesignSystem.mercuryGradient)
            }
            Image(systemName: "laurel.trailing")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(UnifiedDesignSystem.mercuryGradient)
        }
    }

    private var renewalLine: some View {
        Group {
            if let expiration = store.expirationDate {
                Label {
                    Text("Renews \(expiration, style: .relative)")
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(MobileTheme.Colors.success)
                }
            } else {
                Label {
                    Text("Active")
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(MobileTheme.Colors.success)
                }
            }
        }
    }

    private var memberMetaLine: some View {
        Group {
            if let purchaseDate = store.purchaseDate {
                Text("Member since \(purchaseDate, format: .dateTime.month(.abbreviated).year())")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            } else if let exp = store.expirationDate {
                Text("Through \(exp, format: .dateTime.month(.abbreviated).day().year())")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            } else {
                EmptyView()
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard.fill")
                    Text("Manage")
                        .fontWeight(.semibold)
                }
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(UnifiedDesignSystem.mercuryGradient)
                )
            }
            .accessibilityLabel("Manage subscription in App Store")

            Button {
                Task { await store.restorePurchases() }
            } label: {
                HStack(spacing: 6) {
                    if store.isLoading {
                        MiningPickLoader(.inline, tint: MobileTheme.Colors.textPrimary)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Restore")
                        .fontWeight(.semibold)
                }
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(MobileTheme.Colors.surface.opacity(0.85))
                        .overlay(
                            Capsule().stroke(MobileTheme.Colors.border, lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
        }
    }

    @ViewBuilder
    private var backgroundLayers: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MobileTheme.Radius.xl, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: MobileTheme.Radius.xl, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            UnifiedDesignSystem.Colors.ember.opacity(0.08),
                            UnifiedDesignSystem.Colors.amber.opacity(0.06),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RadialGradient(
                colors: [
                    UnifiedDesignSystem.Colors.amber.opacity(0.30),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 220
            )
            .blendMode(.plusLighter)

            if !reduceMotion {
                MercuryShimmerOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.xl, style: .continuous))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)

                MemberSparksOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.xl, style: .continuous))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                    .opacity(0.55)
            }
        }
    }

    private var accessibilitySummary: String {
        var parts: [String] = ["OpenBurnBar Cloud member"]
        if let exp = store.expirationDate {
            parts.append("Renews \(exp.formatted(.relative(presentation: .named)))")
        }
        if let purchase = store.purchaseDate {
            let fmt = purchase.formatted(.dateTime.month(.wide).year())
            parts.append("Member since \(fmt)")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Member Sparks Overlay

private struct MemberSparksOverlay: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let count = 8
                for i in 0..<count {
                    let seed = Double(i) * 1.234
                    let phase = (t * 0.22 + seed).truncatingRemainder(dividingBy: 1.0)
                    let x = size.width * (0.10 + ((sin(seed * 5.7) + 1) * 0.40))
                    let yStart = size.height * 0.95
                    let yEnd = size.height * 0.20
                    let y = yStart + (yEnd - yStart) * CGFloat(phase)
                    let radius: CGFloat = 1.4
                    let rect = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    ctx.opacity = (1.0 - phase) * 0.6
                    let color: Color = (i % 2 == 0)
                        ? UnifiedDesignSystem.Colors.amber
                        : UnifiedDesignSystem.Colors.ember
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Error Card

private struct CloudStoreErrorCard: View {
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
                .fill(MobileTheme.Colors.error.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .stroke(MobileTheme.Colors.error.opacity(0.35), lineWidth: 0.5)
        )
    }
}

// MARK: - Previews

#Preview("Locked") {
    NavigationStack {
        CloudStoreView()
    }
}
