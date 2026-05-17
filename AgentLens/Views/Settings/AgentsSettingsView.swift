import AppKit
import OpenBurnBarCore
import SwiftUI

// MARK: - Settings → Agents

/// Settings → **Agents** — one sidebar tab that consolidates the prior
/// Connections, Account Switcher, and AI Environments tabs into a
/// hub-and-spoke landing page. The landing renders four drill rows
/// (Accounts / CLIs / Runtimes / Advanced) with live summary strings; each
/// drill destination is a focused detail screen lifted from the retired
/// tabs.
///
/// Implementation notes:
/// - Accounts, CLIs (the wiring half), and Advanced delegate to
///   `ConnectionsSettingsView` with a `Section` filter, so the existing
///   Connections layout is reused verbatim rather than duplicated.
/// - CLIs additionally embeds `AccountSwitcherSettingsView(mode: .cliOnly)`
///   below the wiring rows so profile switching is one drill away.
/// - Advanced additionally embeds `AccountSwitcherSettingsView(mode:
///   .browserOnly)` and drill rows to the Hermes detail screens.
/// - Runtimes lifts the gateway drill rows from the retired
///   `ChatGatewaySettingsView`.
struct AgentsSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var daemonManager: OpenBurnBarDaemonManager
    let dataStore: DataStore
    let accountManager: AccountManager
    let cloudSyncService: CloudSyncService?
    let iCloudSessionMirrorService: ICloudSessionMirrorService?

    @State private var quotaService = ProviderQuotaService.shared
    @State private var providerAccounts: [ProviderAccountDoc] = []
    @State private var switcherProfiles: [SwitcherProfileRecord] = []
    @State private var wiringSnapshot: WiringSnapshot = .empty

    init(
        settingsManager: SettingsManager,
        daemonManager: OpenBurnBarDaemonManager,
        dataStore: DataStore,
        accountManager: AccountManager = .shared,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil
    ) {
        self._settingsManager = Bindable(settingsManager)
        self._daemonManager = Bindable(daemonManager)
        self.dataStore = dataStore
        self.accountManager = accountManager
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
    }

    var body: some View {
        SettingsDeepLinkScrollContainer(route: .agentsRoot) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    header
                    drillRows
                }
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .navigationTitle("Agents")
        .task { await refreshAll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAll() }
        }
    }

    private var header: some View {
        Text("Cloud keys, local CLIs, and local runtimes — every agent that does work for you, on this Mac. Pick a section to manage it.")
            .font(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var drillRows: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            NavigationLink(value: SettingsPageRoute.agentsAccounts) {
                AgentsDrillRow(
                    title: "Accounts",
                    summary: AgentsSummaries.accounts(
                        providerCount: providerCounts.providers,
                        keyCount: providerCounts.keys
                    ),
                    iconName: "key.fill",
                    iconTint: DesignSystem.Colors.ember,
                    statusTint: providerCounts.statusTint
                )
            }
            .buttonStyle(.plain)
            .settingsAnchor(SettingsAnchor.agentsAccounts)

            NavigationLink(value: SettingsPageRoute.agentsCLIs) {
                AgentsDrillRow(
                    title: "CLIs",
                    summary: AgentsSummaries.clis(
                        connected: wiringSnapshot.connectedCount,
                        total: wiringSnapshot.totalCount
                    ),
                    iconName: "terminal.fill",
                    iconTint: DesignSystem.Colors.blaze,
                    statusTint: wiringSnapshot.statusTint
                )
            }
            .buttonStyle(.plain)
            .settingsAnchor(SettingsAnchor.agentsCLIs)

            NavigationLink(value: SettingsPageRoute.agentsRuntimes) {
                AgentsDrillRow(
                    title: "Runtimes",
                    summary: AgentsSummaries.runtimes(settings: settingsManager),
                    iconName: "antenna.radiowaves.left.and.right",
                    iconTint: DesignSystem.Colors.hermesAureate,
                    statusTint: AgentsSummaries.runtimeStatusTint(settings: settingsManager)
                )
            }
            .buttonStyle(.plain)
            .settingsAnchor(SettingsAnchor.agentsRuntimes)

            NavigationLink(value: SettingsPageRoute.agentsAdvanced) {
                AgentsDrillRow(
                    title: "Advanced",
                    summary: "Routing strategy, gateway, browser profiles, chat engines, models, inventory",
                    iconName: "gearshape.2.fill",
                    iconTint: DesignSystem.Colors.textMuted,
                    statusTint: DesignSystem.Colors.textMuted
                )
            }
            .buttonStyle(.plain)
            .settingsAnchor(SettingsAnchor.agentsAdvanced)
        }
    }

    // MARK: - Summary inputs

    private struct ProviderCounts {
        let providers: Int
        let keys: Int
        let hasAttention: Bool

        var statusTint: Color {
            if providers == 0 { return DesignSystem.Colors.textMuted }
            if hasAttention { return DesignSystem.Colors.warning }
            return DesignSystem.Colors.success
        }
    }

    private var providerCounts: ProviderCounts {
        let active = providerAccounts.filter { $0.status != .deleted }
        let grouped = Dictionary(grouping: active, by: \.providerID)
        let hasAttention = active.contains { $0.status == .error || $0.status == .stale }
        return ProviderCounts(
            providers: grouped.keys.count,
            keys: active.count,
            hasAttention: hasAttention
        )
    }

    private struct WiringSnapshot {
        let connectedCount: Int
        let totalCount: Int

        static let empty = WiringSnapshot(connectedCount: 0, totalCount: RoutingClientWiringTarget.allCases.count)

        var statusTint: Color {
            if connectedCount == 0 { return DesignSystem.Colors.textMuted }
            if connectedCount < totalCount { return DesignSystem.Colors.warning }
            return DesignSystem.Colors.success
        }
    }

    private func refreshAll() async {
        await daemonManager.refreshHealth()
        await quotaService.refreshIfNeeded(dataStore: dataStore)
        providerAccounts = (try? dataStore.providerAccountStore.fetchAll()) ?? []
        switcherProfiles = (try? dataStore.switcherStore.fetchAllProfiles()) ?? []
        let wiring = RoutingClientWiring()
        let connected = RoutingClientWiringTarget.allCases
            .filter { wiring.isWired(target: $0) }
            .count
        wiringSnapshot = WiringSnapshot(
            connectedCount: connected,
            totalCount: RoutingClientWiringTarget.allCases.count
        )
    }
}

