import SwiftUI
import OpenBurnBarInboxModels
import OpenBurnBarKernel
import OpenBurnBarLogParsers
import OpenBurnBarQuota
import OpenBurnBarUI

// MARK: - You View
//
// Account hub. An inset-grouped Settings list: identity row, Mac keep-awake,
// cloud + sync rows, devices, providers, settings, the destinations that left
// the compact tray, and a destructive sign-out button.

struct YouView: View {
    @Bindable var authStore: AuthStore
    @Bindable var syncStore: CloudSyncHealthStore
    @Bindable var devicesStore: DevicesStore
    @State private var account = AccountStore()
    @State private var showSignOutConfirm = false
    @State private var showCloudStore = false
    @State private var showSignIn = false
    @State private var unlockFeature: GatedFeaturePresentation?
    @ObservedObject private var hostReachability = HostReachabilityClient.shared

    @Environment(\.cloudSubscriptionStore) private var cloudStore

    /// The user's resolved tier; `.none` when no Cloud store is in scope yet.
    private var tier: CloudTier { cloudStore?.cloudTier ?? .none }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    youQuietAvatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(authStore.currentIdentity?.displayName ?? authStore.currentIdentity?.email ?? account.user?.displayName ?? account.user?.email ?? "Guest")
                            .font(.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        if let email = authStore.currentIdentity?.email ?? account.user?.email {
                            Text(email)
                                .font(.footnote)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityIdentifier("you.identity")
            }

            Section("Mac") {
                KeepAwakeHostCard(client: hostReachability)
                askToMirrorRow
            }

            Section("Cloud") {
                cloudMembershipRow
                storeAndTopUpsRow
                syncDiagnosticsCard
            }

            Section {
                NavigationLink(value: YouRoute.devices) {
                    ConnectedDevicesRow(devices: devicesStore.devices)
                }
                providerConnectionsRow
                computerUseRow
                dataVaultRow
                settingsRow
            }

            Section("More") {
                overflowDestinations
            }

            Section {
                accountActionButton
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            HapticBus.refreshStarted()
            async let s: Void = syncStore.refresh()
            async let a: Void = account.fetchConnections()
            async let d: Void = devicesStore.load()
            _ = await (s, a, d)
            playCloudSyncRefreshCompletionHaptic(for: syncStore.health)
        }
        .navigationTitle("You")
        .accessibilityIdentifier("screen.you")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await syncStore.refresh()
            await account.fetchConnections()
            await devicesStore.load()
        }
        .confirmationDialog("Sign out?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                HapticBus.destructive()
                Task { await authStore.signOut() }
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
        .sheet(isPresented: $showSignIn) {
            SignInScene(authStore: authStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $unlockFeature) { presentation in
            FeatureUnlockSheet(feature: presentation.feature)
        }
        .onChange(of: authStore.state.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                showSignIn = false
            }
        }
    }

    // MARK: - Cloud Membership Row
    //
    // Member: MercuryCrest medallion + "Cloud Member · Since {date}".
    // Free:   `MembershipBand` upsell — tap opens `CloudStoreView`.

    @ViewBuilder
    private var cloudMembershipRow: some View {
        Button {
            showCloudStore = true
        } label: {
            YouSettingsLabel(
                imageName: "SettingsIconCloud",
                title: cloudStore?.isActive == true ? "Cloud Member" : "OpenBurnBar Cloud",
                subtitle: cloudStore?.isActive == true
                    ? "Manage membership"
                    : "Hosted refresh, backup, Hermes anywhere"
            )
        }
    }

    @ViewBuilder
    private var youQuietAvatar: some View {
        let url = authStore.currentIdentity?.photoURL ?? account.user?.photoURL
        if let url {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color(.tertiarySystemFill))
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
    }

    private var storeAndTopUpsRow: some View {
        Button {
            HapticBus.primaryAction()
            showCloudStore = true
        } label: {
            YouSettingsLabel(
                imageName: "SettingsIconStore",
                title: "Store & Top-ups",
                subtitle: cloudStore?.isActive == true ? "Manage Cloud, Cloud Pro, and add-ons" : "Buy Cloud, Cloud Pro, and add-ons"
            )
        }
        .accessibilityIdentifier("you.storeAndTopUps")
        .accessibilityLabel("Store and Top-ups")
        .accessibilityHint("Opens OpenBurnBar Cloud purchases and top-ups")
    }

    // MARK: - Sync Card

