import Foundation
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

    func fetchConversations(limit: Int = 500) async throws -> [ConversationRecord] {
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

    func deleteAllUsageRows() async throws {
        try await usageStore.deleteAll()
    }

    func insertUsageAndFetchAll(_ newRecords: [TokenUsage]) async throws -> [TokenUsage] {
        try await usageStore.insert(newRecords)
        return try await usageStore.fetchAllUsage()
    }

    func deleteUsageAndFetchAll(sessionIDPrefix: String) async throws -> [TokenUsage] {
        try await usageStore.deleteUsage(sessionIDPrefix: sessionIDPrefix)
        return try await usageStore.fetchAllUsage()
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