// MARK: - Drill row

private struct AgentsDrillRow: View {
    let title: String
    let summary: String
    let iconName: String
    let iconTint: Color
    let statusTint: Color

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(iconTint.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 7, height: 7)
                    Text(title)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
                Text(summary)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.36))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Summary helpers (extracted for testability)

/// Pure-function summary strings used in the landing page drill rows. Lifted
/// out as a separate enum so tests can pin the exact wording without
/// instantiating SwiftUI views.
enum AgentsSummaries {
    static func accounts(providerCount: Int, keyCount: Int) -> String {
        switch (providerCount, keyCount) {
        case (0, _):
            return "No accounts yet — bring your first API key"
        case (1, 1):
            return "1 provider · 1 key"
        case (1, let keys):
            return "1 provider · \(keys) keys"
        case (let providers, let keys):
            return "\(providers) providers · \(keys) key\(keys == 1 ? "" : "s")"
        }
    }

    static func clis(connected: Int, total: Int) -> String {
        guard total > 0 else { return "No CLIs detected" }
        if connected == 0 { return "None of \(total) CLIs connected yet" }
        if connected == total { return "All \(total) CLIs connected" }
        return "\(connected) of \(total) CLIs connected"
    }

    /// Pulls the *user-facing* runtime status off the settings manager. We
    /// don't probe live process state on the landing page — the value here
    /// is "Hermes auto-launch on / Pi Manual / OpenClaw not set", drilling in
    /// shows the live state.
    @MainActor
    static func runtimes(settings: SettingsManager) -> String {
        var parts: [String] = []
        if settings.launchHermesWithOpenBurnBar { parts.append("Hermes auto") }
        if settings.launchPiAgentsWithOpenBurnBar { parts.append("Pi auto") }
        if !settings.openClawGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("OpenClaw set")
        }
        if parts.isEmpty {
            return "Hermes, Pi, and OpenClaw — none auto-launching"
        }
        return parts.joined(separator: " · ")
    }

    @MainActor
    static func runtimeStatusTint(settings: SettingsManager) -> Color {
        if settings.launchHermesWithOpenBurnBar || settings.launchPiAgentsWithOpenBurnBar {
            return DesignSystem.Colors.success
        }
        return DesignSystem.Colors.textMuted
    }
}

