import Foundation
import GRDB
import OpenBurnBarCore

struct PostPersistenceResult {
    var apiUsages: [ProviderUsageRecord] = []
    var parserImportError: String?
    var postPersistencePhaseDuration: TimeInterval = 0
    var refreshedRecords: [TokenUsage]?
    var supplementalUsageCount: Int = 0
    var pendingProjectionJobs: Int = 0
}

actor RefreshOrchestrator {
    let dataStore: DataStore
    let settingsManager: SettingsManager
    let cloudSyncCoordinator: CloudSyncCoordinator?
    let cloudSync: CloudSyncService?
    let sessionMirror: ICloudSessionMirrorService?
    let quotaService: ProviderQuotaService
    let usageAPIService: ProviderUsageAPIService?

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        cloudSyncCoordinator: CloudSyncCoordinator? = nil,
        cloudSync: CloudSyncService? = nil,
        sessionMirror: ICloudSessionMirrorService? = nil,
        quotaService: ProviderQuotaService,
        usageAPIService: ProviderUsageAPIService? = nil
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.cloudSyncCoordinator = cloudSyncCoordinator
        self.cloudSync = cloudSync
        self.sessionMirror = sessionMirror
        self.quotaService = quotaService
        self.usageAPIService = usageAPIService
    }

    func indexConversations(_ conversations: [ConversationRecord]) async -> Int {
        guard !conversations.isEmpty else { return 0 }
        let indexingEnabled = await MainActor.run { settingsManager.conversationIndexingEnabled }
        guard indexingEnabled else { return 0 }
        do {
            let indexingReport = try await Task { @MainActor in
                try await ConversationIndexer.shared.index(conversations, in: dataStore)
            }.value
            return indexingReport.changedRecordCount
        } catch {
            AppLogger.dataStore.error("Conversation indexing failed: \(error.localizedDescription)")
            return 0
        }
    }

    func indexConversationsOffMain(_ conversations: [ConversationRecord], indexingEnabled: Bool) async -> Int {
        guard !conversations.isEmpty, indexingEnabled else { return 0 }
        do {
            let indexingReport = try await Task { @MainActor in
                try await ConversationIndexer.shared.index(conversations, in: dataStore)
            }.value
            return indexingReport.changedRecordCount
        } catch {
            AppLogger.dataStore.error("Conversation indexing failed: \(error.localizedDescription)")
            return 0
        }
    }

    func runRetentionPurgeIfNeeded() async {
        // Retention purge not configured in current SettingsManager; no-op.
    }

    func runScheduledBackfillIfNeeded(parsers: [AgentProvider: any LogParser]) async {
        let now = Date()

        for provider in parsers.keys {
            do {
                guard let window = try dataStore.actor.backfillCursorStore.nextBackfillWindow(
                    for: provider,
                    currentDate: now
                ) else {
                    continue
                }

                try dataStore.actor.backfillCursorStore.advanceCursor(
                    for: provider,
                    newUpperBound: window.upperBound,
                    earliestSourceDate: window.lowerBound
                )
            } catch {
                AppLogger.dataStore.silentFailure("Backfill cursor advance failed for \(provider.displayName)", error: error)
            }
        }
    }

    func runPostPersistencePhase(
        refreshStartedAt: Date,
        allUsages: [TokenUsage],
        indexedConversationChanges: Int,
        parsePhaseDuration: TimeInterval,
        persistencePhaseDuration: TimeInterval
    ) async -> PostPersistenceResult {
        var result = PostPersistenceResult()

        let postPersistencePhaseStartedAt = Date()

        // 1. Billing reconciliation (nonisolated, runs off main thread via its own DB work)
        let actor = dataStore.actor
        let usageStore = actor.usageStore
        let billingResult = await BillingRefreshCoordinator.reconcile(
            dataStoreActor: actor,
            usageAPIService: usageAPIService,
            allParsedUsages: allUsages,
            persistAndReload: { [dataStore] newRecords in
                let innerStore = dataStore.actor.usageStore
                return try await Task.detached(priority: .utility) {
                    try innerStore.insert(newRecords)
                    return try innerStore.fetchAllUsage()
                }.value
            },
            deleteAndReload: { [dataStore] sessionIDPrefix in
                let innerStore = dataStore.actor.usageStore
                return try await Task.detached(priority: .utility) {
                    try innerStore.deleteUsage(sessionIDPrefix: sessionIDPrefix)
                    return try innerStore.fetchAllUsage()
                }.value
            }
        )

        result.refreshedRecords = billingResult.refreshedRecords
        result.supplementalUsageCount = billingResult.supplementalUsages.count
        if let firstError = billingResult.errors.first {
            result.parserImportError = firstError
        }

        // 2. Quota refresh
        await quotaService.refreshIfNeeded(dataStore: dataStore)

        // 2a. Upload quota snapshots for iOS visibility
        if let coordinator = cloudSyncCoordinator {
            let desktopSnapshots = await MainActor.run {
                quotaService.snapshotsByProvider.values
                    .filter { $0.source != .unavailable }
            }
            await coordinator.syncQuotaSnapshots(Array(desktopSnapshots))
        }

        // 3. Cloud sync
        if let coordinator = cloudSyncCoordinator {
            await coordinator.syncUsage()
            await coordinator.syncConversationMetadata()
            await coordinator.syncSessionLogs()
            await coordinator.syncCollaborationArtifacts()
        } else if let cloudSync = cloudSync {
            await cloudSync.uploadPending()
            await cloudSync.uploadPendingConversations()
            await cloudSync.uploadPendingSessionLogs()
            await cloudSync.syncSharedArtifacts()
        }

        // 4. Session mirror sync
        await sessionMirror?.syncIfNeeded()

        // 5. Projection compaction
        var pendingProjectionJobs = (try? dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])) ?? 0
        if pendingProjectionJobs >= ProjectionWorkerPolicy.backlogCompactionThreshold {
            let removed = (try? dataStore.compactConversationProjectionBacklog()) ?? 0
            if removed > 0 {
                pendingProjectionJobs = (try? dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])) ?? pendingProjectionJobs
            }
        }
        result.pendingProjectionJobs = pendingProjectionJobs

        result.apiUsages = billingResult.apiUsages
        result.postPersistencePhaseDuration = Date().timeIntervalSince(postPersistencePhaseStartedAt)

        return result
    }

    /// Off-main-actor variant used by RefreshBackgroundWork.
    func runPostPersistencePhaseOffMain(
        allUsages: [TokenUsage],
        snapshotAPIs: [any ProviderUsageAPI]
    ) async -> PostPersistenceResult {
        await runPostPersistencePhase(
            refreshStartedAt: Date(),
            allUsages: allUsages,
            indexedConversationChanges: 0,
            parsePhaseDuration: 0,
            persistencePhaseDuration: 0
        )
    }

    private static let retentionPurgeCacheKey = "data_retention_purge"
}
