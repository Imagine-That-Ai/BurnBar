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
    @State private var showProviderConnections = false

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

                    ConnectedDevicesRow(devices: devicesStore.devices) {
                        showProviderConnections = false
                    }
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
                HapticBus.refreshFinished()
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
        .sheet(isPresented: $showProviderConnections) {
            NavigationStack { ProviderConnectionsView() }
                .presentationDetents([.large])
        }
        .confirmationDialog("Sign out?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                HapticBus.destructive()
                Task { await account.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to sign in again to access your data.")
        }
    }

    // MARK: - Sync Card

    private var syncDiagnosticsCard: some View {
        AuroraGlassCard(variant: syncStore.health.isHealthy ? .success : (syncStore.health.isDegraded ? .urgent : .standard)) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(syncColor.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: syncIcon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(syncColor)
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
                Spacer()
                Button {
                    Task { await syncStore.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(MobileTheme.ember)
                        .symbolEffect(.bounce, value: syncStore.lastReadAt ?? Date())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var syncIcon: String {
        switch syncStore.health {
        case .healthy: return "checkmark.icloud.fill"
        case .syncing: return "arrow.triangle.2.circlepath.icloud.fill"
        case .offline: return "icloud.slash.fill"
        case .firebaseUnavailable, .appCheckBlocked, .permissionDenied: return "exclamationmark.icloud.fill"
        case .degraded(_): return "icloud.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var syncColor: Color {
        switch syncStore.health {
        case .healthy: return MobileTheme.success
        case .syncing: return MobileTheme.amber
        case .offline: return MobileTheme.warning
        case .firebaseUnavailable, .appCheckBlocked, .permissionDenied: return MobileTheme.error
        case .degraded(_): return MobileTheme.warning
        case .unknown: return MobileTheme.Colors.textMuted
        }
    }

    // MARK: - Provider Connections Row

    private var providerConnectionsRow: some View {
        Button {
            HapticBus.sheetOpen()
            showProviderConnections = true
        } label: {
            AuroraGlassCard(variant: .standard, cornerRadius: 16, interactive: true) {
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
        NavigationLink(value: YouRoute.settings) {
            AuroraGlassCard(variant: .standard, cornerRadius: 16, interactive: true) {
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

enum YouRoute: Hashable {
    case settings
    case devices
}
