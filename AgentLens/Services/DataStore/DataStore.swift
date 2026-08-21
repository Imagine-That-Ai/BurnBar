import Foundation
import os
@preconcurrency import GRDB
import OpenBurnBarCore

// MARK: - DataStoreActor
//
// Actor that owns the database queue and all sub-stores.
// Heavy I/O and aggregation run here, off the main thread.
// Kept in this file (rather than DataStore/) because DataStoreCoordinator
// imports this module and moving it would require updating all import sites.

actor DataStoreActor {
    nonisolated let dbQueue: any DatabaseWriter
    let database: OpenBurnBarDatabase
    let usageStore: UsageStore
    nonisolated let conversationStore: ConversationStore
    let searchIndexStore: SearchIndexStore
    let artifactStore: ArtifactStore
    let projectionStore: ProjectionStore
    let controlPlaneStore: ControlPlaneStore
    let deviceStore: DeviceStore
    let checkpointStore: ParserCheckpointStore
    nonisolated let remoteSyncWatermarkStore: RemoteSyncWatermarkStore
    nonisolated let switcherStore: SwitcherProfileStore
    let backfillCursorStore: BackfillCursorStore
    let providerAccountStore: ProviderAccountStore
    let textExpansionSnippetStore: TextExpansionSnippetStore
    nonisolated private let didCloseForTermination = OSAllocatedUnfairLock(initialState: false)

    init(
        databaseQueue: any DatabaseWriter,
        runMigrations: Bool = true,
        migrationBackupConfigurationBuilder: OpenBurnBarDatabase.MigrationBackupConfigurationBuilder? = nil
    ) throws {
        dbQueue = databaseQueue
        database = OpenBurnBarDatabase(
            databaseQueue: databaseQueue,
            migrationBackupConfigurationBuilder: migrationBackupConfigurationBuilder
        )
        usageStore = UsageStore(dbQueue: databaseQueue)
        conversationStore = ConversationStore(dbQueue: databaseQueue)
        searchIndexStore = SearchIndexStore(dbQueue: databaseQueue)
        artifactStore = ArtifactStore(dbQueue: databaseQueue)
        projectionStore = ProjectionStore(dbQueue: databaseQueue)
        controlPlaneStore = ControlPlaneStore(dbQueue: databaseQueue)
        deviceStore = DeviceStore(dbQueue: databaseQueue)
        checkpointStore = ParserCheckpointStore(dbQueue: databaseQueue)
        remoteSyncWatermarkStore = RemoteSyncWatermarkStore(dbQueue: databaseQueue)
        switcherStore = SwitcherProfileStore(dbQueue: databaseQueue)
        backfillCursorStore = BackfillCursorStore(dbQueue: databaseQueue)
        providerAccountStore = ProviderAccountStore(dbQueue: databaseQueue)
        textExpansionSnippetStore = TextExpansionSnippetStore(dbQueue: databaseQueue)

        if runMigrations {
            try database.runMigrationsSafely()
        }
    }

    // MARK: - Search / Retrieval

    func fetchConversations(limit: Int = 500) async throws -> [OpenBurnBarCore.ConversationRecord] {
        try await conversationStore.fetchConversations(limit: limit)
    }

    func updateConversationSummary(
        id: String,
        title: String?,
        summary: String?,
        provider: String?,
        model: String?,
        updatedAt: Date = Date(),
        runCostUSD: Double = 0
    ) async throws {
        try await conversationStore.updateConversationSummary(
            id: id,
            title: title,
            summary: summary,
            provider: provider,
            model: model,
            updatedAt: updatedAt,
            runCostUSD: runCostUSD
        )
    }

    func markConversationSummaryAttempt(id: String, attemptedAt: Date = Date()) async throws {
        try await conversationStore.markConversationSummaryAttempt(id: id, attemptedAt: attemptedAt)
    }

    func summarySpendToday(now: Date = Date()) async throws -> Double {
        try await conversationStore.summarySpendToday(now: now)
    }

    func runWorkingDirectoryBackfillIfNeeded() async {
        await WorkingDirectoryBackfillService().runIfNeeded(database: database)
    }

    func fetchDashboardUsageSnapshot(loadedUsageLimit: Int) async throws -> DashboardUsageSnapshot {
        try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: loadedUsageLimit)
    }

    func fetchUsageTotals(in dateRange: ClosedRange<Date>?) async throws -> UsageTotals {
        try await usageStore.fetchUsageTotals(in: dateRange)
    }

    func deleteAllUsageRows() async throws {
        try await usageStore.deleteAll()
    }

    /// Current usage-table new-event marker (see `UsageTableWriteMarker`).
    /// The periodic refresh tick compares this against the last value it
    /// reloaded at to skip O(total-history) refetches when nothing changed.
    var usageTableWriteMarker: Int {
        usageStore.writeMarker.value
    }

    /// One write for a chunk of indexer upserts plus their projection jobs.
    /// Tombstoned rows stay buried (`deletedAt` is not in the SET clause) and
    /// do not enqueue a job — matching `enqueueConversationProjectionJob`'s
    /// live-row `fetchConversation` guard.
    func persistIndexedConversations(
        _ items: [IndexedConversationWrite],
        now: Date
    ) async throws -> Int {
        guard items.isEmpty == false else { return 0 }
        return try await dbQueue.write { [self] db in
            var enqueued = 0
            for item in items {
                let isLive = try conversationStore.upsertConversation(item.record, db: db)
                guard isLive else { continue }
                let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: item.record)
                let job = ProjectionJobRecord(
                    id: ProjectionIdentity.jobID(
                        jobType: item.jobType,
                        sourceKind: .conversation,
                        sourceID: item.record.id,
                        sourceVersionID: sourceVersionID
                    ),
                    jobType: item.jobType,
                    sourceKind: .conversation,
                    sourceID: item.record.id,
                    sourceVersionID: sourceVersionID,
                    status: .queued,
                    priority: 5,
                    attempts: 0,
                    maxAttempts: 5,
                    scheduledAt: now,
                    availableAt: now,
                    createdAt: now,
                    updatedAt: now
                )
                try projectionStore.enqueueProjectionJob(job, db: db)
                enqueued += 1
            }
            return enqueued
        }
    }

    /// Abort in-flight SQL and close the writer so `exit()` cannot tear down
    /// SQLCipher while a `DatabasePool` reader is still in `sqlite3Codec`.
    ///
    /// Nonisolated on purpose: an actor-isolated close would sit behind
    /// `fetchDashboardUsageSnapshot` (the crash's in-flight read) and never
    /// run until that read finished — which is exactly the window `exit()`
    /// used to win. `dbQueue` is already `nonisolated`.
    nonisolated func closeForTermination() {
        let alreadyClosed = didCloseForTermination.withLock { closed -> Bool in
            if closed { return true }
            closed = true
            return false
        }
        guard !alreadyClosed else { return }
        dbQueue.interrupt()
        do {
            try dbQueue.close()
        } catch {
            dbQueue.interrupt()
            do {
                try dbQueue.close()
            } catch {
                AppLogger.dataStore.notice(
                    "database_close_on_termination_failed",
                    metadata: ["error": "\(error)"]
                )
            }
        }
    }
}

// MARK: - DataStore compatibility typealias
//
// The DataStore class has been renamed to DataStoreCoordinator and moved to
// AgentLens/Services/DataStore/DataStoreCoordinator.swift. The compatibility
// name remains intentionally warning-free until the migration can land as a
// focused call-site rename instead of drowning Swift 6 diagnostics in duplicate
// deprecation noise.

typealias DataStore = DataStoreCoordinator

extension DataStore {
    func fetchSwitcherProfiles() throws -> [SwitcherProfileRecord] {
        try switcherStore.fetchAllProfiles()
    }

    func countSwitcherProfiles() throws -> Int {
        try fetchSwitcherProfiles().count
    }

    func setActiveSwitcherProfile(_ profileID: String?) throws {
        try switcherStore.setActiveProfile(profileID)
    }

    func fetchSwitcherProfilesForQuota() throws -> [SwitcherProfileRecord] {
        try fetchSwitcherProfiles()
    }
}