    private var syncDiagnosticsCard: some View {
        HStack(spacing: 12) {
            NavigationLink(value: YouRoute.sync) {
                YouSettingsLabel(
                    imageName: "SettingsIconCloud",
                    title: "Cloud sync",
                    subtitle: syncStore.statusLabel()
                )
            }
            .accessibilityHint("Opens cloud sync details")

            Button {
                Task {
                    HapticBus.refreshStarted()
                    await syncStore.refresh()
                    playCloudSyncRefreshCompletionHaptic(for: syncStore.health)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .symbolEffect(.bounce, value: syncStore.lastReadAt ?? Date())
            }
            .buttonStyle(.borderless)
            .disabled(syncStore.isLoading)
            .accessibilityLabel("Refresh cloud sync")
        }
    }

    // MARK: - Provider Connections Row

    private var providerConnectionsRow: some View {
        NavigationLink(value: YouRoute.providers) {
            HStack(spacing: 12) {
                YouSettingsLabel(
                    imageName: "SettingsIconAgent",
                    title: "Provider connections",
                    subtitle: "\(connectedProviderCount) connected"
                )
                overlappingProviders
            }
        }
    }

    // MARK: - Agent Control (pro-gated)
    //
    // Public name "Agent Control" (never "Computer Use" in user copy). When the
    // user isn't on Cloud Pro the row wears a `TierLockBadge` and its tap opens
    // the unlock sheet instead of navigating into the live agent screen.

    private var askToMirrorRow: some View {
        Button {
            HermesSquareAgentsColumnRouting.AskToMirrorPending.stash()
            NotificationCenter.default.post(name: IPadAwayDeskNotifications.askToMirror, object: nil)
            NotificationCenter.default.post(name: .init("ShowAssistantsTab"), object: nil)
        } label: {
            YouSettingsLabel(
                systemImage: "rectangle.dashed.badge.record",
                systemTint: MobileTheme.Colors.textSecondary,
                title: "Ask to Mirror",
                subtitle: "See your Mac screen from this phone"
            )
        }
        .accessibilityIdentifier("you.askToMirror")
        .accessibilityHint("Opens Agents and asks the Mac to share its screen")
    }

    @ViewBuilder
    private var computerUseRow: some View {
        let chrome = gatedRowChrome(
            icon: "cursorarrow.rays",
            iconTint: .orange,
            title: "Agent Control",
            subtitle: "Watch, approve, halt — or Ask to Mirror from Agents",
            imageName: "SettingsIconSettingsB"
        )
        if tier.satisfies(.pro) {
            NavigationLink(value: YouRoute.computerUse) { chrome }
        } else {
            Button {
                Haptics.light()
                unlockFeature = GatedFeatureID.agentControl.presentation
            } label: {
                chrome.tierLockBadge(.agentControl, tier: tier)
            }
            .accessibilityHint("Available on Cloud Pro")
        }
    }

    /// Shared row chrome for the gated You-tab rows so the entitled
    /// NavigationLink and the locked unlock-button render identically.
    private func gatedRowChrome(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String,
        imageName: String? = nil
    ) -> some View {
        YouSettingsLabel(
            imageName: imageName,
            systemImage: icon,
            systemTint: iconTint,
            title: title,
            subtitle: subtitle
        )
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
            YouSettingsLabel(
                imageName: "SettingsIconSettingsA",
                title: "Settings",
                subtitle: "Theme · Budget · Notifications · About"
            )
        }
        .accessibilityIdentifier("you.settingsRow")
    }

    /// Destinations that left the compact tray. Insights deep links land here
    /// as a reachable route; Pulse, Streams, and Recap stay one tap away.
    private var overflowDestinations: some View {
        Group {
            overflowRow(
                title: "Insights",
                subtitle: "Agent patterns, budgets, monthly recap",
                icon: "sparkles.tv.fill",
                identifier: "you.insightsRow"
            ) {
                InsightsDeepLink.open()
            }
            overflowRow(
                title: "Pulse",
                subtitle: "Live spend and forecast",
                icon: "waveform.path.ecg",
                identifier: "you.pulseRow"
            ) {
                NotificationCenter.default.post(name: .init("NavigateToDashboard"), object: nil)
            }
            overflowRow(
                title: "Streams",
                subtitle: "Sessions, projects, activity",
                icon: "list.bullet.rectangle.portrait.fill",
                identifier: "you.streamsRow"
            ) {
                NotificationCenter.default.post(name: .init("ShowStreamsTab"), object: nil)
            }
            overflowRow(
                title: "Recap",
                subtitle: "Your last completed month",
                icon: "calendar.badge.clock",
                identifier: "you.recapRow"
            ) {
                NotificationCenter.default.post(name: .init("ShowRecap"), object: nil)
            }
        }
    }

    private func overflowRow(
        title: String,
        subtitle: String,
        icon: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            YouSettingsLabel(
                systemImage: icon,
                systemTint: MobileTheme.Colors.textSecondary,
                title: title,
                subtitle: subtitle
            )
        }
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Data Vault (pro-gated)
    //
    // The Data & Privacy Control Center hosts the pro-gated Pensieve agent
    // memory. Locked users see the tier badge and the unlock sheet; the
    // privacy inventory itself stays reachable once on Cloud Pro.

    @ViewBuilder
    private var dataVaultRow: some View {
        let chrome = gatedRowChrome(
            icon: "brain.head.profile",
            iconTint: MobileTheme.success,
            title: "Data Vault",
            subtitle: "Private agent memory · privacy inventory · recovery",
            imageName: "SettingsIconData"
        )
        if tier.satisfies(.pro) {
            NavigationLink(value: YouRoute.dataVault) { chrome }
        } else {
            Button {
                Haptics.light()
                unlockFeature = GatedFeatureID.dataVault.presentation
            } label: {
                chrome.tierLockBadge(.dataVault, tier: tier)
            }
            .accessibilityHint("Available on Cloud Pro")
        }
    }

