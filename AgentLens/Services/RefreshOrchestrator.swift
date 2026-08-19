import Foundation
import GRDB
import OpenBurnBarCore

struct PostPersistenceResult {
    var apiUsages: [ProviderUsageRecord] = []
    var parserImportError: String?
    var postPersistencePhaseDuration: TimeInterval = 0
    /// True when billing reconciliation changed `token_usage` content this
    /// cycle. Informational — the aggregator's reload decision is driven by
    /// `UsageTableWriteMarker`, which those writes bump.
    var usageRowsChanged = false
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
    /// Optional approved-memory cloud replication lane (PR-E2). Scheduled in the
    /// post-persistence cadence alongside the other sync domains, but gated OFF by
    /// default (`memoryApprovedCloudBackupEnabled`): when nil or when its own gate
    /// is closed it performs zero egress. Independent of `cloudSync`/coordinator —
    /// it owns the chat-memory `ControlPlaneStore`, not the usage/conversation store.
    let memoryCloudSyncDomain: MemoryCloudSyncDomain?

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        cloudSyncCoordinator: CloudSyncCoordinator? = nil,
        cloudSync: CloudSyncService? = nil,
        sessionMirror: ICloudSessionMirrorService? = nil,
        quotaService: ProviderQuotaService,
        usageAPIService: ProviderUsageAPIService? = nil,
        memoryCloudSyncDomain: MemoryCloudSyncDomain? = nil
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.cloudSyncCoordinator = cloudSyncCoordinator
        self.cloudSync = cloudSync
        self.sessionMirror = sessionMirror
        self.quotaService = quotaService
        self.usageAPIService = usageAPIService
        self.memoryCloudSyncDomain = memoryCloudSyncDomain
    }

    func indexConversations(_ conversations: [OpenBurnBarCore.ConversationRecord]) async -> Int {
        guard !conversations.isEmpty else { return 0 }
        let indexingEnabled = await MainActor.run { settingsManager.conversationIndexingEnabled }
        guard indexingEnabled else { return 0 }
        do {
            let indexingReport = try await ConversationIndexer.shared.index(conversations, in: dataStore)
            return indexingReport.changedRecordCount
        } catch {
            AppLogger.dataStore.error("Conversation indexing failed: \(error.localizedDescription)")
            return 0
        }
    }

    func indexConversationsOffMain(_ conversations: [OpenBurnBarCore.ConversationRecord], indexingEnabled: Bool) async -> Int {
        guard !conversations.isEmpty, indexingEnabled else { return 0 }
        do {
            let indexingReport = try await ConversationIndexer.shared.index(conversations, in: dataStore)
            return indexingReport.changedRecordCount
        } catch {
            AppLogger.dataStore.error("Conversation indexing failed: \(error.localizedDescription)")
            return 0
        }
    }

    /// Throwing variant of `indexConversationsOffMain` that propagates
    /// indexing failures instead of swallowing them into `return 0`.
    ///
    /// P-PERF-2: the checkpoint watermark MUST NOT advance after a failed
    /// indexing pass. The non-throwing variant returns 0 on both failure and
    /// success-with-no-changes, making them indistinguishable. This variant
    /// lets the caller detect failure and skip checkpoint advancement so the
    /// next tick retries the failed upserts.
    func indexConversationsOffMainThrowing(
        _ conversations: [OpenBurnBarCore.ConversationRecord],
        indexingEnabled: Bool
    ) async throws -> ConversationIndexingReport {
        guard !conversations.isEmpty, indexingEnabled else {
            return .empty
        }
        return try await ConversationIndexer.shared.index(conversations, in: dataStore)
    }

    func runRetentionPurgeIfNeeded() async {
        // No user-facing retention window is configured in SettingsManager yet, so we apply a
        // conservative built-in policy: reap terminal projection jobs (completed/canceled) that
        // the work queue will never re-read. Without this the table grows unbounded — the data
        // lifecycle audit measured 176,247 of 176,386 rows (99.9%) dead.
        // config TODO: when SettingsManager gains a retention window, also bound usage/conversation
        // history here and let the window override `terminalJobRetention`.
        let cutoff = Date().addingTimeInterval(-ProjectionWorkerPolicy.terminalJobRetention)
        do {
            let reaped = try await dataStore.reapTerminalProjectionJobs(olderThan: cutoff)
            if reaped > 0 {
                AppLogger.dataStore.info("Retention purge reaped \(reaped) terminal projection job(s).")
            }
        } catch {
            AppLogger.dataStore.silentFailure("Retention purge of terminal projection jobs failed", error: error)
        }
    }

    func runScheduledBackfillIfNeeded(parsers: [AgentProvider: any OpenBurnBarCore.LogParser]) async {
        let now = Date()

        for provider in parsers.keys {
            do {
                guard let window = try await dataStore.nextBackfillWindow(
                    for: provider,
                    currentDate: now
                ) else {
                    continue
                }

                try await dataStore.advanceBackfillCursor(
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
        let billingResult = await BillingRefreshCoordinator.reconcile(
            usageAPIService: usageAPIService,
            allParsedUsages: allUsages,
            // Bounded-window baseline: only rows whose [startTime, endTime]
            // can intersect a fetched billing record's day window — never the
            // whole history. See BillingRefreshCoordinator.reconcile docs.
            fetchReconciliationBaseline: { @Sendable [dataStore] cutoff in
                try await dataStore.fetchUsage(in: cutoff...Date.distantFuture, limit: Int.max)
            },
            fetchCredentialCostTotals: { @Sendable [dataStore] in
                try await dataStore.driftCredentialCostTotals()
            },
            // `@Sendable` makes these closures nonisolated, so `reconcile`
            // (itself `nonisolated`) runs the blocking GRDB work on the
            // cooperative pool — off this actor and off the main actor (SE-0338)
            // — without an unstructured detached task.
            persistSupplemental: { @Sendable [dataStore] newRecords in
                try await dataStore.insert(newRecords)
            },
            deleteReconciled: { @Sendable [dataStore] sessionIDPrefix in
                try await dataStore.deleteUsage(sessionIDPrefix: sessionIDPrefix)
            }
        )

        result.usageRowsChanged = billingResult.usageRowsChanged
        result.supplementalUsageCount = billingResult.supplementalUsages.count
        if let firstError = billingResult.errors.first {
            result.parserImportError = firstError
        }

        // 2. Quota refresh
        await quotaService.refreshIfNeeded(dataStore: dataStore)

        // 2a. Upload quota snapshots for iOS visibility
        let desktopSnapshots = await MainActor.run {
            quotaService.snapshotsForCloudSync
                .filter { $0.sourceKind != .unavailable }
        }
        if let coordinator = cloudSyncCoordinator {
            await coordinator.syncProviderAccounts()
            await coordinator.syncQuotaSnapshots(Array(desktopSnapshots))
        } else if let cloudSync {
            await cloudSync.uploadProviderAccountsForIOS()
            await cloudSync.uploadQuotaSnapshotsForIOS(Array(desktopSnapshots))
        }

        // 3. Cloud sync
        if let coordinator = cloudSyncCoordinator {
            await coordinator.syncUsage()
            await coordinator.syncConversationMetadata()
            await coordinator.syncSessionLogs()
            await coordinator.syncTextExpansionSnippets()
            await coordinator.syncAIInbox()
            await coordinator.syncFleetMirror()
            await coordinator.syncRoamingProfile()
            await coordinator.syncCollaborationArtifacts()
        } else if let cloudSync {
            await cloudSync.uploadPending()
            await cloudSync.uploadPendingConversations()
            await cloudSync.uploadPendingSessionLogs()
            await cloudSync.syncTextExpansionSnippets()
            await cloudSync.syncAIInbox()
            await cloudSync.syncFleetMirror()
            await cloudSync.syncRoamingProfile()
            await cloudSync.syncSharedArtifacts()
        }

        // 3a. Approved-memory cloud replication (PR-E2). Same cadence as the other
        // sync domains, but a no-op unless the user opted in AND the fleet ceiling
        // allows AND the account is sync-ready — so it ships dormant (zero egress)
        // and only the chat-memory store, not the usage/conversation store, is ever
        // touched. The domain owns its own gate + reentrancy guard.
        await memoryCloudSyncDomain?.sync()

        // 4. Session mirror sync
        await sessionMirror?.syncIfNeeded()

        // 5. Projection compaction
        var pendingProjectionJobs = (try? await dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])) ?? 0 // try?-ok(opportunistic sweep gate)
        if pendingProjectionJobs >= ProjectionWorkerPolicy.backlogCompactionThreshold {
            // Best-effort GC, but a *persistent* failure to drain a runaway backlog is a
            // correctness signal (the work queue starves and the table grows unbounded),
            // so surface the throw via telemetry instead of swallowing it. Preserve the
            // graceful `0`-removed fallback so a transient DB hiccup never breaks refresh.
            let removed: Int
            do {
                removed = try await dataStore.compactConversationProjectionBacklog()
            } catch {
                AppLogger.dataStore.silentFailure("projection_backlog_compaction_failed", error: error)
                removed = 0
            }
            if removed > 0 {
                pendingProjectionJobs = (try? await dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])) ?? pendingProjectionJobs // try?-ok(opportunistic sweep gate)
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
