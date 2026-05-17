import AppKit
import OpenBurnBarCore
import SwiftUI

// MARK: - Settings → Connections

/// Settings → **Connections** — one tab to manage every AI key and CLI on
/// this Mac.
///
/// Replaces the prior two-screen split (Providers + Routing Pools). The
/// premise is unchanged: multiple accounts per provider, automatic failover
/// when one runs out, and one-click wiring for each CLI. The interface is
/// dramatically simpler: a flat per-provider grouped list of accounts on top,
/// a row per CLI with a single smart Connect button below, and everything
/// else (router strategy, gateway controls, log sources, smart-display
/// signals) tucked into a single Advanced disclosure.
struct ConnectionsSettingsView: View {
    /// Which slice of the connections surface this instance should render.
    /// The Agents tab's hub-and-spoke layout slices the page across three
    /// drill destinations; `.all` keeps the legacy single-page rendering.
    enum Section: Hashable {
        case all
        case accountsOnly
        case appsOnly
        case advancedOnly
    }

    @Bindable var settingsManager: SettingsManager
    @Bindable var daemonManager: OpenBurnBarDaemonManager
    let dataStore: DataStore
    let accountManager: AccountManager
    let section: Section

    @State private var viewModel = ConnectionsViewModel()
    @State private var quotaService = ProviderQuotaService.shared
    @State private var wizardProviderID: ProviderWizardTarget?
    @State private var providerAccounts: [ProviderAccountDoc] = []
    @State private var providerAccountLoadError: String?
    @State private var switcherProfiles: [SwitcherProfileRecord] = []
    @State private var switcherProfileLoadError: String?
    @State private var externalAuthStates: [String: CLIAuthInfo] = [:]
    @State private var isAdvancedExpanded = false

    init(
        settingsManager: SettingsManager,
        daemonManager: OpenBurnBarDaemonManager,
        dataStore: DataStore,
        accountManager: AccountManager = .shared,
        section: Section = .all
    ) {
        self._settingsManager = Bindable(settingsManager)
        self._daemonManager = Bindable(daemonManager)
        self.dataStore = dataStore
        self.accountManager = accountManager
        self.section = section
        // When the Agents tab embeds the advanced slice, it should default
        // to expanded — the user just drilled in specifically to see those
        // controls.
        self._isAdvancedExpanded = State(initialValue: section == .advancedOnly)
    }

