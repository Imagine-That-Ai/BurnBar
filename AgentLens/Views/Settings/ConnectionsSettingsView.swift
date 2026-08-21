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
    @State private var refreshingExternalCredentialIDs: Set<String> = []
    @State private var externalCredentialMessages: [String: String] = [:]
    @State private var isAdvancedExpanded = false
    /// Set when an experimental routing toggle changes so the card can highlight
    /// the "Restart daemon to apply" action (the env-based opt-ins only take
    /// effect on the next daemon launch).
    @State private var experimentalRoutingDirty = false

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
            await loadAccountDataAsync()
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
                                settingsManager: settingsManager,
                                quotaWindowsForAccount: quotaWindows(for:),
                                quotaWindowsForExternalAccount: quotaWindows(for:),
                                credentialNoticeForExternalAccount: credentialNotice(for:),
                                credentialMessageForExternalAccount: { externalCredentialMessages[$0.id] },
                                isRefreshingExternalCredential: { refreshingExternalCredentialIDs.contains($0.id) },
                                onTapAccount: { account in
                                    wizardProviderID = ProviderWizardTarget(providerID: account.providerID.rawValue)
                                },
                                onTapExternalAccount: { account in
                                    wizardProviderID = ProviderWizardTarget(providerID: account.providerID.rawValue)
                                },
                                onRefreshExternalCredential: refreshExternalCredential,
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

            MCPInstallCard()

            VibeProxyMigrationCard(
                snapshot: viewModel.vibeProxyMigrationSnapshot,
                state: viewModel.vibeProxyMigrationState,
                onScan: {
                    viewModel.scanVibeProxyMigration()
                },
                onMigrate: {
                    Task {
                        await viewModel.migrateFromVibeProxy(
                            settings: settingsManager,
                            daemonManager: daemonManager,
                            restartGateway: restartLocalGateway
                        )
                    }
                }
            )

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
                        await viewModel.startProxyGateway(settings: settingsManager) {
                            await restartLocalGateway()
                            return localGatewayStartError()
                        }
                        await viewModel.refreshWiringState(settings: settingsManager)
                    }
                },
                routeLogEntries: viewModel.proxyRouteLogEntries,
                routeLogState: viewModel.proxyRouteLogState,
                onRefreshRouteLog: {
                    Task {
                        await viewModel.refreshProxyRouteLog(socketURL: daemonManager.paths.socketURL)
                    }
                },
                onClearRouteLog: {
                    Task {
                        await viewModel.clearProxyRouteLog(socketURL: daemonManager.paths.socketURL)
                    }
                },
                droidSyncState: viewModel.state(for: .droid),
                onSyncDroid: { syncDroidProxyModels() },
                onToggleModelAdvertisement: { model, isEnabled in
                    setModelAdvertisement(model, isEnabled: isEnabled)
                },
                onUpsertModelAlias: { model, alias in
                    await upsertModelAlias(model, alias: alias)
                },
                onRemoveModelAlias: { aliasModel in
                    removeModelAlias(aliasModel)
                },
                onSetDisplayName: { model, name in
                    await setModelDisplayName(model, name: name)
                },
                onClearDisplayName: { model in
                    removeModelDisplayName(model)
                },
                onSetProviderAdvertisement: { providerID, modelIDs, isEnabled in
                    setProviderAdvertisement(providerID, modelIDs: modelIDs, isEnabled: isEnabled)
                },
                customModelsByProvider: customModelsByProvider,
                onAddCustomModel: { providerID, modelID, displayName in
                    addCustomModel(providerID: providerID, modelID: modelID, displayName: displayName)
                },
                onRemoveCustomModel: { providerID, modelID in
                    removeCustomModel(providerID: providerID, modelID: modelID)
                }
            )

            if !hasAnyAccount {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(LinearGradient(
                                colors: [DesignSystem.Colors.blaze.opacity(0.12), DesignSystem.Colors.amber.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 32, height: 32)
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.blaze)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connect your CLIs")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Add a provider account first, then connect Claude Code, Codex CLI, Droid CLI, and other agents to route through BurnBar's local gateway with automatic failover.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(DesignSystem.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.3))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.35), lineWidth: 0.5)
                )
            } else {
                VStack(spacing: DesignSystem.Spacing.xs) {
                    ForEach(RoutingClientWiringTarget.allCases) { target in
                        AppConnectRow(
                            target: target,
                            state: viewModel.state(for: target),
                            isDisabled: !hasAccountFor(target: target),
                            modelSummary: viewModel.modelSummary(for: target),
                            onConnect: {
                                Task {
                                    await viewModel.connect(
                                        target: target,
                                        settings: settingsManager,
                                        daemonManager: daemonManager,
                                        restartGateway: restartLocalGateway
                                    )
                                }
                            },
                            onTest: { Task { await viewModel.test(target: target, settings: settingsManager) } },
                            onSyncModels: {
                                syncRoutedProxyModels(target)
                            },
                            onRepair: {
                                Task {
                                    await viewModel.connect(
                                        target: target,
                                        settings: settingsManager,
                                        daemonManager: daemonManager,
                                        restartGateway: restartLocalGateway
                                    )
                                }
                            },
                            onDisconnect: { Task { await viewModel.disconnect(target: target, settings: settingsManager) } },
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
                experimentalRoutingCard
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
                Text("Routing strategy, local gateway, experimental routing, daemon settings")
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

    private var routingStrategyHeading: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: daemonManager.routerMode.usesExactSameModelInvariant ? "equal.circle" : "rectangle.2.swap")
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var routingStrategyPicker: some View {
        Picker("Routing strategy", selection: Binding(
            get: { daemonManager.routerMode },
            set: { mode in
                Task { @MainActor in
                    await daemonManager.setRouterMode(mode)
                    await daemonManager.refreshHealth()
                }
            }
        )) {
            Text("Exact model failover").tag(ProviderRouterMode.sameModelFailover)
            Text("Stay inside one provider").tag(ProviderRouterMode.providerFamilyFailover)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(daemonManager.isBusy)
    }

    private var routingStrategyCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    routingStrategyHeading
                    Spacer(minLength: DesignSystem.Spacing.md)
                    routingStrategyPicker
                        .frame(maxWidth: 320)
                }
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    routingStrategyHeading
                    routingStrategyPicker
                        .frame(maxWidth: .infinity)
                }
            }
            Text(daemonManager.routerMode.usesExactSameModelInvariant
                ? "BurnBar may switch provider or account after exhaustion, but only when the next route proves it serves the exact same model."
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DesignSystem.Spacing.md) {
                        gatewayEndpointFields
                        Spacer()
                        gatewayResetButton
                    }
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        HStack(spacing: DesignSystem.Spacing.md) {
                            gatewayEndpointFields
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Spacer()
                            gatewayResetButton
                        }
                    }
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

    @ViewBuilder
    private var gatewayEndpointFields: some View {
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
        if !isGatewayLoopback(settingsManager.gatewayHost) {
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
    }

    private var gatewayResetButton: some View {
        Button {
            resetLocalDefaults()
        } label: {
            Label("Reset to local defaults", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Off-by-default, gray-area routing opt-ins for Anthropic's post-June-15
    /// metering split. Each toggle maps to a daemon launch env var (see
    /// `writeLaunchAgentPlist()`), so changes take effect on the next daemon
    /// restart — hence the explicit apply action.
    private var experimentalRoutingCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "testtube.2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text("Experimental routing")
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("EXPERIMENTAL")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DesignSystem.Colors.amber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DesignSystem.Colors.amber.opacity(0.15)))
                    }
                    Text("Off by default. Ways to keep Claude usable after Anthropic's June 15 metering split.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer()
            }

            SettingsToggle(
                title: "Cross-vendor degrade",
                subtitle: "When the requested model can't be served, fall back to an allow-listed OpenAI-compatible vendor (DeepSeek, Z.ai, Moonshot) on your own key. Legitimate — but the reply won't be from the model you asked for.",
                icon: "arrow.triangle.branch",
                isOn: experimentalRoutingBinding(\.crossVendorDegradeEnabled)
            )

            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: experimentalRoutingDirty ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.amber)
                Text(experimentalRoutingDirty
                    ? "Restart the daemon to apply your changes."
                    : "Changes apply after the daemon restarts.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Button {
                    Task { @MainActor in
                        await restartLocalGateway()
                        experimentalRoutingDirty = false
                    }
                } label: {
                    Label("Restart daemon to apply", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(daemonManager.isBusy)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(DesignSystem.Colors.amber.opacity(experimentalRoutingDirty ? 0.5 : 0.18), lineWidth: 0.75)
        )
    }

    /// Wraps an experimental routing toggle so flipping it both persists the
    /// setting and marks the card dirty (the env-based opt-ins only apply on the
    /// next daemon launch).
    private func experimentalRoutingBinding(
        _ keyPath: ReferenceWritableKeyPath<SettingsManager, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { settingsManager[keyPath: keyPath] },
            set: { newValue in
                settingsManager[keyPath: keyPath] = newValue
                experimentalRoutingDirty = true
            }
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

    struct ExternalOAuthCredentialNotice: Hashable {
        enum Kind: Hashable {
            case credentialMissing
            case quotaUnavailable
        }

        let kind: Kind
        let title: String
        let message: String

        static func credentialMissing(cliType: SwitcherCLIProfileType, message: String? = nil) -> Self {
            Self(
                kind: .credentialMissing,
                title: "Credential not found",
                message: message ?? "No \(cliType.displayName) OAuth credential was found for this profile. Refresh the credential to capture current quota."
            )
        }

        static func quotaUnavailable(message: String) -> Self {
            Self(kind: .quotaUnavailable, title: "Quota unavailable", message: message)
        }

        var systemImage: String {
            switch kind {
            case .credentialMissing:
                return "exclamationmark.triangle.fill"
            case .quotaUnavailable:
                return "clock.badge.exclamationmark"
            }
        }

        var tint: Color {
            switch kind {
            case .credentialMissing:
                return DesignSystem.Colors.error
            case .quotaUnavailable:
                return DesignSystem.Colors.warning
            }
        }
    }

    /// Pure classification for an external OAuth account row's credential
    /// notice. Returns the *kind* of warning (or `nil` for "all good") given
    /// the few facts the row actually knows about a credential.
    ///
    /// The cardinal rule: a credential that is genuinely present is **never**
    /// reported as "Credential not found", even when the provider withholds
    /// quota buckets. Isolated Claude OAuth (Max/Pro) profiles routinely sign
    /// in successfully while Anthropic returns no quota windows — that is a
    /// `.quotaUnavailable` state, not a missing credential. Treating it as
    /// missing produced a self-contradictory row (a red "Credential not found"
    /// badge above a message that says the credential *is* signed in) and an
    /// endless refresh-nag loop where refreshing never cleared the warning.
    ///
    /// Presence is proven two independent ways, either of which suffices:
    ///  - `authConnected == true`: local auth discovery found a usable
    ///    credential in the profile's config directory.
    ///  - `snapshotSource == .officialAPI`: the Claude quota adapter only
    ///    stamps an unavailable snapshot with `.officialAPI` *after* it loaded
    ///    this account's stored credential, so that source proves the
    ///    credential exists even with empty buckets.
    ///
    /// - Parameter authConnected: `true`/`false` from auth discovery, or `nil`
    ///   when no auth state was discovered for the account at all.
    static func classifyExternalCredentialNotice(
        isDisabled: Bool,
        isCurrentLogin: Bool,
        hasQuotaWindows: Bool,
        authConnected: Bool?,
        snapshotSource: ProviderQuotaSourceKind?,
        snapshotConfidence: ProviderQuotaConfidence?
    ) -> ExternalOAuthCredentialNotice.Kind? {
        // Disabled rows and rows already showing real quota windows need no
        // warning at all.
        guard !isDisabled, !hasQuotaWindows else { return nil }

        // Auth discovery explicitly reports the saved credential is gone.
        if authConnected == false { return .credentialMissing }

        let credentialPresent = (authConnected == true) || snapshotSource == .officialAPI

        if let snapshotSource, let snapshotConfidence {
            let quotaIsUnavailable = snapshotConfidence == .unavailable
                || snapshotSource == .unavailable
            if quotaIsUnavailable {
                // A present credential with withheld quota reads as a quota
                // gap; only a genuinely-absent credential is "not found".
                return credentialPresent ? .quotaUnavailable : .credentialMissing
            }
            // A usable snapshot proves the credential and simply lacks windows.
            return .quotaUnavailable
        }

        // No snapshot captured yet for this account.
        if credentialPresent, !isCurrentLogin { return .quotaUnavailable }
        if isCurrentLogin { return nil }
        return .credentialMissing
    }

    private struct AccountGroup {
        let providerID: ProviderID
        let accounts: [ProviderAccountDoc]
        let externalAccounts: [ExternalOAuthAccount]
    }

    private var activeAccounts: [ProviderAccountDoc] {
        let storedAccounts = providerAccounts.filter { $0.status != .deleted }
        let storedAccountIDs = Set(storedAccounts.map(\.id))
        let projectedDaemonAccounts = DaemonCredentialSlotAccountProjection
            .accounts(from: daemonManager.providerConfigurations)
            .filter { account in
                account.status != .deleted && !storedAccountIDs.contains(account.id)
            }

        return storedAccounts + projectedDaemonAccounts
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
        Task { @MainActor in
            await loadAccountDataAsync()
        }
    }

    private func loadAccountDataAsync() async {
        await loadAccounts()
        loadSwitcherProfiles()
        refreshExternalAuthStates()
        viewModel.refreshWiringState()
    }

    private func restartLocalGateway() async {
        await daemonManager.installAndStart()
        await daemonManager.refreshHealth()
    }

    private func localGatewayStartError() -> String? {
        daemonManager.localGatewayStartErrorMessage
    }

    private func syncRoutedProxyModels(_ target: RoutingClientWiringTarget = .droid) {
        Task {
            await viewModel.syncModels(
                target: target,
                settings: settingsManager,
                daemonManager: daemonManager,
                restartGateway: restartLocalGateway
            )
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
        }
    }

    private func syncDroidProxyModels() {
        syncRoutedProxyModels(.droid)
    }

    private func setModelAdvertisement(_ model: ProxyAdvertisedModel, isEnabled: Bool) {
        Task {
            await daemonManager.setProviderModelAdvertisement(
                providerID: model.providerID,
                modelID: model.modelID,
                isEnabled: isEnabled
            )
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
        }
    }

    private func setProviderAdvertisement(_ providerID: String, modelIDs: [String], isEnabled: Bool) {
        Task {
            await daemonManager.setProviderModelsAdvertisement(
                providerID: providerID,
                modelIDs: modelIDs,
                isEnabled: isEnabled
            )
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
        }
    }

    private func upsertModelAlias(_ model: ProxyAdvertisedModel, alias: BurnBarModelAlias) async -> String? {
        let saved = await daemonManager.setProviderModelAlias(
            providerID: model.providerID,
            alias: alias
        )
        guard saved else {
            return daemonManager.lastError ?? "Could not save the custom model alias."
        }
        await viewModel.refreshProxyModelCatalog(settings: settingsManager)
        await viewModel.refreshWiringState(settings: settingsManager)
        return nil
    }

    private func removeModelAlias(_ aliasModel: ProxyAdvertisedModel) {
        Task {
            await daemonManager.removeProviderModelAlias(
                providerID: aliasModel.providerID,
                aliasID: aliasModel.modelID
            )
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
        }
    }

    private var customModelsByProvider: [String: [BurnBarCustomModel]] {
        var result: [String: [BurnBarCustomModel]] = [:]
        for config in daemonManager.providerConfigurations where !config.customModels.isEmpty {
            result[config.providerID] = config.customModels
        }
        return result
    }

    private func addCustomModel(providerID: String, modelID: String, displayName: String) {
        Task {
            _ = await daemonManager.setProviderCustomModel(
                providerID: providerID,
                customModel: BurnBarCustomModel(modelID: modelID, displayName: displayName)
            )
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
        }
    }

    private func removeCustomModel(providerID: String, modelID: String) {
        Task {
            await daemonManager.removeProviderCustomModel(
                providerID: providerID,
                modelID: modelID
            )
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
        }
    }

    private func setModelDisplayName(_ model: ProxyAdvertisedModel, name: String) async -> String? {
        let saved = await daemonManager.setProviderModelDisplayName(
            providerID: model.providerID,
            modelID: model.modelID,
            displayName: name
        )
        guard saved else {
            return daemonManager.lastError ?? "Could not save the display name override."
        }
        await viewModel.refreshProxyModelCatalog(settings: settingsManager)
        await viewModel.refreshWiringState(settings: settingsManager)
        return nil
    }

    private func removeModelDisplayName(_ model: ProxyAdvertisedModel) {
        Task {
            await daemonManager.removeProviderModelDisplayName(
                providerID: model.providerID,
                modelID: model.modelID
            )
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
        }
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

    private func loadAccounts() async {
        do {
            providerAccounts = try await dataStore.fetchProviderAccounts()
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
        for profile in switcherProfiles {
            guard profile.targetKind == .cli,
                  let cliType = profile.cliType,
                  cliType == .codex || cliType == .claude,
                  let configDirectory = normalizedString(profile.cliMetadata?.configDirectory) else {
                continue
            }
            next[profile.id] = CLIAuthDiscovery.discoverAuthState(
                for: cliType,
                configDirectoryOverride: configDirectory
            )
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
        case .droid:
            return .factory
        case .forge:
            return ProviderID(rawValue: "forge")
        case .antigravity:
            return .antigravity
        case .grok:
            return .xAI
        case .cursorAgent:
            return ProviderID(rawValue: "cursor-agent")
        case .gemini:
            return AgentProvider.geminiCLI.providerID
        case .kimi:
            return .kimi
        case .pi:
            return AgentProvider.piAgent.providerID
        case .junie:
            return AgentProvider.junie.providerID
        case .fx:
            return AgentProvider.fx.providerID
        case .omp:
            return AgentProvider.omp.providerID
        case .primeAgent:
            return AgentProvider.primeAgent.providerID
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
        let accountWindows = switcherQuotaWindowDisplays(snapshot: accountSnapshot)
        if !accountWindows.isEmpty {
            return accountWindows
        }

        guard let provider = AgentProvider.fromProviderID(account.providerID) else {
            return []
        }
        return switcherQuotaWindowDisplays(snapshot: quotaService.snapshot(for: provider))
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

    private func credentialNotice(for account: ExternalOAuthAccount) -> ExternalOAuthCredentialNotice? {
        guard let provider = account.cliType.agentProvider else { return nil }

        let authInfo = externalAuthInfo(for: account)
        let snapshot = exactExternalQuotaSnapshot(for: account, provider: provider)
        let kind = Self.classifyExternalCredentialNotice(
            isDisabled: account.isDisabled,
            isCurrentLogin: account.isCurrentLogin,
            hasQuotaWindows: !quotaWindows(for: account).isEmpty,
            authConnected: authInfo.map(isExternalAuthConnected),
            snapshotSource: snapshot?.sourceKind,
            snapshotConfidence: snapshot?.confidence
        )

        guard let kind else { return nil }
        switch kind {
        case .credentialMissing:
            // Prefer the most specific explanation available, mirroring the
            // previous message precedence (auth state → snapshot → default).
            if let authInfo, !isExternalAuthConnected(authInfo) {
                return .credentialMissing(
                    cliType: account.cliType,
                    message: credentialMissingMessage(for: account, authInfo: authInfo)
                )
            }
            if let snapshot {
                return .credentialMissing(
                    cliType: account.cliType,
                    message: credentialMissingMessage(
                        for: account,
                        snapshotMessage: normalizedString(snapshot.statusMessage)
                    )
                )
            }
            return .credentialMissing(cliType: account.cliType)
        case .quotaUnavailable:
            if let statusMessage = normalizedString(snapshot?.statusMessage) {
                return .quotaUnavailable(message: statusMessage)
            }
            return .quotaUnavailable(
                message: "\(account.cliType.displayName) credential is present, but no quota snapshot has been captured for this profile yet. Refresh to capture current quota."
            )
        }
    }

    /// Confirmation line shown after a manual credential refresh. Mirrors the
    /// row's own notice so the acknowledgement is truthful: a refreshed,
    /// connected credential reads as success even when the provider returns no
    /// quota — rather than promising a quota meter that will never appear.
    private func refreshConfirmationMessage(for account: ExternalOAuthAccount) -> String {
        let name = account.cliType.displayName
        guard let kind = credentialNotice(for: account)?.kind else {
            return "Credential refreshed. Quota captured for this profile."
        }
        switch kind {
        case .quotaUnavailable:
            return "Credential refreshed and connected. \(name) returned no current quota, so this profile won't show a quota meter yet."
        case .credentialMissing:
            return "Refresh finished, but no usable \(name) credential was captured for this profile. Open the \(name) login again to finish signing in."
        }
    }

    private func externalAuthInfo(for account: ExternalOAuthAccount) -> CLIAuthInfo? {
        if let profileID = account.profileID {
            return externalAuthStates[profileID]
        }
        return externalAuthStates[account.cliType.rawValue]
    }

    private func credentialMissingMessage(
        for account: ExternalOAuthAccount,
        snapshotMessage: String?
    ) -> String {
        if let snapshotMessage,
           !snapshotMessage.localizedCaseInsensitiveContains("stale") {
            return snapshotMessage
        }

        return "No \(account.cliType.displayName) OAuth credential was found for this profile. Refresh the credential to capture current quota."
    }

    private func credentialMissingMessage(
        for account: ExternalOAuthAccount,
        authInfo: CLIAuthInfo
    ) -> String {
        switch authInfo.authState {
        case .notInstalled:
            return "\(account.cliType.displayName) is not installed or not reachable from BurnBar, so this profile's credential cannot be verified."
        case .notAuthenticated:
            return "No \(account.cliType.displayName) OAuth credential was found in this saved profile. Refresh the credential to sign in again and capture current quota."
        case .authenticated, .apiKeyPresent:
            return "No \(account.cliType.displayName) OAuth credential was found for this profile. Refresh the credential to capture current quota."
        }
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
                "switcher:\(profileID)"
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

    private func refreshExternalCredential(for account: ExternalOAuthAccount) {
        Task { @MainActor in
            await refreshExternalCredentialNow(for: account)
        }
    }

    @MainActor
    private func refreshExternalCredentialNow(for account: ExternalOAuthAccount) async {
        refreshingExternalCredentialIDs.insert(account.id)
        externalCredentialMessages[account.id] = account.isCurrentLogin
            ? "Refreshing \(account.cliType.displayName) status..."
            : "Opening \(account.cliType.displayName) login for \(account.label)..."
        defer {
            refreshingExternalCredentialIDs.remove(account.id)
        }

        if account.isCurrentLogin {
            refreshExternalAuthStates()
            // The default local Claude login lives in the ACL-locked global
            // Keychain item, which background quota refresh cannot read. Capture
            // it into the per-profile item the quota reader resolves, while this
            // user action lets macOS show the "Always Allow" prompt. Capture
            // BEFORE the quota refresh below so the same refresh reads the
            // freshly populated item. Non-fatal: a denial only defers quota, so
            // we surface the actionable ACL guidance and still refresh.
            var captureMessage: String?
            if account.cliType == .claude {
                do {
                    try SwitcherCLIAuthCoordinator.captureDefaultLoginProfileCredential(
                        configDirectory: defaultClaudeLoginConfigDirectory(for: account)
                    )
                } catch let captureError as ClaudeCodeOAuthCredentialImportError {
                    if case .accessDenied = captureError {
                        captureMessage = captureError.localizedDescription
                    }
                } catch {
                    AppLogger.shared.error(
                        "claude_default_login_credential_capture_failed",
                        metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                    )
                }
            }
            if let provider = account.cliType.agentProvider {
                await quotaService.refresh(provider: provider, dataStore: dataStore)
            }
            // Prefer the actionable ACL message (so the user knows to grant
            // access); otherwise report the routine status.
            externalCredentialMessages[account.id] = captureMessage
                ?? "Refreshed \(account.cliType.displayName) status."
            return
        }

        guard let profileID = account.profileID,
              let profile = switcherProfiles.first(where: { $0.id == profileID }) else {
            externalCredentialMessages[account.id] = "Could not find the saved \(account.cliType.displayName) profile. Reload Accounts and try again."
            loadSwitcherProfiles()
            return
        }

        let coordinator = SwitcherCLIAuthCoordinator()
        let result = await coordinator.reconnect(
            profile: profile,
            context: SwitcherCLIAuthCoordinator.ReconnectContext(
                providerSlotLabel: account.label,
                existingAccountLabels: switcherProfiles
                    .filter { $0.id != profile.id && $0.targetKind == .cli && $0.cliType == account.cliType }
                    .map { externalAccountLabel(for: $0, cliType: account.cliType) }
            )
        )

        switch result {
        case .readyToPersist(let updatedProfile), .requiresConfirmation(let updatedProfile, _, _):
            do {
                let refreshed = normalizedExternalOAuthProfile(
                    updatedProfile,
                    providerID: account.providerID.rawValue,
                    cliType: account.cliType
                )
                _ = try dataStore.switcherStore.update(refreshed)
                var captureMessage: String?
                // Reconnect no longer snapshots the route token itself (a flaky
                // Keychain must never discard a confirmed re-auth). Snapshot it
                // here, non-fatally: the profile is already saved, so a denial
                // only defers quota tracking. Surfaces the actionable ACL message
                // when macOS blocks the read.
                if account.cliType == .claude {
                    do {
                        try SwitcherCLIAuthCoordinator.persistProfileCredentialAfterConfirmedLogin(for: refreshed)
                    } catch let snapshotError as ClaudeCodeOAuthCredentialImportError {
                        if case .accessDenied = snapshotError {
                            captureMessage = snapshotError.localizedDescription
                        }
                    } catch {
                        AppLogger.shared.error(
                            "claude_route_credential_snapshot_failed",
                            metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                        )
                    }
                }
                loadSwitcherProfiles()
                refreshExternalAuthStates()
                externalCredentialMessages[account.id] = "Credential refreshed. Updating quota..."
                if let provider = account.cliType.agentProvider {
                    await quotaService.refresh(provider: provider, dataStore: dataStore)
                }
                // Re-read state after the quota refresh so the confirmation
                // reflects what actually happened — connected with quota,
                // connected without quota, or still missing — instead of
                // unconditionally promising quota that some accounts never
                // expose.
                refreshExternalAuthStates()
                externalCredentialMessages[account.id] = captureMessage ?? refreshConfirmationMessage(for: account)
            } catch {
                externalCredentialMessages[account.id] = "Failed to save refreshed credential: \(error.localizedDescription)"
            }
        case .cancelled:
            externalCredentialMessages[account.id] = "\(account.cliType.displayName) credential refresh was cancelled."
        case .failed(let message):
            externalCredentialMessages[account.id] = message
        }
    }

    private func normalizedExternalOAuthProfile(
        _ profile: SwitcherProfileRecord,
        providerID: String,
        cliType: SwitcherCLIProfileType
    ) -> SwitcherProfileRecord {
        let metadata = profile.cliMetadata ?? SwitcherCLIProfileMetadata()
        let accountDescription = normalizedString(metadata.accountDescription)
        let displayLabel = accountDescription
            ?? normalizedString(metadata.displayLabel)
            ?? externalAccountLabel(for: profile, cliType: cliType)

        return SwitcherProfileRecord(
            id: profile.id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: metadata.workingDirectory,
                additionalArgs: metadata.additionalArgs,
                envKeysToPass: metadata.envKeysToPass,
                displayLabel: displayLabel,
                configDirectory: metadata.configDirectory,
                accountDescription: metadata.accountDescription,
                providerID: canonicalOAuthProviderID(for: providerID, cliType: cliType),
                runtimeAccountID: metadata.runtimeAccountID,
                subscriptionTierID: metadata.subscriptionTierID,
                modelCapabilityClassID: metadata.modelCapabilityClassID,
                linkedHarnessIDs: metadata.linkedHarnessIDs.isEmpty ? [cliType.rawValue] : metadata.linkedHarnessIDs,
                neverAutoSwitch: metadata.neverAutoSwitch,
                lastQuotaExhaustedAt: metadata.lastQuotaExhaustedAt,
                exhaustedUntil: metadata.exhaustedUntil,
                lastQuotaExhaustionDetail: metadata.lastQuotaExhaustionDetail,
                isDisabled: metadata.isDisabled
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt,
            updatedAt: Date()
        )
    }

    private func canonicalOAuthProviderID(for providerID: String, cliType: SwitcherCLIProfileType) -> ProviderID {
        switch cliType {
        case .codex:
            return .openAI
        case .claude:
            return .anthropic
        case .opencode:
            return .openCode
        case .droid:
            return .factory
        case .forge:
            return ProviderID(rawValue: "forge")
        case .antigravity:
            return .antigravity
        case .grok:
            return .xAI
        case .cursorAgent:
            return ProviderID(rawValue: "cursor-agent")
        case .gemini:
            return AgentProvider.geminiCLI.providerID
        case .kimi:
            return .kimi
        case .pi:
            return AgentProvider.piAgent.providerID
        case .junie:
            return AgentProvider.junie.providerID
        case .fx:
            return AgentProvider.fx.providerID
        case .omp:
            return AgentProvider.omp.providerID
        case .primeAgent:
            return AgentProvider.primeAgent.providerID
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

    /// The config directory whose per-profile Keychain item should hold the
    /// default Claude login's captured token. The account row carries the
    /// discovered config directory in `detail`; fall back to `~/.claude` (the
    /// canonical default) when discovery did not surface a path, so the captured
    /// item hashes to the same service the quota reader resolves for the default
    /// login.
    private func defaultClaudeLoginConfigDirectory(for account: ExternalOAuthAccount) -> String {
        normalizedString(account.detail)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
                .path
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