    // MARK: - Sign Out

    private var accountActionButton: some View {
        Group {
            if authStore.state.isSignedIn {
                Button("Sign out", role: .destructive) {
                    showSignOutConfirm = true
                }
            } else {
                Button {
                    showSignIn = true
                } label: {
                    Label("Sign in for Cloud", systemImage: "person.crop.circle.badge.checkmark")
                }
                .accessibilityIdentifier("you.signIn")
            }
        }
    }
}

// MARK: - You Row Icon
//
// Renders one of the whimsical full-color SVG icons on the main "You" tab.
// The asset is scaled to fit a 44×44 rounded plate with a subtle tinted
// background so it matches the surrounding Aurora glass rows.

struct YouRowIcon: View {
    let imageName: String

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: 29, height: 29)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Settings-row label: SF/asset icon + title + subtitle. List supplies the
/// disclosure chevron. No card chrome.
private struct YouSettingsLabel: View {
    var imageName: String?
    var systemImage: String?
    var systemTint: Color = MobileTheme.Colors.textSecondary
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            if let imageName {
                YouRowIcon(imageName: imageName)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(systemTint)
                    .frame(width: 29, height: 29)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - You Route

enum YouRoute: Hashable, CaseIterable {
    case sync
    case settings
    case devices
    case providers
    case computerUse
    case dataVault
    case memory
}

/// The destination each `YouRoute` opens. Shared by the iPhone root's
/// `navigationDestination` and the iPad You canvas so adding a route is one
/// edit, not two. `onComputerUseAppear` is the iPad's inspector pin.
@ViewBuilder
func youRouteView(
    _ route: YouRoute,
    authStore: AuthStore,
    syncStore: CloudSyncHealthStore,
    devicesStore: DevicesStore,
    hermesService: HermesService,
    settingsRouter: SettingsRouter,
    onComputerUseAppear: @escaping () -> Void = {}
) -> some View {
    switch route {
    case .sync:
        CloudSyncDetailsView(syncStore: syncStore)
    case .settings:
        SettingsHubView(authStore: authStore)
            .environment(settingsRouter)
    case .devices:
        iPadDevicesSettingsView(store: devicesStore, hermesService: hermesService)
    case .providers:
        ProviderConnectionsView(showsDoneButton: false)
    case .computerUse:
        ContentUnavailableView(
            "Watch is open",
            systemImage: "macbook.and.ipad",
            description: Text("Approvals and Ask to Mirror stay in the Watch inspector or Watch window.")
        )
        .onAppear(perform: onComputerUseAppear)
    case .dataVault:
        DataVaultAdaptiveControlView()
    case .memory:
        PensieveMemorySearchView()
    }
}

// MARK: - Cloud Sync Details

struct CloudSyncDetailsView: View {
    @Bindable var syncStore: CloudSyncHealthStore

    var body: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.lg) {
                statusCard
                timestampsCard
                publisherCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, MobileTheme.Spacing.lg)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable { await refresh() }
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
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(spacing: 12) {
                Image(systemName: syncStore.health.systemImageName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(syncStore.health.tint)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(syncStore.health.tint.opacity(0.16)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(syncStore.statusLabel())
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
            .buttonStyle(.bordered)
            .disabled(syncStore.isLoading)
        }
    }

    private var timestampsCard: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Activity")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            detailRow("Last Mac write", value: formatted(syncStore.lastPublishedAt))
            detailRow("Last mobile read", value: formatted(syncStore.lastReadAt))
        }
    }

    private var publisherCard: some View {
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
    var systemImageName: String {
        switch self {
        case .healthy: return "checkmark.icloud.fill"
        case .syncing: return "arrow.triangle.2.circlepath.icloud.fill"
        case .macNotSyncing: return "desktopcomputer.trianglebadge.exclamationmark"
        case .offline: return "icloud.slash.fill"
        case .firebaseUnavailable, .appCheckBlocked, .permissionDenied: return "exclamationmark.icloud.fill"
        case .degraded: return "icloud.fill"
        case .networkDisabledOnThisDevice: return "icloud.slash.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .healthy: return MobileTheme.success
        case .syncing: return MobileTheme.amber
        case .macNotSyncing: return MobileTheme.warning
        case .offline: return MobileTheme.warning
        case .firebaseUnavailable, .appCheckBlocked, .permissionDenied: return MobileTheme.error
        case .degraded: return MobileTheme.warning
        case .networkDisabledOnThisDevice: return MobileTheme.warning
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
        case .macNotSyncing:
            return "OpenBurnBar on your Mac has not published recently. Open the Mac app to update cloud data."
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
        case .networkDisabledOnThisDevice:
            return "Cloud sync was turned off on this device by the emergency compatibility switch, so no data is being read. Remove the override to reconnect."
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
