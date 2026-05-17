import Foundation
import GRDB
import OpenBurnBarCore

struct DaemonCredentialSlotAccountProjection {
    static func accounts(
        from configurations: [OpenBurnBarDaemonProviderConfiguration],
        now: Date = Date()
    ) -> [ProviderAccountDoc] {
        configurations.flatMap { configuration -> [ProviderAccountDoc] in
            let providerID = ProviderID(rawValue: configuration.providerID)
            let defaultSlotID = configuration.preferredCredentialSlotID
                ?? configuration.credentialSlots.first(where: \.isEnabled)?.slotID

            return configuration.credentialSlots.enumerated().map { index, slot in
                let isEnabled = configuration.isEnabled && slot.isEnabled
                let status = accountStatus(for: slot.status, isEnabled: isEnabled)
                let hasRefreshState = slot.lastQuotaRemainingPercent != nil
                    || slot.lastQuotaResetsAt != nil
                    || slot.lastStatusMessage != nil
                    || slot.lastSelectedAt != nil
                let updatedAt = slot.updatedAt

                return ProviderAccountDoc(
                    id: accountID(providerID: providerID, slotID: slot.slotID),
                    providerID: providerID,
                    label: slot.label,
                    identityHint: "Daemon credential slot",
                    status: status,
                    credentialKind: .bearer,
                    storageScope: .deviceKeychain,
                    redactedLabel: "Stored in Mac Keychain",
                    isDefault: slot.slotID == defaultSlotID,
                    sortKey: slot.slotID == defaultSlotID ? 0 : Double(index + 1),
                    lastValidatedAt: slot.status == .ready ? updatedAt : nil,
                    lastRefreshAt: hasRefreshState ? updatedAt : nil,
                    lastErrorCode: status == .connected ? nil : slot.status.rawValue,
                    schemaVersion: 1,
                    createdAt: updatedAt,
                    updatedAt: now
                )
            }
        }
    }

