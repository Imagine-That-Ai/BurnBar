import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Plan Strategy

enum ProviderPlanStrategy: String, CaseIterable, Identifiable {
    case auto
    case preferred
    case backup

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto rotate"
        case .preferred: return "Always preferred"
        case .backup: return "Backup only"
        }
    }

    var iconName: String {
        switch self {
        case .auto: return "arrow.triangle.2.circlepath"
        case .preferred: return "star.fill"
        case .backup: return "shield.lefthalf.filled"
        }
    }

    var summary: String {
        switch self {
        case .auto: return "Rotate fairly across your accounts"
        case .preferred: return "Try this account first; fall back on failure"
        case .backup: return "Stay disabled until other accounts fail"
        }
    }
}

// MARK: - Wizard Steps

enum ProviderPlanWizardStep: Int, CaseIterable {
    case dashboard
    case provider
    case auth
    case credential
    case strategy
    case confirm

    var stepIndex: Int? {
        switch self {
        case .dashboard: return nil
        case .provider: return 1
        case .auth: return 2
        case .credential: return 3
        case .strategy: return 4
        case .confirm: return 5
        }
    }

    var shortTitle: String {
        switch self {
        case .dashboard: return "Accounts"
        case .provider: return "Provider"
        case .auth: return "Method"
        case .credential: return "Credential"
        case .strategy: return "Strategy"
        case .confirm: return "Review"
        }
    }
}

// MARK: - Wizard View

struct ProviderPlanWizardView: View {
    let daemonManager: OpenBurnBarDaemonManager

    let dataStore: DataStore

    let initialProviderID: String?

    let startsAtProviderSelection: Bool

    let onDismiss: () -> Void

    @State var currentStep: ProviderPlanWizardStep = .dashboard

    @State var quotaService = ProviderQuotaService.shared

    // Dashboard state
    @State var activeProviderID: String?

    @State var switcherProfiles: [SwitcherProfileRecord] = []

    @State var switcherProfileLoadError: String?

    @State var dashboardExternalAuthStates: [String: CLIAuthInfo] = [:]

    @State var gatewayAdvertisedProviderIDs: Set<String>?

    @State var gatewayProviderRouteIssues: [String: String] = [:]

    @State var gatewayAdvertisementError: String?

    @State var preferredSlotActionIDs: Set<String> = []

    // Provider step state
    @State var selectedProviderID: String?

    @State var providerSearchQuery: String = ""

    // Auth method step state
    @State var selectedAuthMethodID: String?

    // Credential step state
    @State var planLabel = ""

    @State var apiKeyInput = ""

    @State var credentialStorageOverride: String?

    @State var credentialStorageOverrideVisibleToken: String?

    @State var showAPIKey = false

    @State var isProbingQuota = false

    @State var quotaProbeResult: String?

    @State var quotaProbePercent: Double?

    @State var quotaProbeError: String?

    @State var quotaProbeTask: Task<Void, Never>?

    @State var isImportingCredential = false

    @State var credentialImportMessage: String?

    @State var externalAuthInfo: CLIAuthInfo?

    @State var externalAuthMessage: String?

    @State var isOpeningExternalLogin = false

    @State var isAddingExternalAccount = false

    @State var externalAccountActionMessage: String?

    @State var editingCredentialSlot: EditingCredentialSlot?

    @State var localMimoRegion: ProviderEndpointRegion = .sgp

    @State var localMimoTier: MimoTokenPlanTier = .standard

    @State var localMimoBillingCycle: MimoTokenPlanBillingCycle = .monthly

    // Strategy step state
    @State var selectedStrategy: ProviderPlanStrategy = .auto

    // Save state
    @State var isSaving = false

    @State var saveError: String?