    var body: some View {
        SettingsDeepLinkScrollContainer(route: .connectionsRoot) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    if section == .all {
                        header
                    }
                    if section == .all || section == .accountsOnly {
                        accountsSection
                            .settingsAnchor(SettingsAnchor.connectionsAccounts)
                    }
                    if section == .all || section == .appsOnly {
                        appsSection
                            .settingsAnchor(SettingsAnchor.connectionsApps)
                    }
                    if section == .all || section == .advancedOnly {
                        advancedDisclosure
                            .settingsAnchor(SettingsAnchor.connectionsAdvanced)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .navigationTitle(navigationTitleForSection)
        .sheet(item: $wizardProviderID) { target in
            ProviderPlanWizardView(
                daemonManager: daemonManager,
                dataStore: dataStore,
                initialProviderID: target.providerID,
                startsAtProviderSelection: target.startsAtProviderSelection
            ) {
                wizardProviderID = nil
                loadAccountData()
                Task { await quotaService.refreshIfNeeded(dataStore: dataStore, maxAge: 0) }
            }
        }
        .sheet(item: snippetTargetBinding) { boxed in
            SnippetSheet(
                target: boxed.target,
                snippet: viewModel.snippet(for: boxed.target, settings: settingsManager),
                isCopied: viewModel.copiedSnippetTarget == boxed.target,
                onCopy: { viewModel.copySnippet(for: boxed.target, settings: settingsManager) },
                onDismiss: { viewModel.snippetTarget = nil }
            )
        }
        .task {
            viewModel.refreshWiringState()
            await daemonManager.refreshHealth()
            loadAccountData()
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
            await quotaService.refreshIfNeeded(dataStore: dataStore)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Bring API keys from one or more providers. Add more keys for the same provider any time — OpenBurnBar fails over to the next available key automatically when one runs out. Then connect your CLIs below in one click.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var navigationTitleForSection: String {
        switch section {
        case .all: return "Connections"
        case .accountsOnly: return "Accounts"
        case .appsOnly: return "CLIs"
        case .advancedOnly: return "Advanced"
        }
    }

    // MARK: - Accounts

    @ViewBuilder
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Accounts")
                    .font(DesignSystem.Typography.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Button {
                    wizardProviderID = .addAccount
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .buttonStyle(ConnectionsAddAccountButtonStyle(size: .compact))
                .accessibilityLabel("Add account")
            }

            if let providerAccountLoadError {
                inlineErrorCallout(providerAccountLoadError)
            } else {
                if let switcherProfileLoadError {
                    inlineErrorCallout("Could not load local OAuth profiles: \(switcherProfileLoadError)")
                }

                if !hasAnyAccount {
                    emptyAccountsCard
                } else {
                    VStack(spacing: DesignSystem.Spacing.md) {
                        ForEach(accountGroups, id: \.providerID) { group in
                            ProviderAccountGroup(
                                providerID: group.providerID,
                                accounts: group.accounts,
                                externalAccounts: group.externalAccounts,
                                routingState: quotaService.routingStatesByProviderID[group.providerID],
                                quotaWindowsForAccount: quotaWindows(for:),
                                quotaWindowsForExternalAccount: quotaWindows(for:),
                                onTapAccount: { account in
                                    wizardProviderID = ProviderWizardTarget(providerID: account.providerID.rawValue)
                                },
                                onTapExternalAccount: { account in
                                    wizardProviderID = ProviderWizardTarget(providerID: account.providerID.rawValue)
                                },
                                onAddAnother: {
                                    wizardProviderID = ProviderWizardTarget(providerID: group.providerID.rawValue)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private var emptyAccountsCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.ember.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "key.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.ember)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("No accounts yet")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Bring an API key from OpenAI, Anthropic, or any other provider — and add as many keys per provider as you want. When one runs out, OpenBurnBar falls over to the next automatically.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button {
                    wizardProviderID = .addAccount
                } label: {
                    Label("Add your first account", systemImage: "plus.circle.fill")
                }
                .buttonStyle(ConnectionsAddAccountButtonStyle(size: .regular))
                Spacer()
            }
            .padding(.top, DesignSystem.Spacing.xs)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func inlineErrorCallout(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.error)
            VStack(alignment: .leading, spacing: 2) {
                Text("Could not load accounts")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(message)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.error.opacity(0.08))
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    // MARK: - Apps

    @ViewBuilder
    private var appsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Apps")
                    .font(DesignSystem.Typography.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
            }

            ProxyModelCatalogPanel(
                models: viewModel.proxyModels,
                state: viewModel.proxyModelCatalogState,
                endpoint: gatewayModelsEndpoint,
                onRefresh: {
                    Task {
                        await viewModel.refreshProxyModelCatalog(settings: settingsManager)
                        await viewModel.refreshWiringState(settings: settingsManager)
                    }
                },
                onStartGateway: {
                    Task {
                        viewModel.enableLocalGateway(settings: settingsManager)
                        await restartLocalGateway()
                        await viewModel.refreshProxyModelCatalog(settings: settingsManager)
                        await viewModel.refreshWiringState(settings: settingsManager)
                    }
                }
            )

            if !hasAnyAccount {
                Text("Add an account first, then connect Claude Code, Codex, OpenCode, Forge, or Droid to use it.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.25))
                    )
                    .opacity(0.7)
            } else {
                VStack(spacing: DesignSystem.Spacing.xs) {
                    ForEach(RoutingClientWiringTarget.allCases) { target in
                        AppConnectRow(
                            target: target,
                            state: viewModel.state(for: target),
                            isDisabled: !hasAccountFor(target: target),
                            onConnect: {
                                Task {
                                    await viewModel.connect(
                                        target: target,
                                        settings: settingsManager,
                                        restartGateway: restartLocalGateway
                                    )
                                }
                            },
                            onTest: { Task { await viewModel.test(target: target, settings: settingsManager) } },
                            onSyncModels: {
                                Task {
                                    await viewModel.syncModels(
                                        target: target,
                                        settings: settingsManager,
                                        restartGateway: restartLocalGateway
                                    )
                                }
                            },
                            onRepair: {
                                Task {
                                    await viewModel.connect(
                                        target: target,
                                        settings: settingsManager,
                                        restartGateway: restartLocalGateway
                                    )
                                }
                            },
                            onDisconnect: { Task { await viewModel.disconnect(target: target) } },
                            onShowSnippet: { viewModel.snippetTarget = target },
                            onRevealFile: { viewModel.revealConfigFile(target: target) },
                            configPath: viewModel.configPath(for: target)
                        )
                    }
                }
            }
        }
    }

    /// True only when the gateway has a route-ready daemon credential for this
    /// CLI's wire format. Local CLI OAuth sign-ins are shown elsewhere for
    /// account/quota visibility, but they do not unlock proxy routing.
    private func hasAccountFor(target: RoutingClientWiringTarget) -> Bool {
        ConnectionsRouteReadiness.hasRouteReadyProvider(
            for: target,
            configurations: daemonManager.providerConfigurations
        )
    }

    private var gatewayModelsEndpoint: String {
        let host = settingsManager.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "127.0.0.1"
            : settingsManager.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = settingsManager.gatewayPort > 0 ? settingsManager.gatewayPort : 8317
        return "http://\(host):\(port)/v1/models"
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                routingStrategyCard
                localGatewayCard
                Divider().background(DesignSystem.Colors.border)
                advancedFooter
            }
            .padding(.top, DesignSystem.Spacing.sm)
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text("Advanced")
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Text("Routing strategy, local gateway, daemon settings")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var routingStrategyCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: daemonManager.routerMode == .intelligentModelRouter ? "brain.head.profile" : "rectangle.2.swap")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.blaze)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Routing strategy")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("How OpenBurnBar picks an account for each request.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                Picker("Routing strategy", selection: Binding(
                    get: { daemonManager.routerMode },
                    set: { mode in
                        Task { @MainActor in
                            await daemonManager.setRouterMode(mode)
                            await daemonManager.refreshHealth()
                        }
                    }
                )) {
                    Text("Smart").tag(ProviderRouterMode.intelligentModelRouter)
                    Text("Stay inside one provider").tag(ProviderRouterMode.providerFamilyFailover)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                .disabled(daemonManager.isBusy)
            }
            Text(daemonManager.routerMode == .intelligentModelRouter
                ? "Smart picks the best available account across providers using task fit, account health, cost, and latency."
                : "When the active account runs out, fail over only to other accounts for the same provider.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.5))
        )
    }

    private var localGatewayCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "powerplug.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local gateway")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Where your CLIs send requests. Defaults to localhost — most users never change this.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                Toggle("", isOn: $settingsManager.gatewayEnabled)
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: DesignSystem.Colors.blaze))
            }

            if settingsManager.gatewayEnabled {
                HStack(spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Host")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        TextField("127.0.0.1", text: $settingsManager.gatewayHost)
                            .textFieldStyle(.roundedBorder)
                            .font(DesignSystem.Typography.monoSmall)
                            .frame(width: 160)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Port")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        TextField("8317", value: $settingsManager.gatewayPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(DesignSystem.Typography.monoSmall)
                            .frame(width: 90)
                    }
                    let isLoopback = isGatewayLoopback(settingsManager.gatewayHost)
                    if !isLoopback {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Token (required for non-loopback)")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.warning)
                            SecureField("Bearer token", text: $settingsManager.gatewayAuthToken)
                                .textFieldStyle(.roundedBorder)
                                .font(DesignSystem.Typography.monoSmall)
                                .frame(width: 200)
                        }
                    }
                    Spacer()
                    Button {
                        resetLocalDefaults()
                    } label: {
                        Label("Reset to local defaults", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.5))
        )
    }

    private var advancedFooter: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Need more knobs? Daemon health, controller runtime, log sources, quota smart-displays, and observed agent logs all live under Settings → Daemon and elsewhere.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Data assembly

    /// External OAuth-only "accounts" (e.g. `claude` / `codex` CLI logins)
    /// that surface alongside API-key accounts so the multi-account list
    /// honours every credential source the daemon can route through. Held in
    /// its own type so the Accounts list can render API and OAuth rows in one
    /// flow.
    struct ExternalOAuthAccount: Identifiable, Hashable {
        let id: String
        let providerID: ProviderID
        let cliType: SwitcherCLIProfileType
        let label: String
        let detail: String?
        let statusText: String
        let isCurrentLogin: Bool
        let isDisabled: Bool
        let profileID: String?
    }

    private struct AccountGroup {
        let providerID: ProviderID
        let accounts: [ProviderAccountDoc]
        let externalAccounts: [ExternalOAuthAccount]
    }

    private var activeAccounts: [ProviderAccountDoc] {
        providerAccounts.filter { $0.status != .deleted }
    }

    /// External OAuth account inventory derived from the daemon's switcher
    /// profile store and the default local CLI login state.
    private var activeExternalOAuthAccounts: [ExternalOAuthAccount] {
        visibleExternalOAuthAccounts()
    }

    /// True iff the user has at least one account of either kind. Used to
    /// pick the empty-state path on the Accounts and Apps sections.
    private var hasAnyAccount: Bool {
        !activeAccounts.isEmpty
            || !activeExternalOAuthAccounts.isEmpty
            || ConnectionsRouteReadiness.hasAnyRouteReadyProvider(
                configurations: daemonManager.providerConfigurations
            )
    }

    /// Bridge for the existing wizard sheet completion handler. Reloads the
    /// flat account list so the new account appears immediately.
    private func loadAccountData() {
        loadAccounts()
        loadSwitcherProfiles()
        refreshExternalAuthStates()
        viewModel.refreshWiringState()
    }

    private func restartLocalGateway() async {
        await daemonManager.installAndStart()
        await daemonManager.refreshHealth()
    }

    private var accountGroups: [AccountGroup] {
        let groupedAPI = Dictionary(grouping: activeAccounts, by: \.providerID)
        let groupedOAuth = Dictionary(grouping: activeExternalOAuthAccounts, by: \.providerID)
        let allProviderIDs = Set(groupedAPI.keys).union(groupedOAuth.keys)
        return allProviderIDs
            .map { providerID -> AccountGroup in
                let sortedAccounts = (groupedAPI[providerID] ?? []).sorted { lhs, rhs in
                    if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
                    if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
                    return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                }
                let externals = (groupedOAuth[providerID] ?? []).sorted { lhs, rhs in
                    if lhs.isCurrentLogin != rhs.isCurrentLogin {
                        return lhs.isCurrentLogin && !rhs.isCurrentLogin
                    }
                    if lhs.isDisabled != rhs.isDisabled {
                        return !lhs.isDisabled && rhs.isDisabled
                    }
                    return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                }
                return AccountGroup(
                    providerID: providerID,
                    accounts: sortedAccounts,
                    externalAccounts: externals
                )
            }
            .sorted { lhs, rhs in
                providerDisplayName(lhs.providerID).localizedCaseInsensitiveCompare(providerDisplayName(rhs.providerID)) == .orderedAscending
            }
    }

    private func loadAccounts() {
        do {
            providerAccounts = try dataStore.providerAccountStore.fetchAll()
            providerAccountLoadError = nil
        } catch {
            providerAccounts = []
            providerAccountLoadError = error.localizedDescription
        }
    }

    private func loadSwitcherProfiles() {
        do {
            switcherProfiles = try dataStore.switcherStore.fetchAllProfiles()
            switcherProfileLoadError = nil
        } catch {
            switcherProfiles = []
            switcherProfileLoadError = error.localizedDescription
        }
    }

    private func refreshExternalAuthStates() {
        var next: [String: CLIAuthInfo] = [:]
        for cliType in [SwitcherCLIProfileType.codex, .claude] {
            next[cliType.rawValue] = CLIAuthDiscovery.discoverAuthState(for: cliType)
        }
        externalAuthStates = next
    }

    private func visibleExternalOAuthAccounts() -> [ExternalOAuthAccount] {
        let storedAccounts = switcherProfiles.compactMap { profile -> ExternalOAuthAccount? in
            guard profile.targetKind == .cli,
                  let cliType = profile.cliType,
                  cliType == .codex || cliType == .claude else {
                return nil
            }

            return ExternalOAuthAccount(
                id: profile.id,
                providerID: externalProviderID(for: cliType),
                cliType: cliType,
                label: externalAccountLabel(for: profile, cliType: cliType),
                detail: normalizedString(profile.cliMetadata?.configDirectory),
                statusText: "Isolated \(cliType.displayName) OAuth profile.",
                isCurrentLogin: false,
                isDisabled: profile.isDisabled,
                profileID: profile.id
            )
        }

        let currentAccounts = [SwitcherCLIProfileType.codex, .claude].compactMap { cliType -> ExternalOAuthAccount? in
            guard let authInfo = externalAuthStates[cliType.rawValue],
                  isExternalAuthConnected(authInfo),
                  !storedProfileDuplicatesCurrentAuth(cliType: cliType, authInfo: authInfo) else {
                return nil
            }

            let identity = normalizedString(authInfo.accountDescription)
                ?? normalizedString(authInfo.configDirectory)
                ?? "default"
            let statusText = authInfo.authState == .apiKeyPresent
                ? "Detected from the default local \(cliType.displayName) API-key config."
                : "Detected from the default local \(cliType.displayName) OAuth sign-in."

            return ExternalOAuthAccount(
                id: "current-\(cliType.rawValue)-\(identity)",
                providerID: externalProviderID(for: cliType),
                cliType: cliType,
                label: normalizedString(authInfo.accountDescription) ?? "Current \(cliType.displayName) login",
                detail: normalizedString(authInfo.configDirectory),
                statusText: statusText,
                isCurrentLogin: true,
                isDisabled: false,
                profileID: nil
            )
        }

        return currentAccounts + storedAccounts
    }

    private func externalProviderID(for cliType: SwitcherCLIProfileType) -> ProviderID {
        switch cliType {
        case .codex:
            return .openAI
        case .claude:
            return .anthropic
        case .opencode:
            return .openCode
        }
    }

    private func storedProfileDuplicatesCurrentAuth(cliType: SwitcherCLIProfileType, authInfo: CLIAuthInfo) -> Bool {
        let authAccount = normalizedString(authInfo.accountDescription)
        let authDirectory = normalizedString(authInfo.configDirectory)

        return switcherProfiles.contains { profile in
            guard profile.targetKind == .cli,
                  profile.cliType == cliType else {
                return false
            }

            if let authAccount,
               let profileAccount = normalizedString(profile.cliMetadata?.accountDescription),
               profileAccount.caseInsensitiveCompare(authAccount) == .orderedSame {
                return true
            }

            if let authDirectory,
               let profileDirectory = normalizedString(profile.cliMetadata?.configDirectory),
               profileDirectory == authDirectory {
                return true
            }

            return false
        }
    }

    private func externalAccountLabel(for profile: SwitcherProfileRecord, cliType: SwitcherCLIProfileType) -> String {
        normalizedString(profile.cliMetadata?.accountDescription)
            ?? normalizedString(profile.cliMetadata?.displayLabel)
            ?? normalizedString(profile.displayName)
            ?? "\(cliType.displayName) OAuth profile"
    }

    private func quotaWindows(for account: ProviderAccountDoc) -> [SwitcherQuotaWindowDisplay] {
        let accountSnapshot = quotaService.snapshot(providerID: account.providerID, accountID: account.id)
        return switcherQuotaWindowDisplays(snapshot: accountSnapshot)
    }

    private func quotaWindows(for account: ExternalOAuthAccount) -> [SwitcherQuotaWindowDisplay] {
        guard let provider = account.cliType.agentProvider else { return [] }

        if let accountSnapshot = exactExternalQuotaSnapshot(for: account, provider: provider) {
            let windows = switcherQuotaWindowDisplays(snapshot: accountSnapshot)
            if !windows.isEmpty { return windows }
        }

        if account.isCurrentLogin {
            return switcherQuotaWindowDisplays(snapshot: quotaService.snapshot(for: provider))
        }

        return []
    }

    private func exactExternalQuotaSnapshot(
        for account: ExternalOAuthAccount,
        provider: AgentProvider
    ) -> ProviderQuotaSnapshot? {
        let snapshots = quotaService.snapshots(for: provider.providerID)

        if let profileID = account.profileID {
            let normalizedProfileID = normalizedQuotaIdentifier(profileID)
            let normalizedProfileSourceIDs = Set([
                "switcher-cli:\(account.cliType.rawValue):\(profileID)",
                "switcher:\(profileID)",
            ].compactMap(normalizedQuotaIdentifier))
            return snapshots.first { snapshot in
                normalizedQuotaIdentifier(snapshot.accountID) == normalizedProfileID
                    || normalizedQuotaIdentifier(snapshot.sourceId).map { normalizedProfileSourceIDs.contains($0) } == true
            }
        }

        return snapshots.first { snapshot in
            normalizedString(snapshot.accountLabel)?.caseInsensitiveCompare(account.label) == .orderedSame
        }
    }

    private func isExternalAuthConnected(_ authInfo: CLIAuthInfo) -> Bool {
        switch authInfo.authState {
        case .authenticated, .apiKeyPresent:
            return true
        case .notAuthenticated, .notInstalled:
            return false
        }
    }

    private func providerDisplayName(_ providerID: ProviderID) -> String {
        if let catalogProvider = BurnBarCatalogLoader.bundledCatalog.provider(id: providerID.rawValue) {
            return catalogProvider.displayName
        }
        return AgentProvider.fromProviderID(providerID)?.displayName ?? providerID.rawValue
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedQuotaIdentifier(_ value: String?) -> String? {
        normalizedString(value)?.lowercased()
    }

    private func resetLocalDefaults() {
        settingsManager.gatewayHost = "127.0.0.1"
        settingsManager.gatewayPort = 8317
        settingsManager.gatewayAuthToken = ""
    }

    private func isGatewayLoopback(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty
            || normalized == "127.0.0.1"
            || normalized == "localhost"
            || normalized == "::1"
    }

    // MARK: - Sheet helpers

    private var snippetTargetBinding: Binding<SnippetTargetBox?> {
        Binding(
            get: { viewModel.snippetTarget.map { SnippetTargetBox(target: $0) } },
            set: { viewModel.snippetTarget = $0?.target }
        )
    }

    private struct SnippetTargetBox: Identifiable {
        let target: RoutingClientWiringTarget
        var id: String { target.id }
    }

}