    static func accountID(providerID: ProviderID, slotID: String) -> String {
        "\(providerID.rawValue)-\(ProviderID.normalize(slotID))"
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
}

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
    private let claudeCredentialsReader: any ClaudeCredentialsReading
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
    var onSnapshotsPersistedForCloudSync: (([ProviderQuotaSnapshot]) -> Void)?
    private var codexRolloutScanCache: CodexRolloutScanCache = .empty
    private var connectedQuotaProviderIDsCache: (fetchedAt: Date, ids: Set<ProviderID>)?
    private var suppressRoutingEventPersistence = false
    private var routingEventsDirty = false
    private nonisolated(unsafe) var automaticRefreshTask: Task<Void, Never>?
    private nonisolated(unsafe) var apiKeyChangeObserver: NSObjectProtocol?

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
        claudeCredentialsReader: any ClaudeCredentialsReading = NoClaudeCredentialsReader(),
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
        self.claudeCredentialsReader = claudeCredentialsReader
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
            claudeCredentialsReader: claudeCredentialsReader,
            refreshProviders: self.refreshProviders
        )

        self.claudeBridgeStatus = bridgeManager.refreshClaudeBridgeStatus()

        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths)
        loadPersistedSnapshots()
        loadPersistedRoutingEvents()
        loadPersistedCodexRolloutScanCache()
        refreshClaudeBridgeStatus()
    }

    deinit {
        automaticRefreshTask?.cancel()
        if let apiKeyChangeObserver {
            NotificationCenter.default.removeObserver(apiKeyChangeObserver)
        }
    }

    func snapshot(for provider: AgentProvider) -> ProviderQuotaSnapshot? {
        snapshotsByProvider[provider]
    }

    func snapshot(accountID: String) -> ProviderQuotaSnapshot? {
        accountSnapshot(providerID: nil, accountID: accountID)
    }

    func snapshot(providerID: ProviderID, accountID: String) -> ProviderQuotaSnapshot? {
        accountSnapshot(providerID: providerID, accountID: accountID)
    }

    private func accountSnapshot(providerID: ProviderID?, accountID: String) -> ProviderQuotaSnapshot? {
        guard let normalizedAccountID = Self.normalizedSnapshotIdentifier(accountID) else {
            return nil
        }
        return snapshotsByAccountID.values
            .filter { snapshot in
                guard Self.normalizedSnapshotIdentifier(snapshot.accountID) == normalizedAccountID else {
                    return false
                }
                guard let providerID else { return true }
                return snapshot.providerID == providerID
            }
            .max { $0.fetchedAt < $1.fetchedAt }
    }

    func snapshots(for provider: AgentProvider) -> [ProviderQuotaSnapshot] {
        let providerIDs = Self.snapshotProviderIDs(for: provider)
        var snapshotsByIdentity: [String: ProviderQuotaSnapshot] = [:]

        for snapshot in providerIDs.flatMap({ snapshots(for: $0) }) {
            let key = [
                snapshot.providerID.rawValue,
                snapshot.accountID?.lowercased() ?? "",
                snapshot.sourceId.lowercased()
            ].joined(separator: ":")
            guard let incumbent = snapshotsByIdentity[key] else {
                snapshotsByIdentity[key] = snapshot
                continue
            }
            if snapshot.fetchedAt > incumbent.fetchedAt {
                snapshotsByIdentity[key] = snapshot
            }
        }

        return snapshotsByIdentity.values.sorted { lhs, rhs in
            let lhsLabel = lhs.accountLabel ?? lhs.accountID ?? lhs.sourceId
            let rhsLabel = rhs.accountLabel ?? rhs.accountID ?? rhs.sourceId
            let labelOrder = lhsLabel.localizedCaseInsensitiveCompare(rhsLabel)
            if labelOrder != .orderedSame {
                return labelOrder == .orderedAscending
            }
            return lhs.fetchedAt > rhs.fetchedAt
        }
    }

    func snapshots(for providerID: ProviderID) -> [ProviderQuotaSnapshot] {
        // The on-disk `snapshotsByAccountID` is keyed by `providerID:accountID`
        // or `providerID:sourceId`, which means a single logical account can
        // produce two distinct keys (one record has `accountID` set, another
        // has only `sourceId`). Without a render-time dedupe, the dashboard
        // panel renders the same account twice with subtly different bucket
        // values. Group by the most-specific identifier we can extract and
        // keep the freshest record per group.
        let candidates = snapshotsByAccountID.values.filter {
            $0.providerID == providerID && Self.isAccountLevelSnapshot($0)
        }

        func accountKey(_ snap: ProviderQuotaSnapshot) -> String {
            if let id = snap.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !id.isEmpty {
                return id.lowercased()
            }
            if let label = snap.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty {
                return label.lowercased()
            }
            return snap.sourceId.lowercased()
        }

        var freshest: [String: ProviderQuotaSnapshot] = [:]
        for snap in candidates {
            let key = accountKey(snap)
            guard let incumbent = freshest[key] else {
                freshest[key] = snap
                continue
            }
            // Freshness tombstones must win over old bucketed snapshots;
            // otherwise a credential delete/error marker can be masked by
            // stale quota numbers that still happen to have buckets.
            let candidateIsStale = snap.isExplicitlyStale
            let incumbentIsStale = incumbent.isExplicitlyStale
            if candidateIsStale != incumbentIsStale {
                if snap.fetchedAt >= incumbent.fetchedAt {
                    freshest[key] = snap
                }
                continue
            }
            // Records with real buckets beat empty placeholders only when
            // neither side is an explicit stale marker.
            let candidateHasBuckets = !snap.displayableQuotaBuckets.isEmpty
            let incumbentHasBuckets = !incumbent.displayableQuotaBuckets.isEmpty
            if candidateHasBuckets != incumbentHasBuckets {
                if candidateHasBuckets { freshest[key] = snap }
                continue
            }
            if snap.fetchedAt > incumbent.fetchedAt {
                freshest[key] = snap
            }
        }

        return freshest.values.sorted { lhs, rhs in
            let lhsLabel = lhs.accountLabel ?? lhs.accountID ?? lhs.sourceId
            let rhsLabel = rhs.accountLabel ?? rhs.accountID ?? rhs.sourceId
            let labelOrder = lhsLabel.localizedCaseInsensitiveCompare(rhsLabel)
            if labelOrder != .orderedSame {
                return labelOrder == .orderedAscending
            }
            return lhs.fetchedAt > rhs.fetchedAt
        }
    }

    private static func snapshotProviderIDs(for provider: AgentProvider) -> [ProviderID] {
        switch provider {
        case .kimi:
            return [provider.providerID, ProviderID(rawValue: "moonshot")]
        case .claudeCode:
            return [provider.providerID, ProviderID(rawValue: "anthropic")]
        default:
            return [provider.providerID]
        }
    }

    var accountsByProvider: [ProviderID: [ProviderQuotaSnapshot]] {
        // Re-route through `snapshots(for:)` so this helper inherits the same
        // account-level dedup — without it, popover summaries showed duplicate
        // accounts whenever the storage map happened to keep both an
        // accountID-keyed and a sourceId-keyed record for the same login.
        let allProviders = Set(snapshotsByAccountID.values.map { $0.providerID })
        var result: [ProviderID: [ProviderQuotaSnapshot]] = [:]
        for providerID in allProviders {
            result[providerID] = snapshots(for: providerID)
        }
        return result
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
                allowProviderFallback: request.allowProviderFallback,
                routerMode: request.routerMode,
                selectedProviderID: request.selectedProviderID ?? providerID,
                selectedAccountID: request.selectedAccountID,
                taskCategory: request.taskCategory,
                benchmarkStatus: request.benchmarkStatus
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
                routerMode: decision.routerMode,
                selectedProviderID: scopedRequest.selectedProviderID,
                selectedAccountID: scopedRequest.selectedAccountID,
                selectedModelID: scopedRequest.modelID,
                activeAccount: decision.selected,
                nextFallback: decision.nextFallback,
                exhaustedOrCoolingDownAccounts: decision.exhaustedOrCoolingDown,
                lastSwitchReason: decision.lastSwitchReason,
                latestExplanation: decision.event.explanation,
                rejectedAlternatives: decision.rejectedAlternatives,
                benchmarkStatus: decision.benchmarkStatus,
                recentEvents: Array(
                    routingEvents
                        .filter { $0.selectedProviderID == providerID || $0.nextFallbackProviderID == providerID }
                        .suffix(100)
                )
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
            refreshRoutingState(dataStore: dataStore, request: currentRoutingRequest())
            return
        }
        await refreshAll(dataStore: dataStore)
    }

    func startAutomaticRefresh(
        dataStore: DataStore,
        initialDelay: Duration = .seconds(10),
        interval: Duration = .seconds(15 * 60)
    ) {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task(priority: .utility) { [weak self, weak dataStore] in
            guard let self, let dataStore else { return }
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                await self.refreshIfNeeded(dataStore: dataStore, maxAge: 15 * 60)
                try? await Task.sleep(for: interval)
            }
        }

        guard apiKeyChangeObserver == nil else { return }
        apiKeyChangeObserver = NotificationCenter.default.addObserver(
            forName: ProviderAPIKeyStore.didChangeNotification,
            object: keyStore,
            queue: nil
        ) { [weak self, weak dataStore] notification in
            guard let providerKey = notification.userInfo?[ProviderAPIKeyStore.providerUserInfoKey] as? String else {
                return
            }
            Task { @MainActor [weak self, weak dataStore] in
                guard let self, let dataStore else { return }
                if let provider = self.quotaProvider(forKeyIdentifier: providerKey) {
                    await self.refresh(provider: provider, dataStore: dataStore)
                } else {
                    await self.refreshIfNeeded(dataStore: dataStore, maxAge: 0)
                }
            }
        }
    }

    func stopAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        if let apiKeyChangeObserver {
            NotificationCenter.default.removeObserver(apiKeyChangeObserver)
            self.apiKeyChangeObserver = nil
        }
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
        replaceAccountSnapshots(
            batch.accountSnapshots,
            pruningManagedAccountSnapshotsFor: Set(refreshProviders)
        )
        persistDaemonCredentialSlotAccounts(dataStore: dataStore)
        refreshRoutingState(dataStore: dataStore, request: currentRoutingRequest())

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
            replaceAccountSnapshots(
                accountSnapshots,
                pruningManagedAccountSnapshotsFor: [provider]
            )
            persistDaemonCredentialSlotAccounts(dataStore: dataStore, providers: [provider])
            refreshRoutingState(dataStore: dataStore, request: currentRoutingRequest(provider: provider))
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

    private func currentRoutingRequest(provider: AgentProvider? = nil) -> ProviderRoutingRequest {
        let mode = OpenBurnBarDaemonManager.shared.routerMode
        return ProviderRoutingRequest(
            preferredProviderIDs: provider.map { [$0.providerID] } ?? [],
            routerMode: mode,
            selectedProviderID: provider?.providerID,
            taskCategory: .coding,
            benchmarkStatus: mode == .intelligentModelRouter
                ? ProviderModelBenchmarkStatus(
                    source: .cachedFixture,
                    freshness: .unavailable,
                    message: "No local benchmark snapshot is available yet.",
                    attribution: "OpenBurnBar model landscape adapters"
                )
                : nil
        )
    }

    func fetchSnapshot(
        for provider: AgentProvider,
        apiKeyOverride: String
    ) async throws -> ProviderQuotaSnapshot {
        switch provider {
        case .minimax, .zai, .deepSeek, .copilot, .ollama, .kimi:
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
                statusMessage: "Per-plan quota refresh is available for MiniMax, Z.ai, DeepSeek, Kimi, Copilot, and Ollama Cloud.",
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
        let snapshot = accountSnapshot(providerID: account.providerID, accountID: account.id)
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

        if snapshot?.isTooOldForQuotaDecisions() == true {
            return .pressure
        }

        guard let bucket = snapshot?.primaryDisplayableBucket else {
            return account.status == .error ? .authFailed : .unknown
        }

        if let remaining = bucket.remainingPercent {
            if remaining <= 0 { return bucket.isEstimated ? .pressure : .exhausted }
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
            claudeCredentialsReader: claudeCredentialsReader,
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
        case .openCode:
            return "opencode"
        case .deepSeek:
            return "deepseek"
        case .kimi:
            return "moonshot"
        case .claudeCode:
            return "anthropic"
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
        case .openCode:
            identifiers.append(contentsOf: ["opencode", "open_code", "opencode_auth_json"])
        case .deepSeek:
            identifiers.append(contentsOf: ["deepseek", "deep_seek"])
        default:
            break
        }

        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    private func quotaProvider(forKeyIdentifier key: String) -> AgentProvider? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        for provider in Self.supportedProviders where quotaKeyIdentifiers(for: provider).contains(normalized) {
            return provider
        }
        switch normalized {
        case "cursor_cookie":
            return .cursor
        case "factory_cookie_header", "factory_cookie":
            return .factory
        case "ollama_cookie_header", "ollama_cookie":
            return .ollama
        case "kimi_auth_token":
            return .kimi
        default:
            return nil
        }
    }

    private func handleCodexRolloutScanCacheUpdate(_ cache: CodexRolloutScanCache, didChange: Bool) {
        codexRolloutScanCache = cache
        if didChange {
            persistCodexRolloutScanCache()
        }
    }

    private func upsertSnapshot(_ snapshot: ProviderQuotaSnapshot, for provider: AgentProvider? = nil) {
        if Self.normalizedSnapshotIdentifier(snapshot.accountID) == nil {
            snapshotsByProvider[provider ?? snapshot.provider] = snapshot
        }
        snapshotsByAccountID[ProviderQuotaSnapshotStore.accountSnapshotKey(snapshot)] = snapshot
    }

    private func upsertAccountSnapshots(_ snapshots: [String: ProviderQuotaSnapshot]) {
        for (key, snapshot) in snapshots {
            snapshotsByAccountID[key] = snapshot
        }
    }

    private func replaceAccountSnapshots(
        _ snapshots: [String: ProviderQuotaSnapshot],
        pruningManagedAccountSnapshotsFor providers: Set<AgentProvider>
    ) {
        let providerIDs = Set(providers.map(\.providerID))
        let replacementKeys = Set(snapshots.keys)

        snapshotsByAccountID = snapshotsByAccountID.filter { key, snapshot in
            guard providerIDs.contains(snapshot.providerID),
                  Self.isManagedAccountSnapshot(snapshot) else {
                return true
            }
            return replacementKeys.contains(key)
        }

        upsertAccountSnapshots(snapshots)
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
        let allowedProviderIDs = Set(
            OpenBurnBarDaemonManager.shared.providerConfigurations.compactMap { configuration -> ProviderID? in
                guard let provider = Self.quotaCapableProvider(forProviderID: configuration.providerID),
                      providers?.contains(provider) ?? true else {
                    return nil
                }
                return ProviderID(rawValue: configuration.providerID)
            }
        )
        guard !allowedProviderIDs.isEmpty else { return [] }

        return DaemonCredentialSlotAccountProjection
            .accounts(from: OpenBurnBarDaemonManager.shared.providerConfigurations)
            .filter { allowedProviderIDs.contains($0.providerID) }
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
        case "anthropic", "claude", "claude-code":
            return .claudeCode
        case "opencode", "open-code":
            return .openCode
        case "deepseek", "deep-seek":
            return .deepSeek
        case "moonshot", "kimi":
            return .kimi
        default:
            return nil
        }
    }

    private static func normalizedSnapshotIdentifier(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized.lowercased()
    }

    private static func isAccountLevelSnapshot(_ snapshot: ProviderQuotaSnapshot) -> Bool {
        if normalizedSnapshotIdentifier(snapshot.accountID) != nil {
            return true
        }
        guard let sourceID = normalizedSnapshotIdentifier(snapshot.sourceId) else {
            return false
        }
        return sourceID != "default"
    }

    private static func isManagedAccountSnapshot(_ snapshot: ProviderQuotaSnapshot) -> Bool {
        guard isAccountLevelSnapshot(snapshot),
              let sourceID = normalizedSnapshotIdentifier(snapshot.sourceId) else {
            return false
        }
        return sourceID.hasPrefix("switcher-cli:")
            || sourceID.hasPrefix("switcher:")
            || sourceID.hasPrefix("provider:")
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
        let syncableSnapshots = snapshotsForCloudSync.filter { $0.source != .unavailable }
        if !syncableSnapshots.isEmpty {
            onSnapshotsPersistedForCloudSync?(syncableSnapshots)
        }
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

// MARK: - Cumulative across accounts
//
// When the user has multiple accounts on the same provider, collapse the
// per-account snapshots into one synthetic snapshot whose buckets are
// summed by `(key, windowKind)`. Pure derivation — the cumulative
// snapshot is never persisted, never synced to Firestore. It exists only
// to feed the UI when `SettingsManager.cumulativeAcrossAccounts` is on.

extension ProviderQuotaService {

    /// Returns the cumulative snapshot for `provider`, or nil when there
    /// is nothing meaningful to merge (zero or one account, no displayable
    /// signal, or every input bucket dropped during normalization).
    func cumulativeSnapshot(for provider: AgentProvider, now: Date = Date()) -> ProviderQuotaSnapshot? {
        Self.cumulativeSnapshot(
            provider: provider,
            from: snapshots(for: provider),
            now: now
        )
    }

    /// Pure-logic variant: given an explicit input list of per-account
    /// snapshots, produce the cumulative snapshot. Used by tests and by
    /// the convenience instance method above. Returns nil when there is
    /// nothing meaningful to merge.
    static func cumulativeSnapshot(
        provider: AgentProvider,
        from inputs: [ProviderQuotaSnapshot],
        now: Date = Date()
    ) -> ProviderQuotaSnapshot? {
        // `.localOnly`-scope sources are device-only scrape caches (Codex
        // rollout, etc.) — adding them across accounts double-counts the
        // same machine's usage. Drop them from the sum.
        let candidateSnapshots = inputs.filter { $0.accountStorageScope != .localOnly }
        guard candidateSnapshots.count > 1 else { return nil }

        // Prefer fresh snapshots. If every account is stale, fall back to
        // the freshest single snapshot and tag the result so the UI can
        // show "stale merged" instead of silently dropping data.
        let freshSnapshots = candidateSnapshots.filter { !$0.isStale(relativeTo: now) }
        let mergedInputs: [ProviderQuotaSnapshot]
        let staleFallback: Bool
        if freshSnapshots.isEmpty {
            staleFallback = true
            if let freshest = candidateSnapshots.max(by: { $0.fetchedAt < $1.fetchedAt }) {
                mergedInputs = [freshest]
            } else {
                return nil
            }
        } else {
            staleFallback = false
            mergedInputs = freshSnapshots
        }

        let mergedBuckets = mergeBuckets(across: mergedInputs)
        guard !mergedBuckets.isEmpty else { return nil }

        let fetchedAt = mergedInputs.map(\.fetchedAt).min() ?? now
        let confidence: ProviderQuotaConfidence = staleFallback
            ? .unavailable
            : worstConfidence(among: mergedInputs)
        let managementURL = mergedInputs.compactMap(\.managementURL).first
        let accountCount = candidateSnapshots.count
        let statusMessage: String = {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            let relative = formatter.localizedString(for: fetchedAt, relativeTo: now)
            if staleFallback {
                return "Stale data merged across \(accountCount) accounts — last fetch \(relative)"
            }
            return "Combined \(accountCount) accounts — oldest fetch \(relative)"
        }()

        return ProviderQuotaSnapshot(
            provider: provider,
            providerID: provider.providerID,
            accountID: nil,
            accountLabel: "All accounts (\(accountCount))",
            accountStorageScope: .cloudRefreshable,
            fetchedAt: fetchedAt,
            source: dominantSourceKind(among: mergedInputs),
            sourceId: "cumulative:\(provider.providerID.rawValue)",
            confidence: confidence,
            managementURL: managementURL,
            statusMessage: statusMessage,
            buckets: mergedBuckets,
            schemaVersion: mergedInputs.first?.schemaVersion ?? 2
        )
    }

    /// Single switchboard every UI surface reads from. When the
    /// `cumulativeAcrossAccounts` toggle is on and the provider has more
    /// than one account, returns the cumulative snapshot wrapped in a
    /// one-element array. Otherwise returns the per-account list from
    /// `snapshots(for:)`.
    func displaySnapshots(
        for provider: AgentProvider,
        cumulative: Bool,
        now: Date = Date()
    ) -> [ProviderQuotaSnapshot] {
        guard cumulative else { return snapshots(for: provider) }
        if let combined = cumulativeSnapshot(for: provider, now: now) {
            return [combined]
        }
        return snapshots(for: provider)
    }

    /// Single-snapshot variant for surfaces that show one summary per
    /// provider (popover strip, menu bar). When `cumulative` is on AND
    /// the provider has multiple accounts, returns the merged snapshot.
    /// Otherwise falls back to `snapshot(for:)` (the existing
    /// provider-level snapshot).
    func primaryDisplaySnapshot(
        for provider: AgentProvider,
        cumulative: Bool,
        now: Date = Date()
    ) -> ProviderQuotaSnapshot? {
        if cumulative, let combined = cumulativeSnapshot(for: provider, now: now) {
            return combined
        }
        return snapshot(for: provider)
    }

    // MARK: - Helpers

    /// Group inputs' displayable buckets by `(key, windowKind)` and sum
    /// them into one bucket per group. Buckets without a unit match are
    /// dropped (mismatched units would produce nonsense sums).
    static func mergeBuckets(across snapshots: [ProviderQuotaSnapshot]) -> [ProviderQuotaBucket] {
        struct GroupKey: Hashable {
            let key: String
            let windowKind: ProviderQuotaWindowKind
        }
        var groups: [GroupKey: [ProviderQuotaBucket]] = [:]
        for snapshot in snapshots {
            for bucket in snapshot.displayableQuotaBuckets {
                let groupKey = GroupKey(key: bucket.key, windowKind: bucket.windowKind)
                groups[groupKey, default: []].append(bucket)
            }
        }

        return groups.compactMap { (groupKey, members) -> ProviderQuotaBucket? in
            guard let first = members.first else { return nil }
            // Require unit consistency. If one input is requests and another
            // is tokens for the same key (shouldn't happen, but) we cannot
            // sum them.
            let units = Set(members.map(\.unit))
            guard units.count == 1, let unit = units.first else { return nil }

            let usedValues = members.compactMap(\.usedValue)
            let limitValues = members.compactMap(\.limitValue)
            let remainingValues = members.compactMap(\.remainingValue)

            let usedSum = usedValues.isEmpty ? nil : usedValues.reduce(0, +)
            let limitSum = limitValues.isEmpty ? nil : limitValues.reduce(0, +)
            let remainingSum: Double? = {
                if !remainingValues.isEmpty { return remainingValues.reduce(0, +) }
                if let usedSum, let limitSum {
                    return max(limitSum - usedSum, 0)
                }
                return nil
            }()

            // Always recompute usedPercent from the summed totals — never
            // average raw percents (a 90%-used small bucket and a 10%-used
            // large bucket are NOT 50% combined).
            let usedPercent: Double? = {
                if let usedSum, let limitSum, limitSum > 0 {
                    return min(max((usedSum / limitSum) * 100, 0), 100)
                }
                let rawPercents = members.compactMap(\.usedPercent)
                guard !rawPercents.isEmpty else { return nil }
                return rawPercents.reduce(0, +) / Double(rawPercents.count)
            }()

            // Earliest reset = soonest moment new capacity arrives.
            let resetsAt = members.compactMap(\.resetsAt).min()

            return ProviderQuotaBucket(
                key: groupKey.key,
                label: first.label,
                windowKind: groupKey.windowKind,
                usedValue: usedSum,
                limitValue: limitSum,
                remainingValue: remainingSum,
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                unit: unit,
                isEstimated: members.contains(where: \.isEstimated)
            )
        }
        // Stable order: hourly window first, then daily, weekly, etc.
        .sorted { lhs, rhs in
            Self.windowKindOrder(lhs.windowKind) < Self.windowKindOrder(rhs.windowKind)
        }
    }

    private static func windowKindOrder(_ kind: ProviderQuotaWindowKind) -> Int {
        switch kind {
        case .rollingHours: return 0
        case .daily:        return 1
        case .weekly:       return 2
        case .rollingDays:  return 3
        case .monthly:      return 4
        case .lifetime:     return 5
        case .custom:       return 6
        }
    }

    private static func worstConfidence(among snapshots: [ProviderQuotaSnapshot]) -> ProviderQuotaConfidence {
        // `unavailable` worst, then `estimated`, then `exact`.
        if snapshots.contains(where: { $0.confidence == .unavailable }) { return .unavailable }
        if snapshots.contains(where: { $0.confidence == .estimated }) { return .estimated }
        return .exact
    }

    /// Pick a representative source kind for the merged envelope. Prefers
    /// `officialAPI` > `localCLI` > `localSession` > `manualEstimate` >
    /// `unavailable`.
    private static func dominantSourceKind(among snapshots: [ProviderQuotaSnapshot]) -> ProviderQuotaSourceKind {
        let order: [ProviderQuotaSourceKind] = [
            .officialAPI, .localCLI, .localSession, .manualEstimate, .unavailable
        ]
        for kind in order where snapshots.contains(where: { $0.source == kind }) {
            return kind
        }
        return .unavailable
    }
}