// MARK: - Accounts detail

/// Drill destination for `Accounts`. Renders only the Accounts section of
/// the underlying Connections page so the user lands directly on the
/// multi-account-per-provider list without scrolling past unrelated content.
struct AgentsAccountsView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var daemonManager: OpenBurnBarDaemonManager
    let dataStore: DataStore
    let accountManager: AccountManager

    init(
        settingsManager: SettingsManager,
        daemonManager: OpenBurnBarDaemonManager,
        dataStore: DataStore,
        accountManager: AccountManager = .shared
    ) {
        self._settingsManager = Bindable(settingsManager)
        self._daemonManager = Bindable(daemonManager)
        self.dataStore = dataStore
        self.accountManager = accountManager
    }

    var body: some View {
        ConnectionsSettingsView(
            settingsManager: settingsManager,
            daemonManager: daemonManager,
            dataStore: dataStore,
            accountManager: accountManager,
            section: .accountsOnly
        )
    }
}

// MARK: - CLIs detail

/// Drill destination for `CLIs`. Top half is the existing per-CLI Connect
/// rows from the Connections layout. Bottom half embeds the Account
/// Switcher's CLI profile management so profile reorder / set-primary /
/// change-account stays a single drill away.
struct AgentsCLIsView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var daemonManager: OpenBurnBarDaemonManager
    let dataStore: DataStore
    let accountManager: AccountManager

    init(
        settingsManager: SettingsManager,
        daemonManager: OpenBurnBarDaemonManager,
        dataStore: DataStore,
        accountManager: AccountManager = .shared
    ) {
        self._settingsManager = Bindable(settingsManager)
        self._daemonManager = Bindable(daemonManager)
        self.dataStore = dataStore
        self.accountManager = accountManager
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                Text("Connect each CLI to the local gateway so OpenBurnBar can route requests through your shared key pool. Add multiple profiles per CLI to switch between authenticated sessions.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Wiring rows — keeps the smart-Connect state machine.
                ConnectionsSettingsView(
                    settingsManager: settingsManager,
                    daemonManager: daemonManager,
                    dataStore: dataStore,
                    accountManager: accountManager,
                    section: .appsOnly
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().background(DesignSystem.Colors.border)

                // Profile management — embed the switcher in cliOnly mode.
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("CLI profiles")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Switch any CLI between multiple authenticated profiles. Each profile keeps its own login directory and environment.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    AccountSwitcherSettingsView(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        mode: .cliOnly
                    )
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .navigationTitle("CLIs")
    }
}

// MARK: - Runtimes detail

/// Drill destination for `Runtimes`. Five iOS-style drill rows for the
/// local AI runtimes and their remote relays. Each row navigates to the
/// existing detail view unchanged — this page is purely a re-shelf so the
/// retired AI Environments landing isn't reintroduced.
struct AgentsRuntimesView: View {
    @Bindable var settingsManager: SettingsManager
    let dataStore: DataStore
    let cloudSyncService: CloudSyncService?
    let iCloudSessionMirrorService: ICloudSessionMirrorService?

    @State private var hermesRuntimeLauncher: HermesRuntimeLauncher
    @State private var piAgentRuntimeAdapter: PiAgentRuntimeAdapter

    init(
        settingsManager: SettingsManager,
        dataStore: DataStore,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil
    ) {
        self._settingsManager = Bindable(settingsManager)
        self.dataStore = dataStore
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
        self._hermesRuntimeLauncher = State(initialValue: HermesRuntimeLauncher())
        let preferredInstance: String? = {
            let trimmed = settingsManager.piAgentSelectedInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let redisURL: URL? = {
            let trimmed = settingsManager.piAgentRedisURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(string: trimmed)
        }()
        self._piAgentRuntimeAdapter = State(initialValue: PiAgentRuntimeAdapter(
            preferredInstanceID: preferredInstance,
            redisURL: redisURL
        ))
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    HermesGatewayDetailView(
                        settingsManager: settingsManager,
                        hermesRuntimeLauncher: hermesRuntimeLauncher
                    )
                } label: {
                    SettingsDrillRow(
                        icon: "antenna.radiowaves.left.and.right",
                        iconTint: DesignSystem.Colors.hermesAureate,
                        title: "Hermes Gateway",
                        subtitle: "Local webapi on :8642, auto-launch with OpenBurnBar",
                        value: settingsManager.launchHermesWithOpenBurnBar ? "Auto" : "Manual",
                        valueTint: settingsManager.launchHermesWithOpenBurnBar
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.textMuted,
                        logoProvider: .hermes
                    )
                }

                NavigationLink {
                    RemoteRelayDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "iphone.radiowaves.left.and.right",
                        iconTint: DesignSystem.Colors.coral,
                        title: "Hermes Remote Relay",
                        subtitle: "Let iPhone and iPad chat with this Mac's Hermes over the network",
                        value: settingsManager.hermesRemoteRelayEnabled ? "On" : "Off",
                        valueTint: settingsManager.hermesRemoteRelayEnabled
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.textMuted,
                        logoProvider: .hermes
                    )
                }

                NavigationLink {
                    PiAgentDetailView(
                        settingsManager: settingsManager,
                        piAgentRuntimeAdapter: piAgentRuntimeAdapter
                    )
                } label: {
                    SettingsDrillRow(
                        icon: "circle.hexagongrid.fill",
                        iconTint: DesignSystem.Colors.purple,
                        title: "Pi Agent Instances",
                        subtitle: "Pi gateway endpoint, optional Redis, instance selection",
                        value: settingsManager.launchPiAgentsWithOpenBurnBar ? "Auto" : "Manual",
                        valueTint: settingsManager.launchPiAgentsWithOpenBurnBar
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.textMuted,
                        logoProvider: .piAgent
                    )
                }

                NavigationLink {
                    RemoteRelayPiDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "iphone.gen3.radiowaves.left.and.right",
                        iconTint: DesignSystem.Colors.purple,
                        title: "Pi Remote Relay",
                        subtitle: "Let iPhone and iPad chat with this Mac's Pi over the network",
                        value: settingsManager.piRemoteRelayEnabled ? "On" : "Off",
                        valueTint: settingsManager.piRemoteRelayEnabled
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.textMuted,
                        logoProvider: .piAgent
                    )
                }

                NavigationLink {
                    OpenClawGatewayDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "network.badge.shield.half.filled",
                        iconTint: DesignSystem.Colors.teal,
                        title: "OpenClaw Gateway",
                        subtitle: "OpenAI-compatible gateway (default 127.0.0.1:18789)",
                        value: openClawHostDisplay,
                        logoProvider: .openClaw
                    )
                }
            } header: {
                Text("Runtimes")
            } footer: {
                Text("Each runtime listens locally and can be exposed to your iPhone or iPad through its remote relay. Open a row to manage that runtime.")
                    .font(DesignSystem.Typography.tiny)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(DesignSystem.Colors.background)
        .navigationTitle("Runtimes")
    }

    private var openClawHostDisplay: String {
        let raw = settingsManager.openClawGatewayBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), let host = url.host else {
            return "Not set"
        }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}

