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
                        connectionsCount: account.connections.count
                    )
                    .staggeredEntrance(delay: 0.0)

                    syncDiagnosticsCard
                        .staggeredEntrance(delay: 0.05)

                    NavigationLink {
                        iPadDevicesSettingsView()
                    } label: {
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
    }

    // MARK: - Sync Card

    private var syncDiagnosticsCard: some View {
        AuroraGlassCard(variant: syncStore.health.cardVariant) {
            HStack(spacing: 12) {
                NavigationLink {
                    CloudSyncDetailsView(syncStore: syncStore)
                } label: {
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
        NavigationLink {
            ProviderConnectionsView(showsDoneButton: false)
        } label: {
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
                        Text("\(account.connections.count) connected")
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

    private var overlappingProviders: some View {
        let providers = account.connections.prefix(4).compactMap {
            AgentProvider.fromProviderID(ProviderID(rawValue: $0.provider))
        }
        return ZStack {
            ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
                ProviderAvatar(provider: provider, mode: .tile, size: 26)
                    .offset(x: CGFloat(index) * -16)
                    .zIndex(Double(providers.count - index))
            }
        }
        .frame(width: max(0, CGFloat(providers.count) * 16), height: 32)
    }

    // MARK: - Settings Row

    private var settingsRow: some View {
        NavigationLink {
            SettingsHubView()
        } label: {
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
                        ProgressView()
                            .tint(MobileTheme.ember)
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