enum ConnectionsRouteReadiness {
    static func hasAnyRouteReadyProvider(
        configurations: [OpenBurnBarDaemonProviderConfiguration]
    ) -> Bool {
        configurations.contains { configuration in
            isRouteReady(configuration)
        }
    }

    static func hasRouteReadyProvider(
        for target: RoutingClientWiringTarget,
        configurations: [OpenBurnBarDaemonProviderConfiguration]
    ) -> Bool {
        let expectedFormat: BurnBarProviderFormatFamily = target == .claudeCode
            ? .anthropic
            : .openaiCompat

        return configurations.contains { configuration in
            guard isRouteReady(configuration),
                  formatFamily(forProviderID: configuration.providerID) == expectedFormat else {
                return false
            }
            return true
        }
    }

    private static func isRouteReady(
        _ configuration: OpenBurnBarDaemonProviderConfiguration
    ) -> Bool {
        configuration.isEnabled
            && configuration.hasRoutingCapability
            && configuration.credentialSlots.contains { slot in
                slot.isEnabled && slot.status == .ready
            }
    }

    private static func formatFamily(forProviderID providerID: String) -> BurnBarProviderFormatFamily {
        if let catalogProvider = BurnBarCatalogLoader.bundledCatalog.provider(id: providerID) {
            return catalogProvider.formatFamily
        }
        if let agentProvider = AgentProvider.fromProviderID(ProviderID(rawValue: providerID))
            ?? AgentProvider.fromCatalogProviderID(providerID),
           agentProvider == .claudeCode {
            return .anthropic
        }
        return .openaiCompat
    }
}

