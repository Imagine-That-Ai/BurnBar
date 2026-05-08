import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - Quota Service

@Observable
@MainActor
final class ProviderQuotaService {
    static let shared = ProviderQuotaService()

    static var supportedProviders: [AgentProvider] {
        AgentProvider.quotaSignalProviders
    }

    private let keyStore: ProviderAPIKeyStore
    private let providerRuntimeKeyStore: KeychainStore
    private let appPaths: OpenBurnBarAppPaths
    private let fileManager: FileManager
    private let session: URLSession
    private let environment: [String: String]
    private let homeDirectoryURL: URL
    private let miniMaxModeProvider: () -> MiniMaxQuotaMode
    private let factoryPlanProvider: () -> FactoryQuotaPlanTier
    private let refreshProviders: [AgentProvider]

    private let snapshotStore: ProviderQuotaSnapshotStore
    private let bridgeManager: ClaudeQuotaBridgeManager

    private let quotaRefreshActor: QuotaRefreshActor

    private(set) var snapshotsByProvider: [AgentProvider: ProviderQuotaSnapshot] = [:]
    private(set) var snapshotsByAccountID: [String: ProviderQuotaSnapshot] = [:]
    private(set) var errors: [AgentProvider: String] = [:]
    private(set) var isFetching = false
    private(set) var activeProviders: Set<AgentProvider> = []
    private(set) var lastFetch: Date?
    private(set) var claudeBridgeStatus: ClaudeQuotaBridgeStatus
    private(set) var routingStatesByProviderID: [ProviderID: ProviderRoutingStateSnapshot] = [:]
    private(set) var routingEvents: [ProviderRoutingDecisionEvent] = []
    private var codexRolloutScanCache: CodexRolloutScanCache = .empty
    private var connectedQuotaProviderIDsCache: (fetchedAt: Date, ids: Set<ProviderID>)?
    private var suppressRoutingEventPersistence = false
    private var routingEventsDirty = false