// MARK: - Advanced detail

/// Drill destination for `Advanced`. Holds the routing strategy and local
/// gateway controls from Connections plus the rarely-touched bits from the
/// retired Account Switcher (browser profiles) and AI Environments
/// (chat-engine visibility, Hermes models, inventory import, setup wizard).
struct AgentsAdvancedView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var daemonManager: OpenBurnBarDaemonManager
    let dataStore: DataStore
    let accountManager: AccountManager
    let cloudSyncService: CloudSyncService?
    let iCloudSessionMirrorService: ICloudSessionMirrorService?

    @State private var inventoryImportService: HermesInventoryImportService

    init(
        settingsManager: SettingsManager,
        daemonManager: OpenBurnBarDaemonManager,
        dataStore: DataStore,
        accountManager: AccountManager = .shared,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil
    ) {
        self._settingsManager = Bindable(settingsManager)
        self._daemonManager = Bindable(daemonManager)
        self.dataStore = dataStore
        self.accountManager = accountManager
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
        self._inventoryImportService = State(initialValue: HermesInventoryImportService(
            dataStore: dataStore,
            settingsManager: settingsManager,
            cloudSyncService: cloudSyncService,
            iCloudMirrorService: iCloudSessionMirrorService
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                // Routing strategy + local gateway (lifted from Connections advanced disclosure).
                ConnectionsSettingsView(
                    settingsManager: settingsManager,
                    daemonManager: daemonManager,
                    dataStore: dataStore,
                    accountManager: accountManager,
                    section: .advancedOnly
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().background(DesignSystem.Colors.border)

                // Browser profiles (Account Switcher embed in browserOnly mode).
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Browser profiles")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Launch isolated browser profiles for Chrome or Safari so you can keep separate sessions for different provider accounts.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    AccountSwitcherSettingsView(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        mode: .browserOnly
                    )
                }

                Divider().background(DesignSystem.Colors.border)

                // Hermes follow-on settings as drill rows.
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Chat surfaces & inventory")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Which engines appear in the dashboard, which models Hermes routes through, and one-time setup tasks.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 0) {
                        NavigationLink {
                            ChatEnginesDetailView(settingsManager: settingsManager)
                        } label: {
                            SettingsDrillRow(
                                icon: "cpu",
                                iconTint: DesignSystem.Colors.whimsy,
                                title: "Chat engines",
                                subtitle: "Toggle which engines appear in the dashboard and menu bar",
                                value: "\(settingsManager.enabledChatBackends.count) on"
                            )
                        }
                        Divider().background(DesignSystem.Colors.border)
                        NavigationLink {
                            HermesInventoryImportDetailView(
                                inventoryImportService: inventoryImportService
                            )
                        } label: {
                            SettingsDrillRow(
                                icon: "tray.and.arrow.down.fill",
                                iconTint: DesignSystem.Colors.hermesAureate,
                                title: "Import Hermes chats",
                                subtitle: "Bring pre-OpenBurnBar Hermes conversations into the local index",
                                value: inventoryStatusValue,
                                logoProvider: .hermes
                            )
                        }
                        Divider().background(DesignSystem.Colors.border)
                        NavigationLink {
                            HermesSetupDetailView(
                                settingsManager: settingsManager,
                                dataStore: dataStore,
                                cloudSyncService: cloudSyncService,
                                iCloudSessionMirrorService: iCloudSessionMirrorService
                            )
                        } label: {
                            SettingsDrillRow(
                                icon: "wand.and.stars",
                                iconTint: DesignSystem.Colors.amber,
                                title: "Setup assistant",
                                subtitle: "Guided Hermes setup, mark onboarding complete",
                                value: settingsManager.hermesSetupWizardCompleted ? "Done" : "Pending",
                                valueTint: settingsManager.hermesSetupWizardCompleted
                                    ? DesignSystem.Colors.success
                                    : DesignSystem.Colors.warning,
                                logoProvider: .hermes
                            )
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.32))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
                    )
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .navigationTitle("Advanced")
    }

    private var inventoryStatusValue: String {
        switch inventoryImportService.phase {
        case .scanning: return "Scanning"
        case .importing: return "Importing"
        case .complete: return "Imported"
        case .failed: return "Error"
        case .ready: return "Ready"
        case .idle:
            return inventoryImportService.hasImportableInventory ? "Ready" : "—"
        }
    }
}