// MARK: - Provider Account Group

/// One provider's slice of the Accounts list. Shows the failover chain
/// (Active now / Next fallback chips), each account with a single status
/// line, and a "+ Add another <Provider> account" button that anchors the
/// multi-account-per-provider premise.
private struct ProviderAccountGroup: View {
    let providerID: ProviderID
    let accounts: [ProviderAccountDoc]
    var externalAccounts: [ConnectionsSettingsView.ExternalOAuthAccount] = []
    let routingState: ProviderRoutingStateSnapshot?
    var quotaWindowsForAccount: (ProviderAccountDoc) -> [SwitcherQuotaWindowDisplay] = { _ in [] }
    var quotaWindowsForExternalAccount: (ConnectionsSettingsView.ExternalOAuthAccount) -> [SwitcherQuotaWindowDisplay] = { _ in [] }
    let onTapAccount: (ProviderAccountDoc) -> Void
    var onTapExternalAccount: (ConnectionsSettingsView.ExternalOAuthAccount) -> Void = { _ in }
    let onAddAnother: () -> Void

    private var provider: AgentProvider? {
        AgentProvider.fromProviderID(providerID) ?? AgentProvider.fromCatalogProviderID(providerID.rawValue)
    }

    private var providerDisplayName: String {
        if let catalogProvider = BurnBarCatalogLoader.bundledCatalog.provider(id: providerID.rawValue) {
            return catalogProvider.displayName
        }
        return provider?.displayName ?? providerID.rawValue
    }

