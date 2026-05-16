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
    @Bindable var settingsManager: SettingsManager
    @Bindable var daemonManager: OpenBurnBarDaemonManager
    let dataStore: DataStore
    let accountManager: AccountManager

    @State private var viewModel = ConnectionsViewModel()
    @State private var quotaService = ProviderQuotaService.shared
    @State private var wizardProviderID: ProviderWizardTarget?
    @State private var providerAccounts: [ProviderAccountDoc] = []
    @State private var providerAccountLoadError: String?
    @State private var isShowingAddPicker = false
    @State private var isAdvancedExpanded = false

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
        SettingsDeepLinkScrollContainer(route: .connectionsRoot) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    header
                    accountsSection
                        .settingsAnchor(SettingsAnchor.connectionsAccounts)
                    appsSection
                        .settingsAnchor(SettingsAnchor.connectionsApps)
                    advancedDisclosure
                        .settingsAnchor(SettingsAnchor.connectionsAdvanced)
                }
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .navigationTitle("Connections")
        .sheet(item: $wizardProviderID) { target in
            ProviderPlanWizardView(
                daemonManager: daemonManager,
                dataStore: dataStore,
                initialProviderID: target.providerID
            ) {
                wizardProviderID = nil
                loadAccounts()
            }
        }
        .sheet(isPresented: $isShowingAddPicker) {
            AddAccountProviderPicker(
                daemonManager: daemonManager,
                onSelectProvider: { providerID in
                    isShowingAddPicker = false
                    wizardProviderID = ProviderWizardTarget(providerID: providerID)
                },
                onCancel: { isShowingAddPicker = false }
            )
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
            loadAccounts()
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

    // MARK: - Accounts

    @ViewBuilder
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Accounts")
                    .font(DesignSystem.Typography.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Button {
                    isShowingAddPicker = true
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Add account")
            }

            if let providerAccountLoadError {
                inlineErrorCallout(providerAccountLoadError)
            } else if activeAccounts.isEmpty {
                emptyAccountsCard
            } else {
                VStack(spacing: DesignSystem.Spacing.md) {
                    ForEach(accountGroups, id: \.providerID) { group in
                        ProviderAccountGroup(
                            providerID: group.providerID,
                            accounts: group.accounts,
                            routingState: quotaService.routingStatesByProviderID[group.providerID],
                            onTapAccount: { account in
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
                    isShowingAddPicker = true
                } label: {
                    Label("Add your first account", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
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
                    .font(DesignSystem.Typography.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
            }

            if activeAccounts.isEmpty {
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
                            onConnect: { Task { await viewModel.connect(target: target, settings: settingsManager) } },
                            onTest: { Task { await viewModel.test(target: target, settings: settingsManager) } },
                            onRepair: { Task { await viewModel.connect(target: target, settings: settingsManager) } },
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

    /// True when the user has at least one account for the provider family
    /// this CLI sends traffic to. We don't gate connecting on this — but we
    /// surface a softer "Add an account first" state when there's nothing to
    /// route to.
    private func hasAccountFor(target: RoutingClientWiringTarget) -> Bool {
        let isAnthropicShape = target == .claudeCode
        return activeAccounts.contains { account in
            let pool = poolForProvider(account.providerID)
            return (pool == .anthropic) == isAnthropicShape || pool == .openaiCompat && !isAnthropicShape
        }
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

    private struct AccountGroup {
        let providerID: ProviderID
        let accounts: [ProviderAccountDoc]
    }

    private var activeAccounts: [ProviderAccountDoc] {
        providerAccounts.filter { $0.status != .deleted }
    }

    private var accountGroups: [AccountGroup] {
        Dictionary(grouping: activeAccounts, by: \.providerID)
            .map { providerID, accounts in
                AccountGroup(
                    providerID: providerID,
                    accounts: accounts.sorted { lhs, rhs in
                        if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
                        if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
                        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                    }
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
        viewModel.refreshWiringState()
    }

    private func providerDisplayName(_ providerID: ProviderID) -> String {
        AgentProvider.fromProviderID(providerID)?.displayName ?? providerID.rawValue
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

    // MARK: - Pool inference

    /// Internal-only pool partition. Matches the daemon's `formatFamily` —
    /// the user never sees this label.
    private enum InternalPool {
        case openaiCompat
        case anthropic
    }

    private func poolForProvider(_ providerID: ProviderID) -> InternalPool {
        if let catalogProvider = BurnBarCatalogLoader.bundledCatalog.provider(id: providerID.rawValue) {
            switch catalogProvider.formatFamily {
            case .anthropic: return .anthropic
            case .openaiCompat: return .openaiCompat
            }
        }
        return .openaiCompat
    }
}

// MARK: - Provider Account Group

/// One provider's slice of the Accounts list. Shows the failover chain
/// (Active now / Next fallback chips), each account with a single status
/// line, and a "+ Add another <Provider> key" button that anchors the
/// multi-account-per-provider premise.
private struct ProviderAccountGroup: View {
    let providerID: ProviderID
    let accounts: [ProviderAccountDoc]
    let routingState: ProviderRoutingStateSnapshot?
    let onTapAccount: (ProviderAccountDoc) -> Void
    let onAddAnother: () -> Void

    private var provider: AgentProvider? {
        AgentProvider.fromProviderID(providerID)
    }

    private var providerDisplayName: String {
        provider?.displayName ?? providerID.rawValue
    }

    private var activeAccountID: String? { routingState?.activeAccount?.accountID }
    private var nextFallbackAccountID: String? { routingState?.nextFallback?.accountID }

    /// One-line rotation summary derived from the accounts themselves. The
    /// user never sees the internal `ProviderRouterMode` distinction — they
    /// just see "auto-rotate" / "<account> first" so they know what to expect.
    private var rotationSummary: String {
        if accounts.count == 1 { return "single account" }
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
                    onTap: { onTapAccount(account) }
                )
            }
            if accounts.count == 1 {
                singleAccountHint
            }
            Button(action: onAddAnother) {
                Label("Add another \(providerDisplayName) key", systemImage: "plus")
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
                Text("\(accounts.count) account\(accounts.count == 1 ? "" : "s") · \(rotationSummary)")
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
            Text("Add another key to enable automatic failover when this one runs out.")
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

// MARK: - App Connect Row

/// One row per CLI in the Apps section. The button is **smart** — it auto-
/// enables the gateway and runs wire + probe in one click.
private struct AppConnectRow: View {
    let target: RoutingClientWiringTarget
    let state: AppConnectState
    let isDisabled: Bool
    let onConnect: () -> Void
    let onTest: () -> Void
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
        return false
    }

    private var statusTint: Color {
        switch state {
        case .connected: return DesignSystem.Colors.success
        case .connecting, .probing: return DesignSystem.Colors.textSecondary
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
        case .connected: return "Connected via local gateway"
        case .connecting: return "Connecting…"
        case .probing: return "Testing…"
        case .degraded(let message):
            return "Configured, but the local gateway didn't answer. \(message)"
        case .error(let message): return message
        case .notConnected: return isDisabled
            ? "Add an account first, then connect \(target.displayName)."
            : nil
        case .unknown: return nil
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch state {
        case .notConnected, .unknown:
            Button(action: onConnect) {
                Text("Connect")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isDisabled)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
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
            Button(action: onTest) {
                Text("Test")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
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

// MARK: - Add Account Provider Picker

/// Minimal provider chooser for the top-level `+ Add account` CTA. Picks the
/// provider, then hands off to the existing ProviderPlanWizardView for the
/// credential-entry flow (which is unchanged structurally — only its copy is
/// polished elsewhere in this change).
private struct AddAccountProviderPicker: View {
    let daemonManager: OpenBurnBarDaemonManager
    let onSelectProvider: (String) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""

    private var filtered: [OpenBurnBarDaemonProviderConfiguration] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = daemonManager.providerConfigurations.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        if q.isEmpty { return sorted }
        return sorted.filter {
            $0.displayName.lowercased().contains(q)
                || $0.providerID.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Add an account")
                    .font(DesignSystem.Typography.headline)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }

            Text("Pick which provider this key is for. You can come back and add more keys for the same provider any time.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            TextField("Search providers", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filtered) { config in
                        Button {
                            onSelectProvider(config.providerID)
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                CatalogProviderLogoView(brand: config.brand, size: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(config.displayName)
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    Text("\(config.credentialSlots.count) account\(config.credentialSlots.count == 1 ? "" : "s") connected")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            .padding(DesignSystem.Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 280)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 520, idealHeight: 540)
    }
}

// MARK: - Sheet target wrapper

/// Identifiable wrapper so the wizard sheet can present-by-item without
/// dropping the provider ID across navigation churn.
private struct ProviderWizardTarget: Identifiable {
    let providerID: String
    var id: String { providerID }
}
