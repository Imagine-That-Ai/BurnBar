import SwiftUI
import AppKit
import OpenBurnBarCore

struct ProvidersSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var daemonManager: OpenBurnBarDaemonManager
    let dataStore: DataStore
    let accountManager: AccountManager

    @State private var quotaService = ProviderQuotaService.shared
    @StateObject private var deviceLinksObserver: ProviderAccountDeviceLinksObserver

    @State private var wizardProviderID: ProviderWizardTarget?
    @State private var providerAccounts: [ProviderAccountDoc] = []
    @State private var providerAccountLoadError: String?

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
        self._deviceLinksObserver = StateObject(
            wrappedValue: ProviderAccountDeviceLinksObserver(accountManager: accountManager)
        )
    }

    private var providers: [AgentProvider] {
        AgentProvider.allCases.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                SettingsSectionHeader(title: "Routed Providers")

                routerModeCard

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Daemon routing")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text("OpenBurnBar's routed providers live behind the local daemon and are mirrored here from the daemon config.")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            Spacer()
                            Button("Refresh") {
                                Task { await daemonManager.refreshHealth() }
                            }
                            .buttonStyle(.bordered)
                        }

                        if daemonManager.providerConfigurations.isEmpty {
                            Text("No daemon provider configuration is available yet. Install or repair the daemon to manage routed providers.")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        } else {
                            ForEach(daemonManager.providerConfigurations) { configuration in
                                providerCard(configuration)

                                if configuration.id != daemonManager.providerConfigurations.last?.id {
                                    Divider().background(DesignSystem.Colors.border)
                                }
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                SettingsSectionHeader(title: "Quota Reporting")

                ProviderQuotaSettingsSection(
                    settingsManager: settingsManager,
                    quotaService: quotaService,
                    dataStore: dataStore,
                    onOpenProviderPlans: openProviderPlans(for:),
                    quotaSourceSummary: quotaSourceSummary(for:)
                )

                SettingsSectionHeader(title: "Smart Hubs")

                ProviderQuotaSmartHubsSection(settingsManager: settingsManager)

                SettingsSectionHeader(title: "Provider Accounts")

                providerAccountsSection

                SettingsSectionHeader(title: "CLI Connections")

                CLIConnectionsSettingsSection()

                SettingsSectionHeader(title: "Observed Log Sources")

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        ForEach(providers) { provider in
                            ProviderObservationRow(
                                provider: provider,
                                configuredPath: settingsManager.logPaths[provider] ?? provider.logDirectory,
                                isDetected: settingsManager.detectAvailableProviders()[provider] ?? false
                            )

                            if provider.id != providers.last?.id {
                                Divider().background(DesignSystem.Colors.border)
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .sheet(item: $wizardProviderID) { target in
            ProviderPlanWizardView(
                daemonManager: daemonManager,
                initialProviderID: target.providerID
            ) {
                wizardProviderID = nil
            }
        }
        .task {
            await daemonManager.refreshHealth()
            loadProviderAccounts()
            await quotaService.refreshIfNeeded(dataStore: dataStore)
        }
        .onAppear { deviceLinksObserver.start() }
        .onDisappear { deviceLinksObserver.stop() }
    }

    private var routerModeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                    Image(systemName: daemonManager.routerMode.iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.blaze)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Router mode")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text(daemonManager.routerMode.shortDescription)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: DesignSystem.Spacing.md)

                    Picker("Router mode", selection: Binding(
                        get: { daemonManager.routerMode },
                        set: { mode in
                            Task { @MainActor in
                                await daemonManager.setRouterMode(mode)
                                await daemonManager.refreshHealth()
                            }
                        }
                    )) {
                        ForEach(ProviderRouterMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 380)
                    .disabled(daemonManager.isBusy)
                    .accessibilityLabel("Router mode")
                    .help("Choose whether routed clients stay inside the selected provider family or use the intelligent cross-provider router.")
                }

                if daemonManager.routerMode == .intelligentModelRouter {
                    Label("Uses task fit, account health, cost, latency, capability, and benchmark freshness when routing compatible requests.", systemImage: "chart.line.uptrend.xyaxis")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    @ViewBuilder
    private var providerAccountsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Account inventory")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Each provider can hold multiple accounts. OpenBurnBar shows where each one is stored and who refreshes its quota — credentials never appear here.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: DesignSystem.Spacing.md)

                    Button {
                        loadProviderAccounts()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .help("Re-read provider accounts from this Mac's local store")
                    .accessibilityLabel("Refresh provider accounts")
                }

                if let providerAccountLoadError {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DesignSystem.Colors.error)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Could not load provider accounts")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text(providerAccountLoadError)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(DesignSystem.Spacing.md)
                    .background(DesignSystem.Colors.error.opacity(0.08))
                    .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                } else if providerAccounts.isEmpty {
                    providerAccountsEmptyState
                } else {
                    VStack(spacing: DesignSystem.Spacing.md) {
                        ForEach(groupedProviderAccounts, id: \.providerID) { group in
                            providerAccountGroup(providerID: group.providerID, accounts: group.accounts)
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private var providerAccountsEmptyState: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.whimsy.opacity(0.10))
                    .frame(width: 36, height: 36)
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.whimsy)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("No provider accounts yet")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Connect a provider plan above or sign in on iPhone to start populating this list. Plans saved in the daemon appear here as Mac Keychain accounts.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.40))
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    private var groupedProviderAccounts: [(providerID: ProviderID, accounts: [ProviderAccountDoc])] {
        Dictionary(grouping: providerAccounts, by: \.providerID)
            .map { providerID, accounts in
                (
                    providerID,
                    accounts.sorted {
                        if $0.status != $1.status {
                            return statusSortOrder($0.status) < statusSortOrder($1.status)
                        }
                        if $0.isDefault != $1.isDefault { return $0.isDefault && !$1.isDefault }
                        if $0.sortKey != $1.sortKey { return $0.sortKey < $1.sortKey }
                        return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                    }
                )
            }
            .sorted { providerDisplayName($0.providerID) < providerDisplayName($1.providerID) }
    }

    @ViewBuilder
    private func providerAccountGroup(providerID: ProviderID, accounts: [ProviderAccountDoc]) -> some View {
        let provider = AgentProvider.fromProviderID(providerID)
        let activeAccounts = accounts.filter { $0.status != .deleted }
        let removedAccounts = accounts.filter { $0.status == .deleted }
        let routingState = quotaService.routingStatesByProviderID[providerID]

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                if let provider {
                    ZStack {
                        Circle()
                            .fill(DesignSystem.Colors.primary(for: provider).opacity(0.12))
                            .frame(width: 28, height: 28)
                        ProviderLogoView(provider: provider, size: 18, useFallbackColor: false)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(providerDisplayName(providerID))
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(activeAccountSummary(activeAccounts))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer(minLength: DesignSystem.Spacing.sm)
                ProviderAccountStorageSummary(accounts: activeAccounts)
            }

            if let provider,
               let routingState,
               shouldShowCockpit(activeAccounts: activeAccounts, routingState: routingState) {
                ProviderRoutingCockpit(provider: provider, state: routingState)
            }

            if activeAccounts.isEmpty {
                Text("All accounts for this provider have been removed.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.leading, 36)
            } else {
                VStack(spacing: 6) {
                    ForEach(activeAccounts) { account in
                        ProviderAccountRow(
                            account: account,
                            routingHint: routingHint(for: account, in: routingState),
                            deviceLinks: deviceLinksObserver.links(for: account.id)
                        )
                    }
                }
            }

            if !removedAccounts.isEmpty {
                DisclosureGroup {
                    VStack(spacing: 6) {
                        ForEach(removedAccounts) { account in
                            ProviderAccountRow(
                                account: account,
                                deviceLinks: deviceLinksObserver.links(for: account.id)
                            )
                                .opacity(0.6)
                        }
                    }
                    .padding(.top, DesignSystem.Spacing.xs)
                } label: {
                    Text("\(removedAccounts.count) removed account\(removedAccounts.count == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .padding(.leading, 36)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.30))
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }

    private func activeAccountSummary(_ accounts: [ProviderAccountDoc]) -> String {
        let count = accounts.count
        if count == 0 { return "No accounts connected" }
        let stale = accounts.filter { $0.status == .stale }.count
        let errors = accounts.filter { $0.status == .error }.count
        var parts: [String] = ["\(count) account\(count == 1 ? "" : "s")"]
        if errors > 0 { parts.append("\(errors) needs attention") }
        else if stale > 0 { parts.append("\(stale) stale") }
        return parts.joined(separator: " · ")
    }

    private func statusSortOrder(_ status: ProviderAccountStatus) -> Int {
        switch status {
        case .error: return 0
        case .stale: return 1
        case .connected: return 2
        case .disconnected: return 3
        case .disabled: return 4
        case .deleted: return 5
        }
    }

    private func loadProviderAccounts() {
        do {
            providerAccounts = try dataStore.providerAccountStore.fetchAll()
            providerAccountLoadError = nil
        } catch {
            providerAccounts = []
            providerAccountLoadError = error.localizedDescription
        }
        quotaService.refreshRoutingState(
            dataStore: dataStore,
            request: ProviderRoutingRequest(
                routerMode: OpenBurnBarDaemonManager.shared.routerMode,
                taskCategory: .coding
            )
        )
    }

    private func providerDisplayName(_ providerID: ProviderID) -> String {
        AgentProvider.fromProviderID(providerID)?.displayName ?? providerID.rawValue
    }

    /// The cockpit only earns its space when it actually adds information.
    /// A single, healthy account already says everything via its row chips, so
    /// we suppress the cockpit there to keep the Settings list calm. As soon
    /// as there are multiple accounts, or any blocked/non-healthy account
    /// across the group, the cockpit appears so the user can see who is on
    /// deck and why.
    private func shouldShowCockpit(
        activeAccounts: [ProviderAccountDoc],
        routingState: ProviderRoutingStateSnapshot
    ) -> Bool {
        guard !activeAccounts.isEmpty else { return false }
        if activeAccounts.count > 1 { return true }
        return routingState.hasMeaningfulRoutingDetail
    }

    /// Picks the per-account hint shown next to a settings row so the same
    /// account reads consistently between the routing cockpit, the storage
    /// chip, and the row footer.
    private func routingHint(
        for account: ProviderAccountDoc,
        in state: ProviderRoutingStateSnapshot?
    ) -> ProviderAccountRoutingHint? {
        guard let state else { return nil }
        if state.activeAccount?.accountID == account.id {
            return ProviderAccountRoutingHint(
                role: .active,
                quotaState: state.activeAccount?.quotaState ?? .unknown,
                cooldownUntil: state.activeAccount?.cooldownUntil
            )
        }
        if state.nextFallback?.accountID == account.id {
            return ProviderAccountRoutingHint(
                role: .nextFallback,
                quotaState: state.nextFallback?.quotaState ?? .unknown,
                cooldownUntil: state.nextFallback?.cooldownUntil
            )
        }
        if let blocked = state.exhaustedOrCoolingDownAccounts.first(where: { $0.accountID == account.id }) {
            return ProviderAccountRoutingHint(
                role: .blocked,
                quotaState: blocked.quotaState,
                cooldownUntil: blocked.cooldownUntil
            )
        }
        return nil
    }

    // MARK: - Provider Card

    @ViewBuilder
    private func providerCard(_ config: OpenBurnBarDaemonProviderConfiguration) -> some View {
        Button {
            wizardProviderID = ProviderWizardTarget(providerID: config.providerID)
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                CatalogProviderLogoView(brand: config.brand, size: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(config.displayName)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        if config.isEnabled == false {
                            Text("Off")
                                .font(DesignSystem.Typography.tiny)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(DesignSystem.Colors.textMuted.opacity(0.15))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .clipShape(Capsule())
                        }
                    }

                    if config.credentialSlots.isEmpty {
                        Text("No plans configured")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    } else {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            ForEach(config.credentialSlots) { slot in
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(slotStatusColor(for: slot.status))
                                        .frame(width: 6, height: 6)
                                    Text(slot.label)
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    if let pct = slot.lastQuotaRemainingPercent {
                                        Text("\(Int(pct.rounded()))%")
                                            .font(DesignSystem.Typography.monoTiny)
                                            .foregroundStyle(DesignSystem.Colors.textMuted)
                                    }
                                }
                            }
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.md)
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func slotStatusColor(for status: BurnBarProviderCredentialSlotStatus) -> Color {
        switch status {
        case .ready: return DesignSystem.Colors.success
        case .coolingDown: return DesignSystem.Colors.warning
        case .exhausted, .missingSecret: return DesignSystem.Colors.error
        case .disabled: return DesignSystem.Colors.textMuted
        }
    }

    private func openProviderPlans(for provider: AgentProvider) {
        guard let providerID = provider.providerCatalogID else { return }
        wizardProviderID = ProviderWizardTarget(providerID: providerID)
    }

    private func quotaSourceSummary(for provider: AgentProvider) -> String? {
        switch provider {
        case .minimax, .zai, .ollama:
            guard let configuration = daemonManager.providerConfigurations.first(where: { $0.provider == provider }) else {
                return "No routed provider plan is configured yet."
            }
            guard !configuration.credentialSlots.isEmpty else {
                return "No provider plans configured yet."
            }
            if let preferredSlotID = configuration.preferredCredentialSlotID,
               let preferredSlot = configuration.credentialSlots.first(where: { $0.slotID == preferredSlotID }) {
                if provider == .ollama {
                    return "Using preferred Ollama Cloud plan “\(preferredSlot.label)” for routed gateway traffic. Quota windows still come from Ollama's local/cloud usage signals when available."
                }
                return "Using preferred daemon plan “\(preferredSlot.label)” for quota refresh when available."
            }
            if let firstEnabledSlot = configuration.credentialSlots.first(where: \.isEnabled) {
                if provider == .ollama {
                    return "Using Ollama Cloud plan “\(firstEnabledSlot.label)” for routed gateway traffic. Quota windows still come from Ollama's local/cloud usage signals when available."
                }
                return "Using daemon plan “\(firstEnabledSlot.label)” for quota refresh when available."
            }
            return "Provider plans exist, but none are enabled for quota refresh."
        case .codex:
            return "Quota comes from local Codex rollout/session logs on this Mac."
        case .claudeCode:
            return "Quota comes from Claude Code status line payloads captured locally."
        case .factory:
            return "Factory quota uses your local session credentials or selected plan tier."
        case .cursor:
            return "Cursor quota uses the configured cookie header or local routed-token estimates."
        default:
            return nil
        }
    }
}

// MARK: - Wizard Sheet Target

private struct ProviderWizardTarget: Identifiable {
    let providerID: String
    var id: String { providerID }
}

// MARK: - Provider Account Row

/// Tells the settings row which lane an account currently occupies in the
/// router. Allows the row to mirror cockpit copy without re-deriving routing
/// state on every redraw.
struct ProviderAccountRoutingHint {
    enum Role {
        case active
        case nextFallback
        case blocked
    }

    let role: Role
    let quotaState: ProviderRoutingQuotaState
    let cooldownUntil: Date?
}

private struct ProviderAccountRow: View {
    let account: ProviderAccountDoc
    var routingHint: ProviderAccountRoutingHint?
    var deviceLinks: [ProviderAccountDeviceLinksObserver.Link] = []

    private var statusTint: Color {
        ProviderAccountStatusVisual.tint(account.status)
    }

    private var detailLine: String? {
        // Prefer human-readable identity hint over the redacted credential
        // descriptor, but never both. Empty values fall back to nil so the
        // row collapses cleanly under Dynamic Type.
        let hint = account.identityHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hint, !hint.isEmpty, hint != account.label {
            return hint
        }
        let redacted = account.redactedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !redacted.isEmpty, redacted != account.label {
            return redacted
        }
        return nil
    }

    private var refreshSubtext: String? {
        if account.status == .deleted {
            return "Removed from this Mac. Quota refresh is paused."
        }
        if let lastError = account.lastErrorCode?.trimmingCharacters(in: .whitespacesAndNewlines), !lastError.isEmpty {
            return "Last error: \(lastError)"
        }
        if let last = account.lastRefreshAt {
            return "Refreshed \(last.formatted(.relative(presentation: .named)))"
        }
        if let validated = account.lastValidatedAt {
            return "Validated \(validated.formatted(.relative(presentation: .named)))"
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            // Left rail: status indicator
            VStack(spacing: 0) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
            }
            .frame(width: 12)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
                    Text(account.label)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if account.isDefault {
                        Text("Default")
                            .font(DesignSystem.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.blaze)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignSystem.Colors.blaze.opacity(0.12))
                            .clipShape(Capsule())
                            .accessibilityLabel("Default account for this provider")
                    }

                    if let routingHint {
                        routingHintChip(routingHint)
                    }

                    if let chipText = deviceLinksChipText {
                        deviceLinksChip(chipText)
                    }

                    Spacer(minLength: DesignSystem.Spacing.sm)

                    ProviderAccountStatusChip(status: account.status, compact: true)
                }

                if let detailLine {
                    Text(detailLine)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack(spacing: DesignSystem.Spacing.xs) {
                    ProviderAccountStorageChip(scope: account.storageScope, compact: true)

                    if let refreshSubtext {
                        Text("·")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(refreshSubtext)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(account.status == .error ? DesignSystem.Colors.warning : DesignSystem.Colors.textMuted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.background.opacity(0.45))
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.30), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text(ProviderAccountStorage.description(account.storageScope)))
    }

    private var accessibilityLabel: String {
        var parts: [String] = [account.label]
        if account.isDefault { parts.append("default") }
        if let routingHint {
            parts.append(routingHintAccessibilityFragment(routingHint))
        }
        parts.append(ProviderAccountStatusVisual.label(account.status))
        parts.append("stored in \(ProviderAccountStorage.label(account.storageScope))")
        if let hint = account.identityHint, !hint.isEmpty, hint != account.label {
            parts.append(hint)
        }
        return parts.joined(separator: ", ")
    }

    private var deviceLinksChipText: String? {
        let active = deviceLinks.filter { $0.status != "revoked" }
        guard !active.isEmpty else { return nil }
        if active.count == 1, let only = active.first {
            switch only.capability {
            case .owner: return "This Mac"
            case .add: return "Adds here"
            case .use: return only.label.map { "On \($0)" } ?? "On 1 device"
            }
        }
        return "On \(active.count) devices"
    }

    @ViewBuilder
    private func deviceLinksChip(_ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(DesignSystem.Colors.whimsy)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(DesignSystem.Colors.whimsy.opacity(0.12))
        .clipShape(Capsule())
        .help("Devices that have adopted this account")
        .accessibilityLabel("\(text)")
    }

    @ViewBuilder
    private func routingHintChip(_ hint: ProviderAccountRoutingHint) -> some View {
        let style = routingHintStyle(hint)
        HStack(spacing: 3) {
            Image(systemName: style.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(style.label)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(style.tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(style.tint.opacity(0.12))
        .clipShape(Capsule())
        .help(style.help)
    }

    private struct RoutingHintStyle {
        let label: String
        let icon: String
        let tint: Color
        let help: String
    }

    private func routingHintStyle(_ hint: ProviderAccountRoutingHint) -> RoutingHintStyle {
        switch hint.role {
        case .active:
            return RoutingHintStyle(
                label: "Active now",
                icon: "arrowtriangle.right.circle.fill",
                tint: DesignSystem.Colors.success,
                help: "Router is sending traffic to this account."
            )
        case .nextFallback:
            return RoutingHintStyle(
                label: "Next fallback",
                icon: "arrow.triangle.branch",
                tint: DesignSystem.Colors.amber,
                help: "Router will switch to this account if the active one becomes unavailable."
            )
        case .blocked:
            return RoutingHintStyle(
                label: ProviderRoutingVisual.label(hint.quotaState),
                icon: ProviderRoutingVisual.iconName(hint.quotaState),
                tint: ProviderRoutingVisual.tint(hint.quotaState),
                help: blockedHintHelp(hint)
            )
        }
    }

    private func blockedHintHelp(_ hint: ProviderAccountRoutingHint) -> String {
        var parts = [ProviderRoutingVisual.label(hint.quotaState)]
        if let cooldown = hint.cooldownUntil, cooldown > Date() {
            parts.append("Resumes \(cooldown.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private func routingHintAccessibilityFragment(_ hint: ProviderAccountRoutingHint) -> String {
        switch hint.role {
        case .active:
            return "currently active"
        case .nextFallback:
            return "next fallback"
        case .blocked:
            return "blocked: \(ProviderRoutingVisual.label(hint.quotaState).lowercased())"
        }
    }
}

private struct ProviderObservationRow: View {
    let provider: AgentProvider
    let configuredPath: String
    let isDetected: Bool

    private var supportLabel: String {
        switch provider.supportLevel {
        case .supported: return "Supported"
        case .partial: return "Partial"
        case .unsupported: return "Not yet supported"
        }
    }

    private var supportColor: Color {
        switch provider.supportLevel {
        case .supported: return DesignSystem.Colors.success
        case .partial: return DesignSystem.Colors.warning
        case .unsupported: return DesignSystem.Colors.textMuted
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ProviderLogoView(provider: provider, size: 20, useFallbackColor: false)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(provider.displayName)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(supportLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(supportColor)
                }

                Text(configuredPath)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textSelection(.enabled)

                Text(isDetected ? "Detected on this Mac" : "Not currently detected")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(isDetected ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
            }

            Spacer()
        }
    }
}

private struct CLIConnectionsSettingsSection: View {
    @State private var authStates: [SwitcherCLIProfileType: CLIAuthInfo] = [:]
    @State private var testResults: [SwitcherCLIProfileType: String] = [:]
    @State private var activeTests: Set<SwitcherCLIProfileType> = []
    @State private var activeLogins: Set<SwitcherCLIProfileType> = []

    private let supportedCLIs: [SwitcherCLIProfileType] = [.claude, .codex, .opencode]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("Check whether Claude Code, Codex, and OpenCode are installed and authenticated, then open supported login flows in Terminal when needed.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                ForEach(supportedCLIs, id: \.self) { cliType in
                    CLIConnectionCard(
                        cliType: cliType,
                        authInfo: authStates[cliType],
                        testResult: testResults[cliType],
                        isTesting: activeTests.contains(cliType),
                        isLoggingIn: activeLogins.contains(cliType),
                        onTest: { runCheck(for: cliType) },
                        onLogin: { openLogin(for: cliType) }
                    )

                    if cliType != supportedCLIs.last {
                        Divider().background(DesignSystem.Colors.border)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .task {
            refreshAll()
        }
    }

    private func refreshAll() {
        for cliType in supportedCLIs {
            authStates[cliType] = CLIAuthDiscovery.discoverAuthState(for: cliType)
            testResults[cliType] = nil
        }
    }

    private func runCheck(for cliType: SwitcherCLIProfileType) {
        activeTests.insert(cliType)
        defer { activeTests.remove(cliType) }

        let authInfo = CLIAuthDiscovery.discoverAuthState(for: cliType)
        authStates[cliType] = authInfo
        testResults[cliType] = statusSummary(for: authInfo)
    }

    private func openLogin(for cliType: SwitcherCLIProfileType) {
        guard let executablePath = CLILaunchAdapter.executablePath(for: cliType) else {
            testResults[cliType] = "\(cliType.displayName) is not installed."
            return
        }

        activeLogins.insert(cliType)
        defer { activeLogins.remove(cliType) }

        let command = loginCommands(for: cliType, executablePath: executablePath).first
        guard let command else {
            testResults[cliType] = "No login command is available for \(cliType.displayName)."
            return
        }

        do {
            let scriptURL = try makeLoginScript(command: command, title: cliType.displayName)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([scriptURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error {
                        testResults[cliType] = "Could not open Terminal: \(error.localizedDescription)"
                        return
                    }
                    testResults[cliType] = "Opened \(cliType.displayName) login in Terminal. Run Test again after signing in."
                }
            }
        } catch {
            testResults[cliType] = "Could not prepare login command: \(error.localizedDescription)"
        }
    }

    private func loginCommands(for cliType: SwitcherCLIProfileType, executablePath: String) -> [String] {
        let candidates: [[String]]
        switch cliType {
        case .codex:
            candidates = [["login"], ["auth", "login"]]
        case .claude:
            candidates = [["auth", "login"], ["login"]]
        case .opencode:
            candidates = []
        }

        return candidates.map { args in
            ([executablePath] + args).map(shellEscape).joined(separator: " ")
        }
    }

    private func makeLoginScript(command: String, title: String) throws -> URL {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))-\(UUID().uuidString).command")
        let contents = """
        #!/bin/zsh
        \(command)
        printf '\\nPress Enter to close…'
        read
        """
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func statusSummary(for authInfo: CLIAuthInfo) -> String {
        guard authInfo.isInstalled else {
            return "\(authInfo.cliType.displayName) is not installed."
        }

        switch authInfo.authState {
        case .authenticated:
            if let accountDescription = authInfo.accountDescription {
                return "Connected as \(accountDescription)."
            }
            return "Connected."
        case .apiKeyPresent:
            return "API key detected."
        case .notAuthenticated:
            return "Installed, but not authenticated."
        case .notInstalled:
            return "Not installed."
        }
    }
}

private struct CLIConnectionCard: View {
    let cliType: SwitcherCLIProfileType
    let authInfo: CLIAuthInfo?
    let testResult: String?
    let isTesting: Bool
    let isLoggingIn: Bool
    let onTest: () -> Void
    let onLogin: () -> Void

    private var stateColor: Color {
        guard let authInfo else { return DesignSystem.Colors.textMuted }
        switch authInfo.authState {
        case .authenticated, .apiKeyPresent:
            return DesignSystem.Colors.success
        case .notAuthenticated:
            return DesignSystem.Colors.warning
        case .notInstalled:
            return DesignSystem.Colors.error
        }
    }

    private var stateLabel: String {
        guard let authInfo else { return "Checking…" }
        switch authInfo.authState {
        case .authenticated:
            return "Connected"
        case .apiKeyPresent:
            return "API key present"
        case .notAuthenticated:
            return "Needs login"
        case .notInstalled:
            return "Not installed"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ProviderLogoView(provider: cliType.provider, size: 28, useFallbackColor: true)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(cliType.displayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(stateLabel)
                        .font(DesignSystem.Typography.tiny)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(stateColor.opacity(0.14))
                        .foregroundStyle(stateColor)
                        .clipShape(Capsule())
                }

                if let accountDescription = authInfo?.accountDescription, !accountDescription.isEmpty {
                    Text(accountDescription)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                if let executablePath = authInfo?.executablePath {
                    Text(executablePath)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .textSelection(.enabled)
                }

                if let configDirectory = authInfo?.configDirectory {
                    Text(configDirectory)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .textSelection(.enabled)
                }

                Text(testResult ?? helperText)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: DesignSystem.Spacing.sm) {
                Button(isTesting ? "Testing…" : "Test") {
                    onTest()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting)

                Button(isLoggingIn ? "Opening…" : loginButtonTitle) {
                    onLogin()
                }
                .buttonStyle(.bordered)
                .disabled(isLoggingIn)
            }
        }
    }

    private var loginButtonTitle: String {
        switch authInfo?.authState {
        case .authenticated, .apiKeyPresent:
            return "Reconnect"
        default:
            return "Connect"
        }
    }

    private var helperText: String {
        switch cliType {
        case .claude:
            return "Claude Code must be logged in locally before BurnBar can confirm the CLI connection."
        case .codex:
            return "Codex supports either OAuth or an OpenAI API key in the local config."
        case .opencode:
            return "OpenCode can use the OpenBurnBar Gateway through the routed client sync in Quota Reporting."
        }
    }
}

private extension ProviderRouterMode {
    var displayName: String {
        switch self {
        case .providerFamilyFailover:
            return "Provider-Family Failover"
        case .intelligentModelRouter:
            return "Intelligent Model Router"
        }
    }

    var shortDescription: String {
        switch self {
        case .providerFamilyFailover:
            return "Keeps routed requests inside the selected provider family, then fails over across your accounts."
        case .intelligentModelRouter:
            return "Can rank compatible providers by task fit, account health, cost, latency, capability, and benchmark freshness."
        }
    }

    var iconName: String {
        switch self {
        case .providerFamilyFailover:
            return "rectangle.2.swap"
        case .intelligentModelRouter:
            return "brain.head.profile"
        }
    }
}

private extension SwitcherCLIProfileType {
    var provider: AgentProvider {
        switch self {
        case .claude:
            return .claudeCode
        case .codex:
            return .codex
        case .opencode:
            return .openClaw
        }
    }
}

private extension AgentProvider {
    var providerCatalogID: String? {
        switch self {
        case .minimax:
            return "minimax"
        case .zai:
            return "zai"
        case .ollama:
            return "ollama"
        default:
            return nil
        }
    }
}
