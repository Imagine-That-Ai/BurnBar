import SwiftUI
import OpenBurnBarCore

// MARK: - You View
//
// Account hub. Combines IdentityHero, sync diagnostics card, devices row,
// providers shortcut, settings shortcut, and a destructive sign-out button.

struct YouView: View {
    @Bindable var authStore: AuthStore
    @Bindable var syncStore: CloudSyncHealthStore
    @Bindable var devicesStore: DevicesStore
    @State private var account = AccountStore()
    @State private var showSignOutConfirm = false
    @State private var showCloudStore = false

    @Environment(\.cloudSubscriptionStore) private var cloudStore

    var body: some View {
        ZStack {
            AuroraBackdrop()
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    IdentityHero(
                        displayName: account.user?.displayName ?? account.user?.email ?? "Guest",
                        email: account.user?.email,
                        photoURL: account.user?.photoURL,
                        syncHealth: syncStore.health,
                        connectionsCount: connectedProviderCount
                    )
                    .staggeredEntrance(delay: 0.0)

                    cloudMembershipRow
                        .staggeredEntrance(delay: 0.03)

                    syncDiagnosticsCard
                        .staggeredEntrance(delay: 0.05)

                    NavigationLink(value: YouRoute.devices) {
                        ConnectedDevicesRow(devices: devicesStore.devices)
                    }
                    .buttonStyle(.plain)
                    .staggeredEntrance(delay: 0.10)

                    providerConnectionsRow
                        .staggeredEntrance(delay: 0.15)

                    settingsRow
                        .staggeredEntrance(delay: 0.20)

                    signOutButton
                        .padding(.top, MobileTheme.Spacing.md)
                        .staggeredEntrance(delay: 0.25)
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.vertical, MobileTheme.Spacing.md)
                .padding(.bottom, MobileTheme.Spacing.xxxl)
            }
            .refreshable {
                HapticBus.refreshStarted()
                async let s: Void = syncStore.refresh()
                async let a: Void = account.fetchConnections()
                async let d: Void = devicesStore.load()
                _ = await (s, a, d)
                playCloudSyncRefreshCompletionHaptic(for: syncStore.health)
            }
        }
        .navigationTitle("You")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await syncStore.refresh()
            await account.fetchConnections()
            await devicesStore.load()
        }
        .confirmationDialog("Sign out?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                HapticBus.destructive()
                authStore.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to sign in again to access your data.")
        }
        .sheet(isPresented: $showCloudStore) {
            NavigationStack {
                CloudStoreView(onClose: { showCloudStore = false })
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Cloud Membership Row
    //
    // Member: MercuryCrest medallion + "Cloud Member · Since {date}".
    // Free:   `MembershipBand` upsell — tap opens `CloudStoreView`.

    @ViewBuilder
    private var cloudMembershipRow: some View {
        if let cloudStore, cloudStore.isActive {
            CloudMemberCrestRow(
                purchaseDate: cloudStore.purchaseDate,
                expirationDate: cloudStore.expirationDate,
                onTap: { showCloudStore = true }
            )
        } else {
            MembershipBand(
                title: "OpenBurnBar Cloud",
                detail: "Your agents, unbound — hosted refresh, backup, Hermes anywhere.",
                variant: .upsell,
                icon: "sparkle",
                ctaLabel: "BECOME A MEMBER"
            ) {
                showCloudStore = true
            }
        }
    }

    // MARK: - Sync Card

    private var syncDiagnosticsCard: some View {
        AuroraGlassCard(variant: syncStore.health.cardVariant) {
            HStack(spacing: 12) {
                NavigationLink(value: YouRoute.sync) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(syncStore.health.tint.opacity(0.18))
                                .frame(width: 44, height: 44)
                            Image(systemName: syncStore.health.systemImageName)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(syncStore.health.tint)
                                .symbolEffect(.variableColor, options: .repeating)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cloud sync")
                                .font(MobileTheme.Typography.headline)
                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                            Text(syncStore.health.label)
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                            if let lastSync = syncStore.lastPublishedAt {
                                Text("Last write \(lastSync, style: .relative) ago")
                                    .font(MobileTheme.Typography.tiny)
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHint("Opens cloud sync details")

                Button {
                    Task {
                        HapticBus.refreshStarted()
                        await syncStore.refresh()
                        playCloudSyncRefreshCompletionHaptic(for: syncStore.health)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(MobileTheme.ember)
                        .symbolEffect(.bounce, value: syncStore.lastReadAt ?? Date())
                }
                .buttonStyle(.plain)
                .disabled(syncStore.isLoading)
                .accessibilityLabel("Refresh cloud sync")
            }
        }
    }

    // MARK: - Provider Connections Row

    private var providerConnectionsRow: some View {
        NavigationLink(value: YouRoute.providers) {
            AuroraGlassCard(variant: .standard, cornerRadius: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MobileTheme.ember)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(MobileTheme.ember.opacity(0.16))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Provider connections")
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("\(connectedProviderCount) connected")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    Spacer()
                    overlappingProviders
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    /// Distinct providers that have at least one active account or legacy
    /// connection. Earlier code only counted the legacy
    /// `provider_connections` collection, which left this number stuck at 0
    /// even when `provider_accounts` had several rows feeding the drill-in.
    private var connectedProviders: [AgentProvider] {
        var seen = Set<String>()
        var ordered: [AgentProvider] = []

        // Prefer first-class accounts (multi-account model).
        for doc in account.providerAccounts where doc.status != .deleted {
            let key = doc.providerID.rawValue
            guard seen.insert(key).inserted else { continue }
            if let provider = AgentProvider.fromProviderID(doc.providerID) {
                ordered.append(provider)
            }
        }
        // Then fold in any legacy single-account connections.
        for legacy in account.connections {
            guard seen.insert(legacy.provider).inserted else { continue }
            if let provider = AgentProvider.fromPersistedToken(legacy.provider)
                ?? AgentProvider.fromProviderID(ProviderID(rawValue: legacy.provider)) {
                ordered.append(provider)
            }
        }
        return ordered
    }

    private var connectedProviderCount: Int { connectedProviders.count }

    private var overlappingProviders: some View {
        let providers = Array(connectedProviders.prefix(4))
        return ZStack {
            ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
                ProviderAvatar(provider: provider, mode: .tile, size: 34)
                    .offset(x: CGFloat(index) * -16)
                    .zIndex(Double(providers.count - index))
            }
        }
        .frame(width: max(0, CGFloat(providers.count) * 16), height: 32)
    }

    // MARK: - Settings Row

    private var settingsRow: some View {
        NavigationLink(value: YouRoute.settings) {
            AuroraGlassCard(variant: .standard, cornerRadius: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MobileTheme.amber)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(MobileTheme.amber.opacity(0.16))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings")
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("Theme · Budget · Notifications · About")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sign Out

    private var signOutButton: some View {
        Button("Sign out") {
            showSignOutConfirm = true
        }
        .buttonStyle(.aurora(.destructive, fullWidth: true))
    }
}

// MARK: - You Route

enum YouRoute: Hashable, CaseIterable {
    case sync
    case settings
    case devices
    case providers
}

// MARK: - Cloud Member Crest Row
//
// Pro vocabulary — member certificate row. Replaces the upsell band once a
// user has an active OpenBurnBar Cloud entitlement. MercuryCrest medallion +
// "Cloud Member · Since {date}" with foil edge.

private struct CloudMemberCrestRow: View {
    let purchaseDate: Date?
    let expirationDate: Date?
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: {
            Haptics.light()
            onTap()
        }) {
            HStack(spacing: MobileTheme.Spacing.md) {
                MercuryCrest(size: .large, shimmer: !reduceMotion)
                    .padding(.leading, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cloud Member")
                        .font(ProTheme.Typography.titleSerif)
                        .foregroundStyle(ProTheme.Palette.mercury)
                    Text(metaLine)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.7))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ProTheme.Palette.aureate)
            }
            .padding(.horizontal, MobileTheme.Spacing.md)
            .padding(.vertical, MobileTheme.Spacing.md)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous)
                        .fill(ProTheme.Palette.obsidian)
                    if !reduceMotion {
                        MercuryShimmerOverlay()
                            .clipShape(RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous))
                            .blendMode(.plusLighter)
                            .opacity(0.40)
                            .allowsHitTesting(false)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous)
                    .stroke(ProTheme.Palette.aureateStroke, lineWidth: 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous))
            .shadow(color: ProTheme.Palette.aureate.opacity(0.20), radius: 14, y: 5)
            .contentShape(RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("OpenBurnBar Cloud member. \(metaLine).")
        .accessibilityHint("Opens your Cloud membership")
    }

    private var metaLine: String {
        if let purchaseDate {
            let f = purchaseDate.formatted(.dateTime.month(.abbreviated).year())
            return "Member since \(f)"
        }
        if let expirationDate {
            let f = expirationDate.formatted(.dateTime.month(.abbreviated).day().year())
            return "Through \(f)"
        }
        return "Active"
    }
}

// MARK: - Cloud Sync Details

struct CloudSyncDetailsView: View {
    @Bindable var syncStore: CloudSyncHealthStore

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    statusCard
                    timestampsCard
                    publisherCard
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.vertical, MobileTheme.Spacing.lg)
            }
            .refreshable { await refresh() }
        }
        .navigationTitle("Cloud Sync")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(syncStore.isLoading)
                .accessibilityLabel("Refresh cloud sync")
            }
        }
        .task {
            if syncStore.lastReadAt == nil {
                await refresh()
            }
        }
    }

    private var statusCard: some View {
        AuroraGlassCard(variant: syncStore.health.cardVariant) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(spacing: 12) {
                    Image(systemName: syncStore.health.systemImageName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(syncStore.health.tint)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(syncStore.health.tint.opacity(0.16)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(syncStore.health.label)
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(syncStore.health.detailText)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                    Spacer()
                    if syncStore.isLoading {
                        MiningPickLoader(.inline)
                    }
                }

                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh now", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aurora(.secondary, fullWidth: true))
                .disabled(syncStore.isLoading)
            }
        }
    }

    private var timestampsCard: some View {
        AuroraGlassCard(variant: .standard) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Text("Activity")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                detailRow("Last Mac write", value: formatted(syncStore.lastPublishedAt))
                detailRow("Last mobile read", value: formatted(syncStore.lastReadAt))
            }
        }
    }

    private var publisherCard: some View {
        AuroraGlassCard(variant: .standard) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Text("Publishing device")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                if let publisher = syncStore.publisher {
                    detailRow("Name", value: publisher.displayName)
                    detailRow("Platform", value: publisher.platform)
                    detailRow("Last seen", value: formatted(publisher.lastSeen))
                } else {
                    Text("No publishing device has written sync data yet.")
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(MobileTheme.Typography.monoSmall)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func refresh() async {
        HapticBus.refreshStarted()
        await syncStore.refresh()
        playCloudSyncRefreshCompletionHaptic(for: syncStore.health)
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

}

// MARK: - Cloud Sync Presentation

extension CloudSyncHealth {
    var cardVariant: AuroraGlassVariant {
        isHealthy ? .success : (isDegraded ? .urgent : .standard)
    }

    var systemImageName: String {
        switch self {
        case .healthy: return "checkmark.icloud.fill"
        case .syncing: return "arrow.triangle.2.circlepath.icloud.fill"
        case .offline: return "icloud.slash.fill"
        case .firebaseUnavailable, .appCheckBlocked, .permissionDenied: return "exclamationmark.icloud.fill"
        case .degraded: return "icloud.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .healthy: return MobileTheme.success
        case .syncing: return MobileTheme.amber
        case .offline: return MobileTheme.warning
        case .firebaseUnavailable, .appCheckBlocked, .permissionDenied: return MobileTheme.error
        case .degraded: return MobileTheme.warning
        case .unknown: return MobileTheme.Colors.textMuted
        }
    }

    var detailText: String {
        switch self {
        case .unknown:
            return "Tap refresh to check the latest cloud state."
        case .healthy:
            return "Your mobile app can read the latest synced usage data."
        case .syncing:
            return "Checking Firestore for the newest sync snapshot."
        case .offline:
            return CloudErrorClassification.networkUnavailable.recoveryHint
        case .permissionDenied:
            return CloudErrorClassification.permissionDenied.recoveryHint
        case .appCheckBlocked:
            return CloudErrorClassification.appCheckBlocked.recoveryHint
        case .firebaseUnavailable:
            return CloudErrorClassification.firebaseUnavailable.recoveryHint
        case .degraded(let reason):
            return reason.recoveryHint
        }
    }
}

@MainActor
private func playCloudSyncRefreshCompletionHaptic(for health: CloudSyncHealth) {
    if health.isHealthy {
        HapticBus.refreshFinished()
    } else {
        HapticBus.threshold()
    }
}