    // Delete confirmation. A single pending-deletion value drives one alert so
    // the slot and external-account confirmations can never suppress each other
    // (two `.alert` modifiers on the same view silently collapse to one on
    // macOS — only the last-attached presents, which previously swallowed the
    // slot "Delete plan?" confirmation entirely and made the trash button look
    // dead).
    @State var pendingDeletion: PendingAccountDeletion?

    /// In-flight deletion target id, so a second tap on the same row's trash is
    /// a no-op while the daemon round-trip completes.
    @State var deletingAccountID: String?

    enum PendingAccountDeletion: Identifiable {
        case slot(SlotDeleteTarget)
        case external(ExternalAccountDeleteTarget)

        var id: String {
            switch self {
            case .slot(let target): return "slot:\(target.id)"
            case .external(let target): return "external:\(target.id)"
            }
        }

        var alertTitle: String {
            switch self {
            case .slot: return "Delete plan?"
            case .external: return "Remove account?"
            }
        }

        var confirmTitle: String {
            switch self {
            case .slot: return "Delete"
            case .external: return "Remove"
            }
        }

        var message: String {
            switch self {
            case .slot(let target):
                return "This permanently removes the plan \"\(target.slotLabel)\" and its credentials."
            case .external(let target):
                return "This removes \"\(target.label)\" from BurnBar and deletes its stored switcher credentials. It does not sign out your default local CLI login."
            }
        }
    }

    struct SlotDeleteTarget: Identifiable {
        let providerID: String
        let slotID: String
        let slotLabel: String
        var id: String { slotID }
    }

    struct EditingCredentialSlot: Identifiable {
        let providerID: String
        let slotID: String
        var id: String { "\(providerID):\(slotID)" }
    }

    struct ExternalAccountDeleteTarget: Identifiable {
        let profileID: String
        let label: String
        let cliType: SwitcherCLIProfileType
        var id: String { profileID }
    }

    struct ExternalOAuthAccount: Identifiable {
        let id: String
        let cliType: SwitcherCLIProfileType
        let label: String
        let detail: String?
        let statusText: String
        let isCurrentLogin: Bool
        let isDisabled: Bool
        let profile: SwitcherProfileRecord?
    }

    struct GatewayModelsEnvelope: Decodable {
        let data: [GatewayModelRow]
    }

