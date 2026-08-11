import Foundation
import os
import OpenBurnBarCore

struct DaemonCredentialSlotAccountProjection {
    static func accounts(
        from configurations: [OpenBurnBarDaemonProviderConfiguration],
        now: Date = Date()
    ) -> [ProviderAccountDoc] {
        configurations.flatMap { configuration -> [ProviderAccountDoc] in
            let providerID = QuotaCapableProviderMap.canonicalProviderID(
                forDaemonProviderID: configuration.providerID
            )
            let defaultSlotID = configuration.preferredCredentialSlotID
                ?? configuration.credentialSlots.first(where: \.isEnabled)?.slotID

            return configuration.credentialSlots.enumerated().map { index, slot in
                let isEnabled = configuration.isEnabled && slot.isEnabled
                let effectiveSlotStatus = slot.effectiveRoutingStatus(now: now)
                let status = accountStatus(for: effectiveSlotStatus, isEnabled: isEnabled)
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

    /// Account id for a slot addressed by its *daemon-config* provider id.
    /// Callers holding the configured string (which may be an alias) must go
    /// through here so they address the same row `accounts(from:)` writes.
    static func accountID(daemonProviderID: String, slotID: String) -> String {
        accountID(
            providerID: QuotaCapableProviderMap.canonicalProviderID(forDaemonProviderID: daemonProviderID),
            slotID: slotID
        )
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

final class ProviderQuotaAutomaticRefreshLifecycle: Sendable {
    private struct State {
        var refreshTask: Task<Void, Never>?
        var apiKeyObserver: NSObjectProtocol?
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    func replaceRefreshTask(_ task: Task<Void, Never>) {
        let previous = state.withLockUnchecked { state -> Task<Void, Never>? in
            let previous = state.refreshTask
            state.refreshTask = task
            return previous
        }
        previous?.cancel()
    }

    func cancelRefreshTask() {
        let task = state.withLockUnchecked { state -> Task<Void, Never>? in
            let task = state.refreshTask
            state.refreshTask = nil
            return task
        }
        task?.cancel()
    }

    var hasAPIKeyObserver: Bool {
        state.withLockUnchecked { $0.apiKeyObserver != nil }
    }

    func setAPIKeyObserver(_ observer: NSObjectProtocol) {
        state.withLockUnchecked {
            $0.apiKeyObserver = observer
        }
    }

    func removeAPIKeyObserver() {
        let observer = state.withLockUnchecked { state -> NSObjectProtocol? in
            let observer = state.apiKeyObserver
            state.apiKeyObserver = nil
            return observer
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func cancelAll() {
        cancelRefreshTask()
        removeAPIKeyObserver()
    }
}

/// An immutable, `Sendable` value snapshot of the user's quota-plan selection,
/// captured on the main actor and handed to adapters that run off it. This is
/// the Swift-6-safe replacement for synchronously reaching into `@MainActor`
/// `SettingsManager` from inside `QuotaRefreshActor`.
struct ProviderQuotaPlanSnapshot: Sendable {
    let miniMaxMode: MiniMaxQuotaMode
    let factoryPlan: FactoryQuotaPlanTier
    let xaiPlan: XAIQuotaPlanTier
    let mimoTokenPlanRegion: ProviderEndpointRegion
    let mimoTokenPlanTier: MimoTokenPlanTier?
    let mimoTokenPlanBillingCycle: MimoTokenPlanBillingCycle
}

// Quota adapters need the user's plan selection while running off the main
// actor. The readers are immutable `@MainActor` closures (which are `Sendable`)
// installed during `ProviderQuotaService` initialization; their backing
// `SettingsManager` is main-actor isolated, so the values are snapshotted with
// `resolvedSnapshot()` on the main actor before any off-actor quota work.
final class ProviderQuotaPlanReaders: Sendable {
    let miniMaxModeProvider: @MainActor () -> MiniMaxQuotaMode
    let factoryPlanProvider: @MainActor () -> FactoryQuotaPlanTier
    let xaiPlanProvider: @MainActor () -> XAIQuotaPlanTier
    let mimoTokenPlanRegionProvider: @MainActor () -> ProviderEndpointRegion
    let mimoTokenPlanTierProvider: @MainActor () -> MimoTokenPlanTier?
    let mimoTokenPlanBillingCycleProvider: @MainActor () -> MimoTokenPlanBillingCycle

    init(
        miniMaxModeProvider: @escaping @MainActor () -> MiniMaxQuotaMode,
        factoryPlanProvider: @escaping @MainActor () -> FactoryQuotaPlanTier,
        xaiPlanProvider: @escaping @MainActor () -> XAIQuotaPlanTier,
        mimoTokenPlanRegionProvider: @escaping @MainActor () -> ProviderEndpointRegion,
        mimoTokenPlanTierProvider: @escaping @MainActor () -> MimoTokenPlanTier?,
        mimoTokenPlanBillingCycleProvider: @escaping @MainActor () -> MimoTokenPlanBillingCycle
    ) {
        self.miniMaxModeProvider = miniMaxModeProvider
        self.factoryPlanProvider = factoryPlanProvider
        self.xaiPlanProvider = xaiPlanProvider
        self.mimoTokenPlanRegionProvider = mimoTokenPlanRegionProvider
        self.mimoTokenPlanTierProvider = mimoTokenPlanTierProvider
        self.mimoTokenPlanBillingCycleProvider = mimoTokenPlanBillingCycleProvider
    }

    /// Snapshots every plan reader into a `Sendable` value on the main actor.
    @MainActor
    func resolvedSnapshot() -> ProviderQuotaPlanSnapshot {
        ProviderQuotaPlanSnapshot(
            miniMaxMode: miniMaxModeProvider(),
            factoryPlan: factoryPlanProvider(),
            xaiPlan: xaiPlanProvider(),
            mimoTokenPlanRegion: mimoTokenPlanRegionProvider(),
            mimoTokenPlanTier: mimoTokenPlanTierProvider(),
            mimoTokenPlanBillingCycle: mimoTokenPlanBillingCycleProvider()
        )
    }
}

// MARK: - Quota Service

@Observable
@MainActor
final class ProviderQuotaService {
    struct InFlightRefresh {
        let id: UUID
        /// Providers whose normal refresh contract this task satisfies.
        /// Empty for specialized work that only needs serialization.
        let providers: Set<AgentProvider>
        let task: Task<Void, Never>
    }

    static let shared = ProviderQuotaService()
    internal static let maxPersistedRoutingEvents = 500  // pure-move: was private

    static var supportedProviders: [AgentProvider] {
        AgentProvider.quotaSignalProviders
    }

    internal let keyStore: ProviderAPIKeyStore  // pure-move: was private
    internal let providerRuntimeKeyStore: KeychainStore  // pure-move: was private
    internal let appPaths: OpenBurnBarAppPaths  // pure-move: was private
    internal let fileManager: FileManager  // pure-move: was private
    internal let session: URLSession  // pure-move: was private
    internal let environment: [String: String]  // pure-move: was private
    internal let homeDirectoryURL: URL  // pure-move: was private
    internal let miniMaxModeProvider: @MainActor () -> MiniMaxQuotaMode  // pure-move: was private
    internal let factoryPlanProvider: @MainActor () -> FactoryQuotaPlanTier  // pure-move: was private
    internal let xaiPlanProvider: @MainActor () -> XAIQuotaPlanTier  // pure-move: was private
    internal let mimoTokenPlanRegionProvider: @MainActor () -> ProviderEndpointRegion  // pure-move: was private
    internal let mimoTokenPlanTierProvider: @MainActor () -> MimoTokenPlanTier?  // pure-move: was private
    internal let mimoTokenPlanBillingCycleProvider: @MainActor () -> MimoTokenPlanBillingCycle  // pure-move: was private
    internal let claudeCredentialsReader: any ClaudeCredentialsReading  // pure-move: was private
    internal let refreshProviders: [AgentProvider]  // pure-move: was private
    private let planReaders: ProviderQuotaPlanReaders

    internal let snapshotStore: ProviderQuotaSnapshotStore  // pure-move: was private
    internal let bridgeManager: ClaudeQuotaBridgeManager  // pure-move: was private

    internal let quotaRefreshActor: QuotaRefreshActor  // pure-move: was private

    internal(set) var snapshotsByProvider: [AgentProvider: ProviderQuotaSnapshot] = [:]  // pure-move: was private
    internal(set) var snapshotsByAccountID: [String: ProviderQuotaSnapshot] = [:]  // pure-move: was private
    internal(set) var errors: [AgentProvider: String] = [:]  // pure-move: was private
    internal(set) var isFetching = false  // pure-move: was private
    /// Coalesces overlapping adaptive and full refreshes so a provider has at
    /// most one rate-limited probe in flight through the batch refresh path.
    var inFlightRefresh: InFlightRefresh?

    var quotaHomeDirectoryURL: URL { homeDirectoryURL }
    var activeProviders: Set<AgentProvider> = []  // pure-move: was private
    var lastFetch: Date?  // pure-move: was private
    var claudeBridgeStatus: ClaudeQuotaBridgeStatus  // pure-move: was private
    var routingStatesByProviderID: [ProviderID: ProviderRoutingStateSnapshot] = [:]  // pure-move: was private
    var routingEvents: [ProviderRoutingDecisionEvent] = []  // pure-move: was private
    var onSnapshotsPersistedForCloudSync: (@Sendable ([ProviderQuotaSnapshot]) -> Void)?
    /// Codex rollout-scan cache. A `Locked` box (not a plain stored property) so
    /// the `@Sendable` write-back handed to off-actor adapters can update it
    /// without capturing `self` (main-actor isolated).
    internal let codexRolloutScanCacheBox = Locked<CodexRolloutScanCache>(.empty)  // pure-move: was private
    internal var connectedQuotaProviderIDsCache: (fetchedAt: Date, ids: Set<ProviderID>)?  // pure-move: was private
    internal var suppressRoutingEventPersistence = false  // pure-move: was private
    internal var routingEventsDirty = false  // pure-move: was private
    internal let automaticRefreshLifecycle = ProviderQuotaAutomaticRefreshLifecycle()  // pure-move: was private
    internal var claudeStatuslineWatcher: ClaudeStatuslineWatcher?  // pure-move: was private

    init(
        settingsManager: SettingsManager = .shared,
        keyStore: ProviderAPIKeyStore = .shared,
        providerRuntimeKeyStore: KeychainStore = KeychainStore(
            service: OpenBurnBarCore.OpenBurnBarIdentity.cursorConnectorKeychainService,
            legacyServices: OpenBurnBarCore.OpenBurnBarIdentity.legacyCursorConnectorKeychainServices
        ),
        appPaths: OpenBurnBarCore.OpenBurnBarAppPaths = .live(),
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        miniMaxModeProvider: (@MainActor () -> MiniMaxQuotaMode)? = nil,
        factoryPlanProvider: (@MainActor () -> FactoryQuotaPlanTier)? = nil,
        xaiPlanProvider: (@MainActor () -> XAIQuotaPlanTier)? = nil,
        mimoTokenPlanRegionProvider: (@MainActor () -> ProviderEndpointRegion)? = nil,
        mimoTokenPlanTierProvider: (@MainActor () -> MimoTokenPlanTier?)? = nil,
        mimoTokenPlanBillingCycleProvider: (@MainActor () -> MimoTokenPlanBillingCycle)? = nil,
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
        let resolvedMiniMaxModeProvider = miniMaxModeProvider ?? { settingsManager.miniMaxQuotaMode }
        let resolvedFactoryPlanProvider = factoryPlanProvider ?? { settingsManager.factoryQuotaPlanTier }
        let resolvedXAIPlanProvider = xaiPlanProvider ?? { settingsManager.xaiQuotaPlanTier }
        let resolvedMimoTokenPlanRegionProvider = mimoTokenPlanRegionProvider ?? { settingsManager.mimoTokenPlanRegion }
        let resolvedMimoTokenPlanTierProvider = mimoTokenPlanTierProvider ?? { settingsManager.mimoTokenPlanTier }
        let resolvedMimoTokenPlanBillingCycleProvider = mimoTokenPlanBillingCycleProvider ?? { settingsManager.mimoTokenPlanBillingCycle }
        self.miniMaxModeProvider = resolvedMiniMaxModeProvider
        self.factoryPlanProvider = resolvedFactoryPlanProvider
        self.xaiPlanProvider = resolvedXAIPlanProvider
        self.mimoTokenPlanRegionProvider = resolvedMimoTokenPlanRegionProvider
        self.mimoTokenPlanTierProvider = resolvedMimoTokenPlanTierProvider
        self.mimoTokenPlanBillingCycleProvider = resolvedMimoTokenPlanBillingCycleProvider
        self.planReaders = ProviderQuotaPlanReaders(
            miniMaxModeProvider: resolvedMiniMaxModeProvider,
            factoryPlanProvider: resolvedFactoryPlanProvider,
            xaiPlanProvider: resolvedXAIPlanProvider,
            mimoTokenPlanRegionProvider: resolvedMimoTokenPlanRegionProvider,
            mimoTokenPlanTierProvider: resolvedMimoTokenPlanTierProvider,
            mimoTokenPlanBillingCycleProvider: resolvedMimoTokenPlanBillingCycleProvider
        )
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
            planReaders: planReaders,
            claudeCredentialsReader: claudeCredentialsReader,
            refreshProviders: self.refreshProviders
        )

        self.claudeBridgeStatus = bridgeManager.refreshClaudeBridgeStatus()

        // Best-effort, but observable: if the support directory can't be
        // prepared the persisted snapshot/routing-event loads below will all
        // miss and every later persist silently no-ops. Swallowing the error
        // here used to make that whole-cache loss invisible. Keep init
        // resilient (the service must still construct) but record the fault.
        do {
            _ = try OpenBurnBarCore.OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths)
        } catch {
            AppLogger.dataStore.error(
                "ProviderQuotaService: prepareSupportDirectory failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
        }
        loadPersistedSnapshots()
        loadPersistedRoutingEvents()
        loadPersistedCodexRolloutScanCache()
        refreshClaudeBridgeStatus()
    }

    deinit {
        automaticRefreshLifecycle.cancelAll()
        // Note: claudeStatuslineWatcher cancels its dispatch source in
        // its own deinit when the strong reference drops here.
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

    internal func accountSnapshot(providerID: ProviderID?, accountID: String) -> ProviderQuotaSnapshot? {  // pure-move: was private
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

    /// Canonical id first, then every daemon alias for the provider.
    ///
    /// Snapshots are written under the canonical id, but records persisted
    /// before that was true — and records synced from a device still on the old
    /// build — carry the alias, so reads stay alias-tolerant. This used to be a
    /// hand-written `kimi`/`claude-code` special case that never learned about
    /// xAI's aliases; it now reads the same table the projection canonicalizes
    /// against, so the two cannot drift.
    private static func snapshotProviderIDs(for provider: AgentProvider) -> [ProviderID] {
        let aliases = QuotaCapableProviderMap.daemonProviderIDs(for: provider)
            .subtracting([provider.providerID])
            .sorted { $0.rawValue < $1.rawValue }
        return [provider.providerID] + aliases
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

    func visiblePopoverProviders(dataStore: DataStore) async -> [AgentProvider] {
        let connectedProviderIDs = await connectedQuotaProviderIDs(dataStore: dataStore)
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

    func hasConnectedQuotaAccount(for provider: AgentProvider, dataStore: DataStore) async -> Bool {
        await connectedQuotaProviderIDs(dataStore: dataStore).contains(provider.providerID)
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

    internal func persistSnapshots() {  // pure-move: was private
        let persistedSnapshots = deduplicatedPersistedSnapshots()
        snapshotStore.persistSnapshots(snapshotsByProvider, accountSnapshots: snapshotsByAccountID)
        recordSnapshotWrittenTelemetry(for: persistedSnapshots)
        let syncableSnapshots = snapshotsForCloudSync.filter { $0.sourceKind != .unavailable }
        if !syncableSnapshots.isEmpty {
            onSnapshotsPersistedForCloudSync?(syncableSnapshots)
        }
    }

    private func deduplicatedPersistedSnapshots() -> [ProviderQuotaSnapshot] {
        Array(
            (Array(snapshotsByProvider.values) + Array(snapshotsByAccountID.values))
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

    private func recordSnapshotWrittenTelemetry(for snapshots: [ProviderQuotaSnapshot], now: Date = Date()) {
        for snapshot in snapshots {
            TelemetryService.shared.record(
                feature: .providerQuotaRefresh,
                outcome: .success,
                attributes: [
                    "quota_event": "snapshot_written",
                    "provider": snapshot.providerID.rawValue,
                    "source": snapshot.source,
                    "snapshot_age_bucket": Self.snapshotAgeBucket(fetchedAt: snapshot.fetchedAt, now: now)
                ]
            )
        }
    }

    static func snapshotAgeBucket(fetchedAt: Date, now: Date = Date()) -> String {
        let ageSeconds = now.timeIntervalSince(fetchedAt)
        if ageSeconds < 0 { return "future" }
        if ageSeconds < 60 { return "<1m" }
        if ageSeconds < 5 * 60 { return "1-5m" }
        if ageSeconds < 20 * 60 { return "5-20m" }
        if ageSeconds < 60 * 60 { return "20-60m" }
        if ageSeconds < 4 * 60 * 60 { return "1-4h" }
        return ">=4h"
    }

    private func loadPersistedRoutingEvents() {
        switch snapshotStore.loadPersistedRoutingEvents(limit: Self.maxPersistedRoutingEvents) {
        case .loaded(let events):
            routingEvents = events
            persistRoutingEvents()
        case .failed(let target, let message):
            AppLogger.dataStore.silentFailure(
                "ProviderQuotaService: \(target.label) load failed",
                error: ProviderQuotaPersistenceLoadError(message: message)
            )
        case .missing:
            break
        }
    }

    internal func persistRoutingEvents() {  // pure-move: was private
        snapshotStore.persistRoutingEvents(routingEvents, limit: Self.maxPersistedRoutingEvents)
    }

    private func loadPersistedCodexRolloutScanCache() {
        switch snapshotStore.loadPersistedCodexRolloutScanCache() {
        case .loaded(let cache):
            codexRolloutScanCacheBox.write(cache)
        case .failed(let target, let message):
            AppLogger.dataStore.silentFailure(
                "ProviderQuotaService: \(target.label) load failed",
                error: ProviderQuotaPersistenceLoadError(message: message)
            )
        case .missing:
            break
        }
    }

}

private struct ProviderQuotaPersistenceLoadError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
