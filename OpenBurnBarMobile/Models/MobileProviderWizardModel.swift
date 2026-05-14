import Foundation
import OpenBurnBarCore

@Observable
@MainActor
final class MobileProviderWizardModel {

    // MARK: - Step types

    enum WizardStep: Hashable {
        case pickProvider
        case authMethod
        case syncMode
        case credential
        case connecting
        case connected
        case failed

        var orderIndex: Int {
            switch self {
            case .pickProvider: return 0
            case .authMethod:   return 1
            case .syncMode:     return 2
            case .credential:   return 3
            case .connecting:   return 4
            case .connected:    return 5
            case .failed:       return 4
            }
        }
    }

    enum StepDirection { case forward, backward }

    // MARK: - Bindable inputs (view writes directly)

    var step: WizardStep
    var selectedProvider: AgentProvider?
    var searchText: String = ""
    var selectedAuthMethodID: String?
    var syncMode: QuotaConnectionMode = .cloud
    var credential: String = ""
    var accountLabel: String = ""
    var revealCredential: Bool = false
    var runnerURL: String = ""
    var runnerSecret: String = ""

    // MARK: - Model-owned outputs (view reads only)

    private(set) var stepDirection: StepDirection = .forward
    private(set) var errorMessage: String?
    var isConnecting: Bool = false
    private(set) var connectedAccount: ProviderAccountDoc?
    /// Exposed so tests can `await model.connectTask?.value` for deterministic
    /// assertions on connect outcomes.
    var connectTask: Task<Void, Never>?

    // MARK: - Injected collaborators

    let connectionStore: any ProviderConnectionProviding
    let subscriptionStore: any HostedQuotaSubscriptionProviding
    let runnerSaver: any SelfHostedRunnerSaving
    let haptics: any HapticPerforming
    let onConnected: (ProviderAccountDoc) -> Void
    let onCancel: () -> Void
    let preselectedProvider: AgentProvider?

    // MARK: - Init

    init(
        preselectedProvider: AgentProvider? = nil,
        onConnected: @escaping (ProviderAccountDoc) -> Void = { _ in },
        onCancel: @escaping () -> Void = {},
        connectionStore: any ProviderConnectionProviding = ProviderConnectionStore(),
        subscriptionStore: any HostedQuotaSubscriptionProviding = HostedQuotaSubscriptionStore(),
        runnerSaver: any SelfHostedRunnerSaving = SelfHostedQuotaRunnerStore.shared,
        haptics: any HapticPerforming = LiveHaptics()
    ) {
        self.preselectedProvider = preselectedProvider
        self.onConnected = onConnected
        self.onCancel = onCancel
        self.connectionStore = connectionStore
        self.subscriptionStore = subscriptionStore
        self.runnerSaver = runnerSaver
        self.haptics = haptics

        if let preselected = preselectedProvider {
            step = Self.firstInteractiveStep(for: preselected)
            selectedProvider = preselected
            selectedAuthMethodID = ProviderSetupGuide.registryDescriptor(for: preselected)?.primaryMethod.id
            let guide = ProviderSetupGuide.registryEnrichedGuide(for: preselected)
            syncMode = Self.defaultSyncMode(for: guide)
            accountLabel = guide.labelSuggestion
        } else {
            step = .pickProvider
            selectedProvider = nil
        }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        async let c: Void = connectionStore.load()
        async let s: Void = subscriptionStore.load()
        _ = await (c, s)
    }

    // MARK: - Step machine

    func advance(to next: WizardStep) {
        stepDirection = next.orderIndex >= step.orderIndex ? .forward : .backward
        haptics.selection()
        step = next
        // Intentionally do NOT clear errorMessage here. Callers (e.g. connect())
        // set errorMessage before advancing to .failed, and clearing it here
        // would wipe out the error before it ever displays.
    }