    private var activeAccountID: String? { routingState?.activeAccount?.accountID }
    private var nextFallbackAccountID: String? { routingState?.nextFallback?.accountID }
    private var totalAccountCount: Int { accounts.count + externalAccounts.count }

    /// One-line rotation summary derived from the accounts themselves. The
    /// user never sees the internal `ProviderRouterMode` distinction — they
    /// just see "auto-rotate" / "<account> first" so they know what to expect.
    private var rotationSummary: String {
        if totalAccountCount == 1 { return "single account" }
        if let preferred = accounts.first(where: { $0.isDefault }) {
            return "tries \(preferred.label) first"
        }
        return "auto-rotate"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header
            ForEach(accounts) { account in
                AccountRowView(
                    account: account,
                    isActive: account.id == activeAccountID,
                    isNextFallback: account.id == nextFallbackAccountID,
                    cooldownUntil: cooldownUntil(for: account.id),
                    quotaWindows: quotaWindowsForAccount(account),
                    onTap: { onTapAccount(account) }
                )
            }
            ForEach(externalAccounts) { account in
                ExternalOAuthAccountRowView(
                    account: account,
                    quotaWindows: quotaWindowsForExternalAccount(account),
                    onTap: { onTapExternalAccount(account) }
                )
            }
            if totalAccountCount == 1 {
                singleAccountHint
            }
            Button(action: onAddAnother) {
                Label("Add another \(providerDisplayName) account", systemImage: "plus")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.ember)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel("Add another \(providerDisplayName) account")
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if let provider {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.primary(for: provider).opacity(0.12))
                        .frame(width: 28, height: 28)
                    ProviderLogoView(provider: provider, size: 18, useFallbackColor: false)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(providerDisplayName)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("\(totalAccountCount) account\(totalAccountCount == 1 ? "" : "s") · \(rotationSummary)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer(minLength: 0)
        }
    }