    struct GatewayModelRow: Decodable {
        let providerID: String?
        let ownedBy: String?
        let quotaState: String?
        let lastError: String?
        let enabled: Bool?
        let routeEligible: Bool?

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case ownedBy = "owned_by"
            case quotaState = "quota_state"
            case lastError = "last_error"
            case enabled
            case routeEligible = "route_eligible"
        }
    }
    var eligibleProviders: [OpenBurnBarDaemonProviderConfiguration] {
        let sorted = daemonManager.providerConfigurations.sorted { lhs, rhs in
            let lhsHasRouting = lhs.hasRoutingCapability
            let rhsHasRouting = rhs.hasRoutingCapability
            if lhsHasRouting != rhsHasRouting { return lhsHasRouting && !rhsHasRouting }
            if lhs.credentialSlots.count != rhs.credentialSlots.count {
                return lhs.credentialSlots.count > rhs.credentialSlots.count
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return sorted
    }

    var filteredProviders: [OpenBurnBarDaemonProviderConfiguration] {
        let query = providerSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return eligibleProviders }
        return eligibleProviders.filter { config in
            config.displayName.lowercased().contains(query)
                || config.providerID.lowercased().contains(query)
                || (descriptor(for: config.providerID).aliasProviderIDs.contains { $0.contains(query) })
        }
    }

    var routingProviders: [OpenBurnBarDaemonProviderConfiguration] {
        filteredProviders.filter { $0.hasRoutingCapability }
    }

    var trackingProviders: [OpenBurnBarDaemonProviderConfiguration] {
        filteredProviders.filter { !$0.hasRoutingCapability }
    }

    var activeProvider: OpenBurnBarDaemonProviderConfiguration? {
        guard let id = activeProviderID else { return nil }
        return daemonManager.providerConfigurations.first { $0.providerID == id }
    }

    var selectedProvider: OpenBurnBarDaemonProviderConfiguration? {
        guard let id = selectedProviderID else { return nil }
        return eligibleProviders.first { $0.providerID == id }
    }

    var selectedDescriptor: BurnBarProviderAuthDescriptor? {
        guard let id = selectedProviderID else { return nil }
        return descriptor(for: id)
    }

    var selectedAuthMethod: BurnBarProviderAuthMethod? {
        guard let descriptor = selectedDescriptor else { return nil }
        if let id = selectedAuthMethodID, let method = descriptor.method(id: id) {
            return method
        }
        return descriptor.primaryMethod
    }

    func descriptor(for providerID: String) -> BurnBarProviderAuthDescriptor {
        let displayName = daemonManager.providerConfigurations
            .first { $0.providerID == providerID }?.displayName ?? providerID.capitalized
        let supportsProxy = daemonManager.providerConfigurations
            .first { $0.providerID == providerID }?.hasRoutingCapability ?? true
        return BurnBarProviderAuthRegistry.descriptorOrFallback(
            forCatalogProviderID: providerID,
            displayName: displayName,
            supportsProxyRouting: supportsProxy
        )
    }

    func quotaProbeProvider(for providerID: String) -> AgentProvider? {
        AgentProvider.fromCatalogProviderID(providerID)
    }

    var canProceedFromProvider: Bool { selectedProviderID != nil }

    var canProceedFromAuth: Bool { selectedAuthMethod != nil }

    var canProceedFromCredential: Bool {
        if let method = selectedAuthMethod, method.usesExternalLogin {
            return externalAuthInfo?.isWizardConnected == true
        }
        let trimmedLabel = planLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedKey.isEmpty else { return false }
        return selectedAuthMethod?.validate(trimmedKey).isWarning != true
    }

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader

            Divider().background(DesignSystem.Colors.border)

            ScrollView {
                stepContent
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.top, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(stepTransition)
                    .id(currentStep)
            }

            Divider().background(DesignSystem.Colors.border)

            wizardNavigation
        }
        .frame(width: 600)
        .frame(minHeight: 580)
        .background(DesignSystem.Colors.background)
        .onAppear {
            primeWizardOnAppear()
            loadSwitcherProfiles()
            refreshDashboardExternalAuthStates()
        }
        .task(id: externalAuthRefreshID) {
            refreshDashboardExternalAuthStates()
        }
        .task {
            await quotaService.refreshIfNeeded(dataStore: dataStore)
            await daemonManager.repairProviderCredentialSlotSecrets()
            await refreshGatewayAdvertisementState()
        }
        .onDisappear { quotaProbeTask?.cancel() }
        .alert(
            pendingDeletion?.alertTitle ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { target in
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button(target.confirmTitle, role: .destructive) {
                switch target {
                case .slot(let slot): deleteSlot(slot)
                case .external(let account): deleteExternalAccount(account)
                }
            }
        } message: { target in
            Text(target.message)
        }
    }

    var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    func primeWizardOnAppear() {
        if startsAtProviderSelection {
            activeProviderID = nil
            selectedProviderID = nil
            selectedAuthMethodID = nil
            credentialStorageOverride = nil
            credentialStorageOverrideVisibleToken = nil
            currentStep = .provider
            return
        }

        if let initialID = initialProviderID {
            activeProviderID = initialID
        } else if eligibleProviders.count == 1 {
            activeProviderID = eligibleProviders.first?.providerID
        }
    }

    var externalAuthRefreshID: String {
        let providerPart = eligibleProviders
            .filter { supportsExternalOAuth(for: $0.providerID) }
            .map(\.providerID)
            .joined(separator: "|")
        return providerPart.isEmpty ? "default-cli-oauth" : providerPart
    }

    func loadSwitcherProfiles() {
        do {
            switcherProfiles = try dataStore.switcherStore.fetchAllProfiles()
            switcherProfileLoadError = nil
        } catch {
            switcherProfiles = []
            switcherProfileLoadError = "Could not load OAuth profiles: \(error.localizedDescription)"
        }
    }

    func refreshDashboardExternalAuthStates() {
        var next: [String: CLIAuthInfo] = [:]
        var seen = Set<String>()
        for cliType in [SwitcherCLIProfileType.codex, .claude] {
            seen.insert(cliType.rawValue)
            next[cliType.rawValue] = CLIAuthDiscovery.discoverAuthState(for: cliType)
        }
        for provider in eligibleProviders {
            guard supportsExternalOAuth(for: provider.providerID),
                  let cliType = externalCLIType(forProviderID: provider.providerID),
                  !seen.contains(cliType.rawValue) else {
                continue
            }
            seen.insert(cliType.rawValue)
            next[cliType.rawValue] = CLIAuthDiscovery.discoverAuthState(for: cliType)
        }
        dashboardExternalAuthStates = next
    }

    func refreshGatewayAdvertisementState() async {
        guard daemonManager.settingsManager.gatewayEnabled else {
            gatewayAdvertisedProviderIDs = nil
            gatewayProviderRouteIssues = [:]
            gatewayAdvertisementError = "The local gateway is off."
            return
        }

        guard let url = gatewayModelsURL() else {
            gatewayAdvertisedProviderIDs = nil
            gatewayProviderRouteIssues = [:]
            gatewayAdvertisementError = "The local gateway URL is invalid."
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let token = daemonManager.settingsManager.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                gatewayAdvertisedProviderIDs = nil
                gatewayProviderRouteIssues = [:]
                gatewayAdvertisementError = "The local gateway returned an invalid /v1/models response."
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                gatewayAdvertisedProviderIDs = nil
                gatewayProviderRouteIssues = [:]
                gatewayAdvertisementError = "The local gateway returned HTTP \(httpResponse.statusCode) for /v1/models."
                return
            }

            let envelope = try JSONDecoder().decode(GatewayModelsEnvelope.self, from: data)
            var advertisedIDs = Set<String>()
            var blockedRowsByProvider: [String: [GatewayModelRow]] = [:]
            for row in envelope.data {
                guard row.enabled != false else { continue }
                let rawProviderID = row.providerID ?? row.ownedBy
                guard let rawProviderID else { continue }
                let providerID = ProviderID.normalize(rawProviderID)
                guard !providerID.isEmpty else { continue }

                if row.routeEligible != false {
                    advertisedIDs.insert(providerID)
                } else {
                    blockedRowsByProvider[providerID, default: []].append(row)
                }
            }

            gatewayAdvertisedProviderIDs = advertisedIDs
            gatewayProviderRouteIssues = blockedRowsByProvider.mapValues(gatewayRouteIssue)
            gatewayAdvertisementError = nil
        } catch {
            gatewayAdvertisedProviderIDs = nil
            gatewayProviderRouteIssues = [:]
            gatewayAdvertisementError = "Could not read live /v1/models: \(error.localizedDescription)"
        }
    }

    func gatewayRouteIssue(for rows: [GatewayModelRow]) -> String {
        let states = rows.compactMap { $0.quotaState?.lowercased() }
        if states.contains("missing_credential") {
            return "The live gateway sees this provider, but the daemon cannot read a routing credential. Use current login or paste a credential, then Save."
        }
        if states.contains("exhausted") {
            return "The live gateway sees this provider, but every matching account is out of quota."
        }
        if states.contains("cooling_down") {
            return "The live gateway sees this provider, but its account is cooling down after a failed or rate-limited request."
        }
        if states.contains("auth_failed") {
            return "The live gateway sees this provider, but the saved credential was rejected. Reconnect or replace it."
        }
        if states.contains("disabled") {
            return "The live gateway sees this provider, but the provider or account is switched off."
        }
        if let error = rows
            .compactMap({ $0.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return error
        }
        return "The live gateway sees this provider, but no advertised model is route-ready yet."
    }

    func gatewayRouteIssueLabel(for issue: String) -> String {
        let lower = issue.lowercased()
        if lower.contains("cannot read") || lower.contains("credential") {
            return "Credential missing"
        }
        if lower.contains("quota") {
            return "Quota exhausted"
        }
        if lower.contains("cooling") {
            return "Cooling down"
        }
        if lower.contains("switched off") {
            return "Proxy off"
        }
        return "Not routable"
    }

    func gatewayModelsURL() -> URL? {
        let settings = daemonManager.settingsManager
        let configuredHost = settings.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        switch configuredHost {
        case "", "0.0.0.0", "::":
            host = "127.0.0.1"
        default:
            host = configuredHost
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = settings.gatewayPort > 0 ? settings.gatewayPort : 8317
        components.path = "/v1/models"
        return components.url
    }

    @ViewBuilder
    var wizardHeader: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    if currentStep == .dashboard {
                        onDismiss()
                    } else if currentStep == .provider {
                        navigateToStep(.dashboard)
                    } else {
                        navigateBack()
                    }
                } label: {
                    Image(systemName: currentStep == .dashboard ? "xmark" : "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(DesignSystem.Colors.surfaceElevated)
                        )
                        .overlay(
                            Circle().stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                if currentStep != .dashboard {
                    progressTrack
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.md)

            VStack(alignment: .leading, spacing: 2) {
                Text(stepTitle)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(stepDescription)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
        }
        .padding(.bottom, DesignSystem.Spacing.md)
    }

    var addFlowSteps: [ProviderPlanWizardStep] {
        [.provider, .auth, .credential, .strategy, .confirm]
    }

    @ViewBuilder
    var progressTrack: some View {
        HStack(spacing: 0) {
            ForEach(Array(addFlowSteps.enumerated()), id: \.element.rawValue) { index, step in
                progressNode(step)
                if index < addFlowSteps.count - 1 {
                    progressConnector(after: step)
                }
            }
        }
    }

}

// MARK: - Provider Configuration Helpers

extension OpenBurnBarDaemonProviderConfiguration {
    var routeReadyCredentialSlots: [CredentialSlot] {
        credentialSlots.filter { slot in
            slot.canAttemptRoute()
        }
    }

    var hasRoutingCapability: Bool {
        let providerID = self.providerID.lowercased()
        switch providerID {
        case "minimax", "zai", "z-ai", "ollama", "mlx", "mimo", "xiaomi", "xiaomimimo",
             "openai", "xai", "deepseek", "mistral", "alibaba", "qwen", "meta":
            return true
        default:
            // Honor catalog routing capability when available.
            if let catalog = BurnBarCatalogLoader.bundledCatalog.provider(id: self.providerID) {
                return catalog.capabilities.contains(.routing)
            }
            return false
        }
    }
}

extension BurnBarProviderAuthMethod {
    var usesExternalLogin: Bool {
        kind == .browserLogin || kind == .localRuntime
    }

    var isClaudeOAuthBearer: Bool {
        id == "anthropic-claude-oauth"
    }

    var isOpenCodeAuthJSON: Bool {
        id == "opencode-auth-json"
    }
}

enum ProviderPlanWizardError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

extension CLIAuthInfo {
    var isWizardConnected: Bool {
        switch authState {
        case .authenticated, .apiKeyPresent:
            return true
        case .notAuthenticated, .notInstalled:
            return false
        }
    }

    var wizardStateColor: Color {
        switch authState {
        case .authenticated, .apiKeyPresent:
            return DesignSystem.Colors.success
        case .notAuthenticated:
            return DesignSystem.Colors.warning
        case .notInstalled:
            return DesignSystem.Colors.error
        }
    }
}