    func advanceFromPicker(to provider: AgentProvider) {
        haptics.selection()
        selectedProvider = provider
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: provider)
        accountLabel = guide.labelSuggestion
        syncMode = Self.defaultSyncMode(for: guide)
        credential = ""
        runnerURL = ""
        runnerSecret = ""
        errorMessage = nil
        selectedAuthMethodID = ProviderSetupGuide.registryDescriptor(for: provider)?.primaryMethod.id
        advance(to: nextStepAfterPicker(for: provider))
    }

    func advanceFromAuthMethod() {
        guard let provider = selectedProvider else { return }
        advance(to: nextStepAfterPicker(for: provider, skipping: .authMethod))
    }

    func backFromSyncMode() {
        guard let provider = selectedProvider else {
            advance(to: .pickProvider)
            return
        }
        advance(to: hasMultipleAuthMethods(for: provider) ? .authMethod : .pickProvider)
    }

    func backFromCredential() {
        guard let provider = selectedProvider else {
            advance(to: .pickProvider)
            return
        }
        if ProviderSetupGuide.registryEnrichedGuide(for: provider).supportsRemoteRunner {
            advance(to: .syncMode)
        } else if hasMultipleAuthMethods(for: provider) {
            advance(to: .authMethod)
        } else {
            advance(to: .pickProvider)
        }
    }

    func nextStepAfterPicker(
        for provider: AgentProvider,
        skipping skipped: WizardStep? = nil
    ) -> WizardStep {
        if hasMultipleAuthMethods(for: provider) && skipped != .authMethod {
            return .authMethod
        }
        if ProviderSetupGuide.registryEnrichedGuide(for: provider).supportsRemoteRunner {
            return .syncMode
        }
        return .credential
    }

    func hasMultipleAuthMethods(for provider: AgentProvider) -> Bool {
        (ProviderSetupGuide.registryDescriptor(for: provider)?.methods.count ?? 0) > 1
    }

    func isProviderAlreadyConnected(_ provider: AgentProvider) -> Bool {
        connectionStore.accounts.contains { $0.providerID == provider.providerID }
    }

    static func firstInteractiveStep(for provider: AgentProvider) -> WizardStep {
        let descriptor = ProviderSetupGuide.registryDescriptor(for: provider)
        if (descriptor?.methods.count ?? 0) > 1 { return .authMethod }
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: provider)
        if guide.supportsRemoteRunner { return .syncMode }
        return .credential
    }

    static func defaultSyncMode(for guide: ProviderSetupGuide) -> QuotaConnectionMode {
        if guide.supportsHosted { return .hosted }
        if guide.supportsSelfHosted { return .selfHosted }
        return .cloud
    }

    // MARK: - Intents

    func startConnect() {
        connectTask?.cancel()
        connectTask = Task { await connect() }
    }

    func cancelConnectingFromUser() {
        connectTask?.cancel()
        connectTask = nil
        isConnecting = false
        advance(to: .credential)
    }

    func handleCancel() {
        connectTask?.cancel()
        connectTask = nil
        onCancel()
    }

    func selectAuthMethod(_ id: String) {
        haptics.selection()
        selectedAuthMethodID = id
    }

    func selectSyncMode(_ mode: QuotaConnectionMode) {
        haptics.selection()
        syncMode = mode
    }

    func toggleRevealCredential() {
        revealCredential.toggle()
        haptics.light()
    }

    func clearSearch() {
        haptics.selection()
        searchText = ""
    }

    // MARK: - Derived state

    var canContinueFromSyncMode: Bool {
        switch syncMode {
        case .cloud, .selfHosted: return true
        case .hosted: return subscriptionStore.isActive
        }
    }

    var alreadyHasAccountForSelectedProvider: Bool {
        guard let provider = selectedProvider else { return false }
        return connectionStore.accounts.contains { $0.providerID == provider.providerID }
    }

    var canConnect: Bool {
        guard let provider = selectedProvider, !isConnecting else { return false }
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: provider)
        switch syncMode {
        case .cloud:
            return ProviderSetupGuide.registryValidation(credential: credential, for: provider) != .empty
                && trimmedCredential.count >= 8
        case .hosted:
            return guide.supportsHosted
                && subscriptionStore.isActive
                && trimmedCredential.count >= 8
        case .selfHosted:
            return SelfHostedQuotaRunnerStore.validatedRunnerURL(runnerURL) != nil
        }
    }

    var stepTitle: String {
        switch step {
        case .pickProvider: return "Pick a provider"
        case .authMethod:   return "Pick a credential method"
        case .syncMode:     return "Pick a sync mode"
        case .credential:
            if let selectedProvider {
                if alreadyHasAccountForSelectedProvider {
                    return "Add another \(selectedProvider.displayName) account"
                }
                return "Connect \(selectedProvider.displayName)"
            }
            return "Paste your credential"
        case .connecting:   return "Connecting…"
        case .connected:    return "You're connected"
        case .failed:       return "Couldn't connect"
        }
    }

    var stepCaption: String? {
        switch step {
        case .pickProvider:
            return "Tap a provider to continue."
        case .authMethod:
            guard let descriptor = selectedProvider.flatMap({ ProviderSetupGuide.registryDescriptor(for: $0) }) else {
                return nil
            }
            return "Choose how you want to authenticate \(descriptor.displayName)."
        case .syncMode:
            return "Where should we run the connection?"
        case .credential:
            return selectedProvider.map(ProviderSetupGuide.registryEnrichedGuide(for:))?.oneLineHint
        default:
            return nil
        }
    }

    var totalDots: Int {
        var total = 1
        let descriptor = selectedProvider.flatMap { ProviderSetupGuide.registryDescriptor(for: $0) }
        if (descriptor?.methods.count ?? 0) > 1 { total += 1 }
        if let provider = selectedProvider,
           ProviderSetupGuide.registryEnrichedGuide(for: provider).supportsRemoteRunner {
            total += 1
        }
        total += 1
        total += 1
        return total
    }

    var activeDot: Int {
        switch step {
        case .pickProvider: return 0
        case .authMethod:   return 1
        case .syncMode:
            return (selectedProvider.flatMap { ProviderSetupGuide.registryDescriptor(for: $0) }?.methods.count ?? 0) > 1 ? 2 : 1
        case .credential:
            return totalDots - 2
        case .connecting, .connected, .failed:
            return totalDots - 1
        }
    }

    var trimmedCredential: String {
        credential.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedLabel: String {
        accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var resolvedCredentialKind: CredentialKind {
        guard let provider = selectedProvider,
              let descriptor = ProviderSetupGuide.registryDescriptor(for: provider),
              let id = selectedAuthMethodID,
              let method = descriptor.method(id: id) else {
            return selectedProvider.map { ProviderSetupGuide.guide(for: $0).defaultKind } ?? .token
        }
        switch method.kind {
        case .apiKey: return .token
        case .bearerToken: return .bearer
        case .sessionToken: return .session
        case .cookie: return .cookie
        case .browserLogin, .localRuntime: return .session
        }
    }

    // MARK: - Search

    var isSearchEmptyOfResults: Bool {
        !searchText.isEmpty && filteredRecommended.isEmpty && filteredOthers.isEmpty
    }

    var allConnectableProviders: [AgentProvider] {
        ProviderSetupGuide.sortedProvidersForOnboarding()
    }

    var filteredRecommended: [AgentProvider] {
        let recommended = ProviderSetupGuide.recommended.filter(allConnectableProviders.contains(_:))
        guard !searchText.isEmpty else { return recommended }
        return recommended.filter(matchesSearch)
    }

    var filteredOthers: [AgentProvider] {
        let others = allConnectableProviders.filter { !ProviderSetupGuide.recommended.contains($0) }
        guard !searchText.isEmpty else { return others }
        return others.filter(matchesSearch)
    }

    func matchesSearch(_ provider: AgentProvider) -> Bool {
        let needle = searchText.lowercased()
        let descriptor = ProviderSetupGuide.registryDescriptor(for: provider)
        return provider.displayName.lowercased().contains(needle)
            || provider.persistedToken.contains(needle)
            || (descriptor?.summary.lowercased().contains(needle) ?? false)
            || (descriptor?.aliasProviderIDs.contains { $0.lowercased().contains(needle) } ?? false)
    }

    // MARK: - Connect

    private func connect() async {
        guard let provider = selectedProvider, canConnect else { return }
        haptics.medium()
        advance(to: .connecting)
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let guide = ProviderSetupGuide.registryEnrichedGuide(for: provider)
        let labelToUse = trimmedLabel.isEmpty ? guide.labelSuggestion : trimmedLabel
        let kind: CredentialKind = resolvedCredentialKind
        let created: ProviderAccountDoc?

        switch syncMode {
        case .cloud:
            created = await connectionStore.connect(
                providerID: provider.providerID,
                credential: trimmedCredential,
                kind: kind,
                label: labelToUse
            )
            if Task.isCancelled { return }
        case .hosted:
            do {
                try await subscriptionStore.refreshEntitlement()
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                errorMessage = error.localizedDescription
                advance(to: .failed)
                return
            }
            if Task.isCancelled { return }
            guard subscriptionStore.isActive else {
                errorMessage = "Hosted Quota Sync subscription is not active."
                advance(to: .failed)
                return
            }
            created = await connectionStore.connectHosted(
                providerID: provider.providerID,
                credential: trimmedCredential,
                kind: kind,
                label: labelToUse
            )
            if Task.isCancelled { return }
        case .selfHosted:
            created = await connectionStore.connectSelfHosted(
                providerID: provider.providerID,
                label: labelToUse
            )
            if Task.isCancelled {
                if let created { await connectionStore.delete(account: created) }
                return
            }
            if let created {
                do {
                    try runnerSaver.save(
                        accountID: created.id,
                        runnerURL: runnerURL,
                        accessSecret: runnerSecret.isEmpty ? nil : runnerSecret
                    )
                } catch {
                    runnerSaver.delete(accountID: created.id)
                    await connectionStore.delete(account: created)
                    errorMessage = error.localizedDescription
                    advance(to: .failed)
                    return
                }
            }
        }

        if Task.isCancelled { return }
        if let created {
            connectedAccount = created
            advance(to: .connected)
        } else {
            errorMessage = connectionStore.error ?? "We couldn't validate your credentials."
            advance(to: .failed)
        }
    }
}