    init(
        settingsManager: SettingsManager = .shared,
        keyStore: ProviderAPIKeyStore = .shared,
        providerRuntimeKeyStore: KeychainStore = KeychainStore(
            service: OpenBurnBarIdentity.cursorConnectorKeychainService,
            legacyServices: OpenBurnBarIdentity.legacyCursorConnectorKeychainServices
        ),
        appPaths: OpenBurnBarAppPaths = .live(),
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        miniMaxModeProvider: (() -> MiniMaxQuotaMode)? = nil,
        factoryPlanProvider: (() -> FactoryQuotaPlanTier)? = nil,
        refreshProviders: [AgentProvider] = ProviderQuotaService.supportedProviders
    ) {
        self.keyStore = keyStore
        self.providerRuntimeKeyStore = providerRuntimeKeyStore
        self.appPaths = appPaths
        self.fileManager = fileManager
        self.session = session
        self.environment = environment
        self.homeDirectoryURL = homeDirectoryURL
        self.miniMaxModeProvider = miniMaxModeProvider ?? { settingsManager.miniMaxQuotaMode }
        self.factoryPlanProvider = factoryPlanProvider ?? { settingsManager.factoryQuotaPlanTier }
        self.refreshProviders = refreshProviders.filter(\.isQuotaSignalProvider)

        let store = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        self.snapshotStore = store
        self.bridgeManager = ClaudeQuotaBridgeManager(
            appPaths: appPaths,
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager,
            snapshotStore: store
        )

        self.quotaRefreshActor = QuotaRefreshActor(
            settingsManager: settingsManager,
            keyStore: keyStore,
            providerRuntimeKeyStore: providerRuntimeKeyStore,
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            miniMaxModeProvider: self.miniMaxModeProvider,
            factoryPlanProvider: self.factoryPlanProvider,
            refreshProviders: self.refreshProviders
        )

        self.claudeBridgeStatus = bridgeManager.refreshClaudeBridgeStatus()

        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths)
        loadPersistedSnapshots()
        loadPersistedRoutingEvents()
        loadPersistedCodexRolloutScanCache()
        refreshClaudeBridgeStatus()
    }

    func snapshot(for provider: AgentProvider) -> ProviderQuotaSnapshot? {
        snapshotsByProvider[provider]
    }

    func snapshot(accountID: String) -> ProviderQuotaSnapshot? {
        snapshotsByAccountID.values.first { $0.accountID == accountID }
    }

    func snapshots(for provider: AgentProvider) -> [ProviderQuotaSnapshot] {
        snapshots(for: provider.providerID)
    }

    func snapshots(for providerID: ProviderID) -> [ProviderQuotaSnapshot] {
        snapshotsByAccountID.values
            .filter { $0.providerID == providerID }
            .sorted { lhs, rhs in
                let lhsLabel = lhs.accountLabel ?? lhs.accountID ?? lhs.sourceId
                let rhsLabel = rhs.accountLabel ?? rhs.accountID ?? rhs.sourceId
                let labelOrder = lhsLabel.localizedCaseInsensitiveCompare(rhsLabel)
                if labelOrder != .orderedSame {
                    return labelOrder == .orderedAscending
                }
                return lhs.fetchedAt > rhs.fetchedAt
            }
    }

    var accountsByProvider: [ProviderID: [ProviderQuotaSnapshot]] {
        Dictionary(grouping: snapshotsByAccountID.values, by: \.providerID)
            .mapValues { snapshots in
                snapshots.sorted { lhs, rhs in
                    let lhsLabel = lhs.accountLabel ?? lhs.accountID ?? lhs.sourceId
                    let rhsLabel = rhs.accountLabel ?? rhs.accountID ?? rhs.sourceId
                    return lhsLabel.localizedCaseInsensitiveCompare(rhsLabel) == .orderedAscending
                }
            }
    }

    var snapshotsForCloudSync: [ProviderQuotaSnapshot] {
        Array(
            (Array(snapshotsByProvider.values) + Array(snapshotsByAccountID.values))
                .compactMap { $0.filteringToDisplayableQuotaSignal() }
                .reduce(into: [String: ProviderQuotaSnapshot]()) { result, snapshot in
                    let key = ProviderQuotaSnapshotStore.accountSnapshotKey(snapshot)
                    guard let existing = result[key] else {
                        result[key] = snapshot
                        return
                    }
                    if snapshot.fetchedAt >= existing.fetchedAt {
                        result[key] = snapshot
                    }
                }
                .values
        )
    }

    func visiblePopoverProviders(dataStore: DataStore) -> [AgentProvider] {
        let connectedProviderIDs = connectedQuotaProviderIDs(dataStore: dataStore)
        let providersWithAccountSnapshots = Set(snapshotsByAccountID.values.compactMap { snapshot -> AgentProvider? in
            guard snapshot.hasDisplayableQuotaSignal else { return nil }
            return AgentProvider.fromProviderID(snapshot.providerID)
        })

        return refreshProviders.filter { provider in
            if connectedProviderIDs.contains(provider.providerID) { return true }
            if snapshotsByProvider[provider]?.hasDisplayableQuotaSignal == true { return true }
            return providersWithAccountSnapshots.contains(provider)
        }
    }

    func hasConnectedQuotaAccount(for provider: AgentProvider, dataStore: DataStore) -> Bool {
        connectedQuotaProviderIDs(dataStore: dataStore).contains(provider.providerID)
    }

    func routingState(for providerID: ProviderID) -> ProviderRoutingStateSnapshot? {
        routingStatesByProviderID[providerID]
    }

    @discardableResult
    func refreshRoutingState(
        dataStore: DataStore,
        request: ProviderRoutingRequest = ProviderRoutingRequest()
    ) -> [ProviderID: ProviderRoutingStateSnapshot] {
        let accounts = (try? dataStore.providerAccountStore.fetchAll()) ?? []
        let providerIDs = Set(
            accounts.map(\.providerID)
                + snapshotsByProvider.values.filter(\.hasDisplayableQuotaSignal).map(\.providerID)
                + OpenBurnBarDaemonManager.shared.providerConfigurations.map { ProviderID(rawValue: $0.providerID) }
                + request.preferredProviderIDs
        )

        var updatedStates: [ProviderID: ProviderRoutingStateSnapshot] = [:]
        let wasSuppressingPersistence = suppressRoutingEventPersistence
        suppressRoutingEventPersistence = true
        defer {
            suppressRoutingEventPersistence = wasSuppressingPersistence
            if !wasSuppressingPersistence, routingEventsDirty {
                routingEventsDirty = false
                persistRoutingEvents()
            }
        }

        for providerID in providerIDs {
            let scopedRequest = ProviderRoutingRequest(
                modelID: request.modelID,
                preferredProviderIDs: request.preferredProviderIDs.isEmpty ? [providerID] : request.preferredProviderIDs,
                allowProviderFallback: request.allowProviderFallback
            )
            let candidates = routingCandidates(
                providerID: providerID,
                accounts: accounts.filter { $0.providerID == providerID }
            )
            guard !candidates.isEmpty else { continue }

            let decision = ProviderRoutingPolicy.decide(
                request: scopedRequest,
                candidates: candidates
            )
            appendRoutingEvent(decision.event)
            updatedStates[providerID] = ProviderRoutingStateSnapshot(
                activeAccount: decision.selected,
                nextFallback: decision.nextFallback,
                exhaustedOrCoolingDownAccounts: decision.exhaustedOrCoolingDown,
                lastSwitchReason: decision.lastSwitchReason,
                recentEvents: routingEvents.filter { $0.selectedProviderID == providerID || $0.nextFallbackProviderID == providerID }
            )
        }

        routingStatesByProviderID = updatedStates
        return updatedStates
    }

    func isRefreshing(_ provider: AgentProvider) -> Bool {
        activeProviders.contains(provider)
    }

    func refreshIfNeeded(dataStore: DataStore, maxAge: TimeInterval = 5 * 60) async {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < maxAge {
            refreshRoutingState(dataStore: dataStore)
            return
        }
        await refreshAll(dataStore: dataStore)
    }

    func refreshAll(dataStore: DataStore) async {
        guard !isFetching else { return }
        isFetching = true
        defer {
            isFetching = false
            activeProviders.removeAll()
        }
        errors = [:]
        refreshClaudeBridgeStatus()

        activeProviders = Set(refreshProviders)
        let batch = await quotaRefreshActor.fetchAllSnapshots(dataStoreActor: dataStore.actor)
        for (provider, snapshot) in batch.providerSnapshots {
            upsertSnapshot(snapshot, for: provider)
        }
        upsertAccountSnapshots(batch.accountSnapshots)
        persistDaemonCredentialSlotAccounts(dataStore: dataStore)
        refreshRoutingState(dataStore: dataStore)

        lastFetch = Date()
        persistSnapshots()
    }

    func refresh(provider: AgentProvider, dataStore: DataStore) async {
        guard Self.supportedProviders.contains(provider) else { return }
        activeProviders.insert(provider)
        defer { activeProviders.remove(provider) }
        let start = Date()

        do {
            let context = makeContext(dataStore: dataStore)
            let snapshot = try await quotaRefreshActor.fetchSnapshot(for: provider, context: context)
            upsertSnapshot(snapshot, for: provider)
            let accountSnapshots = await quotaRefreshActor.fetchAccountSnapshots(for: provider, dataStoreActor: dataStore.actor)
            upsertAccountSnapshots(accountSnapshots)
            persistDaemonCredentialSlotAccounts(dataStore: dataStore, providers: [provider])
            refreshRoutingState(dataStore: dataStore, request: ProviderRoutingRequest(preferredProviderIDs: [provider.providerID]))
            errors.removeValue(forKey: provider)
            lastFetch = Date()
            persistSnapshots()
            if provider == .claudeCode {
                refreshClaudeBridgeStatus()
            }
            TelemetryService.shared.record(feature: .providerQuotaRefresh, outcome: .success, durationMs: Int(Date().timeIntervalSince(start) * 1000))
            OpenBurnBarMetrics.counter(name: "quota_refresh_success", labels: ["provider": provider.rawValue])
        } catch {
            TelemetryService.shared.record(feature: .providerQuotaRefresh, outcome: .failure, durationMs: Int(Date().timeIntervalSince(start) * 1000))
            OpenBurnBarMetrics.counter(name: "quota_refresh_failure", labels: ["provider": provider.rawValue])
            errors[provider] = error.localizedDescription
            if snapshotsByProvider[provider] == nil {
                upsertSnapshot(ProviderQuotaSnapshot(
                    provider: provider,
                    fetchedAt: Date(),
                    source: .unavailable,
                    confidence: .unavailable,
                    managementURL: nil,
                    statusMessage: error.localizedDescription,
                    buckets: []
                ), for: provider)
            }
        }
    }

    func fetchSnapshot(
        for provider: AgentProvider,
        apiKeyOverride: String
    ) async throws -> ProviderQuotaSnapshot {
        switch provider {
        case .minimax, .zai, .copilot, .ollama:
            let scratchDataStore = try makeScratchDataStore()
            let context = makeContext(dataStore: scratchDataStore, apiKeyOverrides: [provider: apiKeyOverride])
            return try await quotaRefreshActor.fetchSnapshot(for: provider, context: context)
        default:
            return ProviderQuotaSnapshot(
                provider: provider,
                fetchedAt: Date(),
                source: .unavailable,
                confidence: .unavailable,
                managementURL: nil,
                statusMessage: "Per-plan quota refresh is available for MiniMax, Z.ai, Copilot, and Ollama Cloud.",
                buckets: []
            )
        }
    }

    func installClaudeQuotaBridge() throws {
        try bridgeManager.installClaudeQuotaBridge()
        refreshClaudeBridgeStatus()
    }

    func removeClaudeQuotaBridge() throws {
        try bridgeManager.removeClaudeQuotaBridge()
        refreshClaudeBridgeStatus()
    }

    func refreshClaudeBridgeStatus() {
        claudeBridgeStatus = bridgeManager.refreshClaudeBridgeStatus()
    }

    // MARK: - Internal

    private func appendRoutingEvent(_ event: ProviderRoutingDecisionEvent) {
        if routingEvents.last?.selectedProviderID == event.selectedProviderID,
           routingEvents.last?.selectedAccountID == event.selectedAccountID,
           routingEvents.last?.reason == event.reason {
            return
        }
        routingEvents.append(event)
        routingEventsDirty = true
        if routingEvents.count > 100 {
            routingEvents.removeFirst(routingEvents.count - 100)
        }
        if !suppressRoutingEventPersistence {
            routingEventsDirty = false
            persistRoutingEvents()
        }
    }

    private func connectedQuotaProviderIDs(dataStore: DataStore) -> Set<ProviderID> {
        if let cache = connectedQuotaProviderIDsCache,
           Date().timeIntervalSince(cache.fetchedAt) < 15 {
            return cache.ids
        }
        let accounts = (try? dataStore.providerAccountStore.fetchAll()) ?? []
        let ids: Set<ProviderID> = Set(accounts.compactMap { account in
            guard Self.isConnectedQuotaAccount(account) else { return nil }
            guard let provider = AgentProvider.fromProviderID(account.providerID),
                  Self.supportedProviders.contains(provider) else {
                return nil
            }
            return account.providerID
        })
        connectedQuotaProviderIDsCache = (Date(), ids)
        return ids
    }

    private static func isConnectedQuotaAccount(_ account: ProviderAccountDoc) -> Bool {
        switch account.status {
        case .connected, .stale, .error:
            return true
        case .disconnected, .disabled, .deleted:
            return false
        }
    }

    private func routingCandidates(
        providerID: ProviderID,
        accounts: [ProviderAccountDoc]
    ) -> [ProviderRoutingCandidate] {
        let accountCandidates = accounts
            .filter { $0.status != .deleted }
            .map { account in
                routingCandidate(for: account)
            }

        if !accountCandidates.isEmpty {
            return accountCandidates
        }

        if let agentProvider = AgentProvider.fromProviderID(providerID),
           snapshotsByProvider[agentProvider]?.hasDisplayableQuotaSignal == true || ProviderQuotaService.supportedProviders.contains(agentProvider) {
            return [
                .defaultLegacyAccount(
                    providerID: providerID,
                    providerLabel: agentProvider.displayName,
                    credentialHandle: "legacy-default",
                    localCredentialAvailable: true
                )
            ]
        }

        return []
    }

    private func routingCandidate(for account: ProviderAccountDoc) -> ProviderRoutingCandidate {
        let slot = daemonSlot(forAccount: account)
        let snapshot = snapshotsByAccountID[account.id]
        let quotaState = routingQuotaState(account: account, snapshot: snapshot, slot: slot)
        let cooldownUntil = slot?.cooldownUntil

        return ProviderRoutingCandidate(
            providerID: account.providerID,
            accountID: account.id,
            accountLabel: account.label,
            credentialHandle: account.redactedLabel,
            storageScope: account.storageScope,
            modelCompatibility: .unknown,
            quotaState: quotaState,
            cooldownUntil: cooldownUntil,
            priority: Int(account.sortKey),
            routingEnabled: account.status != .disabled && account.status != .deleted,
            lastUsedAt: slot?.lastSelectedAt,
            lastFailureCode: account.lastErrorCode ?? slot?.lastStatusMessage,
            localCredentialAvailable: account.storageScope == .deviceKeychain || account.storageScope == .localOnly
        )
    }

    private func daemonSlot(forAccount account: ProviderAccountDoc) -> OpenBurnBarDaemonProviderConfiguration.CredentialSlot? {
        guard let configuration = OpenBurnBarDaemonManager.shared.providerConfigurations.first(where: { configuration in
            ProviderID(rawValue: configuration.providerID) == account.providerID
        }) else {
            return nil
        }
        for slot in configuration.credentialSlots {
            let accountID = "\(account.providerID.rawValue)-\(ProviderID.normalize(slot.slotID))"
            if accountID == account.id {
                return slot
            }
        }
        return nil
    }

    private func routingQuotaState(
        account: ProviderAccountDoc,
        snapshot: ProviderQuotaSnapshot?,
        slot: OpenBurnBarDaemonProviderConfiguration.CredentialSlot?
    ) -> ProviderRoutingQuotaState {
        if account.status == .deleted { return .deleted }
        if account.status == .disabled { return .disabled }
        if account.status == .error {
            if let code = account.lastErrorCode?.lowercased(),
               code.contains("auth") || code.contains("401") || code.contains("403") || code.contains("secret") {
                return .authFailed
            }
        }

        if let slot {
            switch slot.status {
            case .ready:
                break
            case .coolingDown:
                return .coolingDown
            case .exhausted:
                return .exhausted
            case .disabled:
                return .disabled
            case .missingSecret:
                return .authFailed
            }
        }

        guard let bucket = snapshot?.primaryDisplayableBucket else {
            return account.status == .error ? .authFailed : .unknown
        }

        if let remaining = bucket.remainingPercent {
            if remaining <= 0 { return .exhausted }
            if remaining <= 20 { return .pressure }
            return .healthy
        }

        return snapshot?.confidence == .unavailable ? .unknown : .healthy
    }

    private func makeScratchDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(
            databaseQueue: queue,
            runMigrations: true,
            refreshOnInit: false
        )
    }

    private func makeContext(
        dataStore: DataStore,
        apiKeyOverrides: [AgentProvider: String] = [:]
    ) -> ProviderQuotaAdapterContext {
        var resolvedKeys: [String: String?] = [:]
        for provider in Self.supportedProviders {
            let resolvedValue: String?
            if let override = apiKeyOverrides[provider] {
                resolvedValue = override
            } else {
                resolvedValue = providerQuotaAPIKey(for: provider)
            }

            for identifier in quotaKeyIdentifiers(for: provider) {
                resolvedKeys[identifier] = resolvedValue
            }
        }
        resolvedKeys["cursor_cookie"] = keyStore.apiKey(for: "cursor_cookie")
        for identifier in ["factory_cookie_header", "factory_cookie", "ollama_cookie_header", "ollama_cookie", "kimi_auth_token"] {
            resolvedKeys[identifier] = keyStore.apiKey(for: identifier)
        }

        return ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            dataStoreActor: dataStore.actor,
            snapshotStore: snapshotStore,
            bridgeManager: bridgeManager,
            miniMaxModeProvider: miniMaxModeProvider,
            factoryPlanProvider: factoryPlanProvider,
            claudeBridgeStatus: claudeBridgeStatus,
            codexRolloutScanCache: codexRolloutScanCache,
            updateCodexRolloutScanCache: { [weak self] cache, didChange in
                self?.handleCodexRolloutScanCacheUpdate(cache, didChange: didChange)
            },
            refreshClaudeBridgeStatus: { [weak self] in
                self?.refreshClaudeBridgeStatus()
                return self?.claudeBridgeStatus ?? ClaudeQuotaBridgeStatus(
                    state: .notInstalled,
                    wrapperPath: "",
                    detailText: "",
                    lastPayloadAt: nil
                )
            },
            resolvedAPIKeys: resolvedKeys
        )
    }

    private func providerQuotaAPIKey(for provider: AgentProvider) -> String? {
        for identifier in quotaKeyIdentifiers(for: provider) {
            if let value = quotaNonEmpty(keyStore.apiKey(for: identifier)) {
                return value
            }
        }
        return daemonPlanAPIKey(for: provider)
    }

    private func daemonPlanAPIKey(for provider: AgentProvider) -> String? {
        guard let providerID = daemonProviderID(for: provider) else { return nil }
        guard let configuration = OpenBurnBarDaemonManager.shared.providerConfigurations.first(
            where: { $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame }
        ) else {
            return nil
        }

        let preferredSlot = configuration.preferredCredentialSlotID.flatMap { preferredID in
            configuration.credentialSlots.first(where: { $0.slotID == preferredID })
        }

        var orderedSlots: [OpenBurnBarDaemonProviderConfiguration.CredentialSlot] = []
        if let preferredSlot {
            orderedSlots.append(preferredSlot)
        }
        orderedSlots.append(
            contentsOf: configuration.credentialSlots.filter { slot in
                slot.slotID != preferredSlot?.slotID && slot.isEnabled
            }
        )
        orderedSlots.append(
            contentsOf: configuration.credentialSlots.filter { slot in
                slot.slotID != preferredSlot?.slotID && !slot.isEnabled
            }
        )

        for slot in orderedSlots {
            let account = "provider.\(providerID).slot.\(slot.slotID).apiKey"
            if let key = try? providerRuntimeKeyStore.string(for: account, allowUserInteraction: false),
               let normalized = quotaNonEmpty(key) {
                return normalized
            }
        }
        return nil
    }

    private func daemonProviderID(for provider: AgentProvider) -> String? {
        switch provider {
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

    private func quotaKeyIdentifiers(for provider: AgentProvider) -> [String] {
        let rawValue = provider.rawValue
        let lowercased = rawValue.lowercased()
        let collapsed = lowercased.replacingOccurrences(of: " ", with: "")
        let snakeCased = lowercased.replacingOccurrences(of: " ", with: "_")

        var identifiers = [rawValue, lowercased, collapsed, snakeCased]

        switch provider {
        case .minimax:
            identifiers.append("minimax")
        case .zai:
            identifiers.append(contentsOf: ["zai", "z_ai"])
        case .kimi:
            identifiers.append("kimi_auth_token")
        default:
            break
        }

        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    private func handleCodexRolloutScanCacheUpdate(_ cache: CodexRolloutScanCache, didChange: Bool) {
        codexRolloutScanCache = cache
        if didChange {
            persistCodexRolloutScanCache()
        }
    }

    private func upsertSnapshot(_ snapshot: ProviderQuotaSnapshot, for provider: AgentProvider? = nil) {
        snapshotsByProvider[provider ?? snapshot.provider] = snapshot
        snapshotsByAccountID[ProviderQuotaSnapshotStore.accountSnapshotKey(snapshot)] = snapshot
    }

    private func upsertAccountSnapshots(_ snapshots: [String: ProviderQuotaSnapshot]) {
        for (key, snapshot) in snapshots {
            snapshotsByAccountID[key] = snapshot
        }
    }

    private func persistDaemonCredentialSlotAccounts(
        dataStore: DataStore,
        providers: Set<AgentProvider>? = nil
    ) {
        let accounts = daemonCredentialSlotAccounts(providers: providers)
        let scopedProviderIDs = daemonCredentialSlotProviderIDs(providers: providers)

        do {
            for account in accounts {
                try dataStore.providerAccountStore.upsert(account)
            }
            try markRemovedDaemonCredentialSlotAccountsDeleted(
                dataStore: dataStore,
                scopedProviderIDs: scopedProviderIDs,
                activeAccountIDs: Set(accounts.map(\.id))
            )
            connectedQuotaProviderIDsCache = nil
        } catch {
            AppLogger.dataStore.silentFailure("ProviderQuotaService: Failed to persist daemon provider accounts", error: error)
        }
    }

    private func daemonCredentialSlotProviderIDs(providers: Set<AgentProvider>? = nil) -> Set<ProviderID> {
        Set(
            OpenBurnBarDaemonManager.shared.providerConfigurations.compactMap { configuration in
                guard let provider = Self.quotaCapableProvider(forProviderID: configuration.providerID),
                      providers?.contains(provider) ?? true else {
                    return nil
                }
                return ProviderID(rawValue: configuration.providerID)
            }
        )
    }

    private func markRemovedDaemonCredentialSlotAccountsDeleted(
        dataStore: DataStore,
        scopedProviderIDs: Set<ProviderID>,
        activeAccountIDs: Set<String>
    ) throws {
        guard !scopedProviderIDs.isEmpty else { return }
        let now = Date()
        for providerID in scopedProviderIDs {
            let existingAccounts = try dataStore.providerAccountStore.fetchAll(providerID: providerID)
            for account in existingAccounts where account.storageScope == .deviceKeychain && !activeAccountIDs.contains(account.id) {
                try dataStore.providerAccountStore.upsert(
                    ProviderAccountDoc(
                        id: account.id,
                        providerID: account.providerID,
                        label: account.label,
                        identityHint: account.identityHint,
                        status: .deleted,
                        credentialKind: account.credentialKind,
                        storageScope: account.storageScope,
                        redactedLabel: account.redactedLabel,
                        sourceDeviceID: account.sourceDeviceID,
                        linkedSwitcherProfileID: account.linkedSwitcherProfileID,
                        isDefault: false,
                        sortKey: account.sortKey,
                        lastValidatedAt: account.lastValidatedAt,
                        lastRefreshAt: account.lastRefreshAt,
                        lastErrorCode: "credential_slot_removed",
                        schemaVersion: account.schemaVersion,
                        createdAt: account.createdAt,
                        updatedAt: now
                    )
                )
            }
        }
    }

    private func daemonCredentialSlotAccounts(providers: Set<AgentProvider>? = nil) -> [ProviderAccountDoc] {
        let now = Date()
        return OpenBurnBarDaemonManager.shared.providerConfigurations.flatMap { configuration -> [ProviderAccountDoc] in
            guard let provider = Self.quotaCapableProvider(forProviderID: configuration.providerID),
                  providers?.contains(provider) ?? true else {
                return []
            }

            let providerID = ProviderID(rawValue: configuration.providerID)
            let defaultSlotID = configuration.preferredCredentialSlotID
                ?? configuration.credentialSlots.first(where: \.isEnabled)?.slotID

            return configuration.credentialSlots.enumerated().map { index, slot in
                let accountID = "\(providerID.rawValue)-\(ProviderID.normalize(slot.slotID))"
                let isEnabled = configuration.isEnabled && slot.isEnabled
                let status = Self.accountStatus(for: slot.status, isEnabled: isEnabled)
                let hasQuotaState = slot.lastQuotaRemainingPercent != nil
                    || slot.lastQuotaResetsAt != nil
                    || slot.lastStatusMessage != nil
                let updatedAt = slot.updatedAt

                return ProviderAccountDoc(
                    id: accountID,
                    providerID: providerID,
                    label: slot.label,
                    status: status,
                    credentialKind: .bearer,
                    storageScope: .deviceKeychain,
                    redactedLabel: "Stored in Mac Keychain",
                    isDefault: slot.slotID == defaultSlotID,
                    sortKey: slot.slotID == defaultSlotID ? 0 : Double(index + 1),
                    lastRefreshAt: hasQuotaState ? updatedAt : nil,
                    lastErrorCode: status == .connected ? nil : slot.status.rawValue,
                    schemaVersion: 1,
                    createdAt: updatedAt,
                    updatedAt: now
                )
            }
        }
    }

    private static func accountStatus(
        for slotStatus: BurnBarProviderCredentialSlotStatus,
        isEnabled: Bool
    ) -> ProviderAccountStatus {
        guard isEnabled else { return .disabled }
        switch slotStatus {
        case .ready:
            return .connected
        case .coolingDown, .exhausted:
            return .stale
        case .disabled:
            return .disabled
        case .missingSecret:
            return .error
        }
    }

    private static func quotaCapableProvider(forProviderID providerID: String) -> AgentProvider? {
        switch ProviderID.normalize(providerID) {
        case "minimax":
            return .minimax
        case "zai", "z-ai":
            return .zai
        case "ollama":
            return .ollama
        case "openai":
            return .openAI
        default:
            return nil
        }
    }

    // MARK: - Persistence

    private func loadPersistedSnapshots() {
        switch snapshotStore.loadPersistedSnapshots() {
        case .loaded(let result):
            snapshotsByProvider = result.snapshots
            snapshotsByAccountID = result.accountSnapshots
            lastFetch = result.lastFetch
        case .failed(let target, let message):
            AppLogger.dataStore.silentFailure(
                "ProviderQuotaService: \(target.label) load failed",
                error: ProviderQuotaPersistenceLoadError(message: message)
            )
        case .missing:
            break
        }
    }

    private func persistSnapshots() {
        snapshotStore.persistSnapshots(snapshotsByProvider, accountSnapshots: snapshotsByAccountID)
    }

    private func loadPersistedRoutingEvents() {
        switch snapshotStore.loadPersistedRoutingEvents() {
        case .loaded(let events):
            routingEvents = events
        case .failed(let target, let message):
            AppLogger.dataStore.silentFailure(
                "ProviderQuotaService: \(target.label) load failed",
                error: ProviderQuotaPersistenceLoadError(message: message)
            )
        case .missing:
            break
        }
    }

    private func persistRoutingEvents() {
        snapshotStore.persistRoutingEvents(routingEvents)
    }

    private func loadPersistedCodexRolloutScanCache() {
        switch snapshotStore.loadPersistedCodexRolloutScanCache() {
        case .loaded(let cache):
            codexRolloutScanCache = cache
        case .failed(let target, let message):
            AppLogger.dataStore.silentFailure(
                "ProviderQuotaService: \(target.label) load failed",
                error: ProviderQuotaPersistenceLoadError(message: message)
            )
        case .missing:
            break
        }
    }

    private func persistCodexRolloutScanCache() {
        snapshotStore.persistCodexRolloutScanCache(codexRolloutScanCache)
    }
}

private struct ProviderQuotaPersistenceLoadError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