    private var singleAccountHint: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.amber)
            Text("Add another account to enable automatic failover when this one runs out.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignSystem.Spacing.xs)
    }

    private func cooldownUntil(for accountID: String) -> Date? {
        if accountID == activeAccountID { return routingState?.activeAccount?.cooldownUntil }
        if accountID == nextFallbackAccountID { return routingState?.nextFallback?.cooldownUntil }
        return routingState?.exhaustedOrCoolingDownAccounts.first { $0.accountID == accountID }?.cooldownUntil
    }
}

// MARK: - Account Row

/// One account inside a provider group. Single status, single routing chip
/// (Active now / Next fallback / cooldown), tappable to edit. No chip stack.
private struct AccountRowView: View {
    let account: ProviderAccountDoc
    let isActive: Bool
    let isNextFallback: Bool
    let cooldownUntil: Date?
    let quotaWindows: [SwitcherQuotaWindowDisplay]
    let onTap: () -> Void

    private var statusTint: Color {
        ProviderAccountStatusVisual.tint(account.status)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.label)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        routingChip
                    }
                    if let detail = detailLine {
                        Text(detail)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !quotaWindows.isEmpty {
                        ConnectionQuotaWindowPills(windows: quotaWindows)
                    }
                }
                Spacer()
                Image(systemName: ProviderAccountStorage.iconName(account.storageScope))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ProviderAccountStorage.tint(account.storageScope))
                    .help(ProviderAccountStorage.description(account.storageScope))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(isActive
                        ? DesignSystem.Colors.success.opacity(0.06)
                        : DesignSystem.Colors.background.opacity(0.45)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .stroke(isActive
                        ? DesignSystem.Colors.success.opacity(0.4)
                        : DesignSystem.Colors.border.opacity(0.3),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var routingChip: some View {
        if isActive {
            chip(label: "Active now", systemImage: "checkmark.circle.fill", tint: DesignSystem.Colors.success)
        } else if isNextFallback {
            chip(label: "Next fallback", systemImage: "arrow.triangle.branch", tint: DesignSystem.Colors.amber)
        } else if let cooldown = cooldownUntil, cooldown > Date() {
            chip(label: "Cooling down", systemImage: "clock.fill", tint: DesignSystem.Colors.warning)
        } else if account.status == .error {
            chip(label: "Sign-in needed", systemImage: "exclamationmark.triangle.fill", tint: DesignSystem.Colors.error)
        } else if account.status == .stale {
            chip(label: "Stale", systemImage: "clock.badge.exclamationmark", tint: DesignSystem.Colors.warning)
        }
    }

    private func chip(label: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }

    private var detailLine: String? {
        if account.status == .deleted {
            return "Removed from this Mac"
        }
        if let cooldown = cooldownUntil, cooldown > Date() {
            return "Resumes \(cooldown.formatted(.relative(presentation: .named)))"
        }
        if account.status == .error, let code = account.lastErrorCode {
            return "Last error: \(code)"
        }
        if let identity = account.identityHint, !identity.isEmpty, identity != account.label {
            return identity
        }
        if let last = account.lastRefreshAt {
            return "Refreshed \(last.formatted(.relative(presentation: .named)))"
        }
        return nil
    }

    private var accessibilityLabel: String {
        var parts: [String] = [account.label]
        if isActive { parts.append("active now") }
        else if isNextFallback { parts.append("next fallback") }
        parts.append(ProviderAccountStatusVisual.label(account.status))
        parts.append("stored in \(ProviderAccountStorage.label(account.storageScope))")
        return parts.joined(separator: ", ")
    }
}

// MARK: - External OAuth Row

private struct ExternalOAuthAccountRowView: View {
    let account: ConnectionsSettingsView.ExternalOAuthAccount
    let quotaWindows: [SwitcherQuotaWindowDisplay]
    let onTap: () -> Void

    private var tint: Color {
        account.isDisabled ? DesignSystem.Colors.textMuted : DesignSystem.Colors.success
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.label)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        chip(
                            label: account.isCurrentLogin ? "Current login" : "OAuth profile",
                            systemImage: account.isCurrentLogin ? "checkmark.seal.fill" : "person.crop.circle.badge.checkmark",
                            tint: tint
                        )
                        if account.isDisabled {
                            chip(label: "Disabled", systemImage: "pause.circle.fill", tint: DesignSystem.Colors.textMuted)
                        }
                    }
                    Text(account.statusText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = account.detail {
                        Text(detail)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if !quotaWindows.isEmpty {
                        ConnectionQuotaWindowPills(windows: quotaWindows)
                    }
                }
                Spacer()
                Image(systemName: account.isCurrentLogin ? "terminal.fill" : "person.crop.circle.badge.checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .help(account.isCurrentLogin ? "Default local CLI login" : "Isolated OAuth profile")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.background.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .stroke(tint.opacity(account.isDisabled ? 0.18 : 0.34), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .opacity(account.isDisabled ? 0.66 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func chip(label: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }

    private var accessibilityLabel: String {
        var parts = [account.label, account.isCurrentLogin ? "current login" : "OAuth profile"]
        if account.isDisabled { parts.append("disabled") }
        if !quotaWindows.isEmpty {
            parts.append("quota \(quotaWindows.map(\.inlineText).joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
    }
}

private struct ConnectionQuotaWindowPills: View {
    let windows: [SwitcherQuotaWindowDisplay]

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(windows) { window in
                HStack(spacing: 4) {
                    Text(window.label)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(window.remaining)
                        .font(DesignSystem.Typography.monoTiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text(window.resetText)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(DesignSystem.Colors.surfaceElevated.opacity(0.72))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5))
            }
        }
    }
}

// MARK: - Proxy Model Catalog
//
// `ProxyModelCatalogPanel`, `ProxyModelProviderGroup`, `ProxyModelProviderSection`,
// and `ProxyModelCatalogRow` live in their own file so both the embedded catalog
// here and the dedicated Settings → Agents → Models page can share them.
// See `ProxyModelCatalogPanel.swift`.

// MARK: - App Connect Row

/// One row per CLI in the Apps section. The button is **smart** — it auto-
/// enables the gateway and runs wire + probe in one click.
private struct AppConnectRow: View {
    let target: RoutingClientWiringTarget
    let state: AppConnectState
    let isDisabled: Bool
    let onConnect: () -> Void
    let onTest: () -> Void
    let onSyncModels: () -> Void
    let onRepair: () -> Void
    let onDisconnect: () -> Void
    let onShowSnippet: () -> Void
    let onRevealFile: () -> Void
    let configPath: String

    private var provider: AgentProvider? {
        switch target {
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        case .opencode: return .openCode
        case .forge: return .forgeDev
        case .droid: return .factory
        }
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if let provider {
                        ProviderLogoView(provider: provider, size: 18, useFallbackColor: true)
                    }
                    Text(target.displayName)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
                if let statusText {
                    Text(statusText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(statusTint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            primaryAction
            if isConnected {
                Menu {
                    Button("Test connection", action: onTest)
                    Button("Show shell snippet", action: onShowSnippet)
                    Button("Reveal config file", action: onRevealFile)
                    Divider()
                    Button("Disconnect", role: .destructive, action: onDisconnect)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
        .opacity(isDisabled ? 0.6 : 1)
    }

    // MARK: - State machine surface

    private var isConnected: Bool {
        if case .connected = state { return true }
        if case .degraded = state { return true }
        return false
    }

    private var statusTint: Color {
        if isDisabled {
            return DesignSystem.Colors.warning
        }
        switch state {
        case .connected: return DesignSystem.Colors.success
        case .connecting, .syncingModels, .probing: return DesignSystem.Colors.textSecondary
        case .degraded: return DesignSystem.Colors.warning
        case .error: return DesignSystem.Colors.error
        case .notConnected, .unknown: return DesignSystem.Colors.textMuted
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusTint)
            .frame(width: 8, height: 8)
    }

    private var statusText: String? {
        switch state {
        case .connected:
            if target == .droid {
                return isDisabled ? missingRouteText : "Droid models synced from BurnBar's live catalog"
            }
            return isDisabled ? missingRouteText : "Connected via local gateway"
        case .syncingModels: return "Syncing models…"
        case .connecting: return "Connecting…"
        case .probing: return "Testing…"
        case .degraded(let message):
            if isDisabled {
                return "\(missingRouteText) \(message)"
            }
            return "Configured via local gateway, but the route test needs attention. \(message)"
        case .error(let message): return message
        case .notConnected: return isDisabled
            ? missingRouteText
            : nil
        case .unknown: return nil
        }
    }

    private var missingRouteText: String {
        switch target {
        case .claudeCode:
            return "No route-ready Anthropic account is enabled. Add an Anthropic Console API key or Claude OAuth credential before using Claude Code."
        case .codex, .opencode, .forge, .droid:
            return "No route-ready OpenAI-compatible account is enabled. Add or enable a provider account before using \(target.displayName)."
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch state {
        case .notConnected, .unknown:
            Button(action: onConnect) {
                Text(target == .droid ? "Connect + Sync" : "Connect")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isDisabled)
        case .connecting, .syncingModels:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state == .syncingModels ? "Syncing…" : "Connecting…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        case .probing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        case .connected:
            Button(action: target == .droid ? onSyncModels : onTest) {
                Text(target == .droid ? "Sync models" : "Test")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(isDisabled)
        case .degraded:
            Button(action: onRepair) {
                Text("Repair")
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignSystem.Colors.warning)
            .controlSize(.regular)
        case .error:
            Button(action: onConnect) {
                Text("Try again")
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignSystem.Colors.error)
            .controlSize(.regular)
        }
    }
}

private struct ConnectionsAddAccountButtonStyle: ButtonStyle {
    enum Size {
        case compact
        case regular

        var height: CGFloat {
            switch self {
            case .compact: return 30
            case .regular: return 36
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .compact: return 12
            case .regular: return 14
            }
        }

        var font: Font {
            switch self {
            case .compact: return DesignSystem.Typography.caption
            case .regular: return DesignSystem.Typography.body
            }
        }
    }

    let size: Size

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.blaze,
                        DesignSystem.Colors.amber
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.16 : 0.28), lineWidth: 0.6)
            )
            .shadow(
                color: DesignSystem.Colors.blaze.opacity(configuration.isPressed ? 0.12 : 0.22),
                radius: configuration.isPressed ? 3 : 7,
                x: 0,
                y: configuration.isPressed ? 1 : 3
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Capsule(style: .continuous))
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

// MARK: - Snippet Sheet

private struct SnippetSheet: View {
    let target: RoutingClientWiringTarget
    let snippet: String
    let isCopied: Bool
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("\(target.displayName) — shell snippet")
                    .font(DesignSystem.Typography.headline)
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            Text("Paste these into `~/.zshrc`, `~/.bashrc`, or your shell of choice. Restart \(target.displayName) so it picks up the env vars.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            ScrollView {
                Text(snippet)
                    .font(DesignSystem.Typography.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.surfaceElevated)
                    )
            }
            HStack {
                Button(action: onCopy) {
                    if isCopied {
                        Label("Copied!", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("Copy to clipboard", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.borderedProminent)
                .animation(.easeInOut(duration: 0.2), value: isCopied)
                Spacer()
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 540, minHeight: 380)
    }
}

// MARK: - Sheet target wrapper

/// Identifiable wrapper so the wizard sheet can present-by-item without
/// dropping the provider ID across navigation churn.
struct ProviderWizardTarget: Equatable, Identifiable {
    let providerID: String?
    let startsAtProviderSelection: Bool

    var id: String {
        startsAtProviderSelection ? "add-account" : providerID ?? "provider-dashboard"
    }

    static let addAccount = ProviderWizardTarget(
        providerID: nil,
        startsAtProviderSelection: true
    )

    init(providerID: String) {
        self.providerID = providerID
        self.startsAtProviderSelection = false
    }

    private init(providerID: String?, startsAtProviderSelection: Bool) {
        self.providerID = providerID
        self.startsAtProviderSelection = startsAtProviderSelection
    }
}
