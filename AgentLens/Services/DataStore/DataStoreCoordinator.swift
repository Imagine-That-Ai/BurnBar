import Foundation
import GRDB
import SwiftUI
import OpenBurnBarCore

// MARK: - DataStoreCoordinator
//
// DataStoreActor (actor) is in DataStore.swift to avoid a circular dependency.
// This class is the @MainActor @Observable facade that forwards all async calls
// to the actor. It also owns the usage view model.
//
// Previously this class was named DataStore. It was extracted to its own file
// to eliminate the monolithic DataStore.swift. All code that imports DataStore
// should continue to work via the typealias in DataStore.swift.
// TODO(1.0): Remove the DataStore typealias and update all import sites.

@Observable
@MainActor
final class DataStoreCoordinator {
    nonisolated static let legacyChatThreadID = "openburnbar-chat-legacy"

    nonisolated let actor: DataStoreActor

    nonisolated var dbQueue: any DatabaseWriter { actor.dbQueue }
    nonisolated var database: OpenBurnBarDatabase { actor.database }
    nonisolated var usageStore: UsageStore { actor.usageStore }
    nonisolated var conversationStore: ConversationStore { actor.conversationStore }
    nonisolated var searchIndexStore: SearchIndexStore { actor.searchIndexStore }
    nonisolated var artifactStore: ArtifactStore { actor.artifactStore }
    nonisolated var projectionStore: ProjectionStore { actor.projectionStore }
    nonisolated var controlPlaneStore: ControlPlaneStore { actor.controlPlaneStore }
    nonisolated var deviceStore: DeviceStore { actor.deviceStore }
    nonisolated var checkpointStore: ParserCheckpointStore { actor.checkpointStore }
    nonisolated var remoteSyncWatermarkStore: RemoteSyncWatermarkStore { actor.remoteSyncWatermarkStore }
    nonisolated var switcherStore: SwitcherProfileStore { actor.switcherStore }
    nonisolated var backfillCursorStore: BackfillCursorStore { actor.backfillCursorStore }
    nonisolated var providerAccountStore: ProviderAccountStore { actor.providerAccountStore }

    /// Presentation-layer view model for dashboard aggregate metrics.
    /// Rebuilt automatically whenever usages change.
    let usageViewModel = DashboardUsageViewModel()

    private(set) var usages: [TokenUsage] = []
    private(set) var isLoading = false
    private(set) var lastRefresh: Date?

    // MARK: - Forwarding Computed Properties (deprecated — use usageViewModel)

    /// Use `usageViewModel.moodBand` instead.
    var moodBand: MoodBand { usageViewModel.moodBand }

    /// Use `usageViewModel.moodLabel` instead.
    var moodLabel: String { usageViewModel.moodLabel }

    /// Use `usageViewModel.moodColor` instead.
    var moodColor: Color { usageViewModel.moodColor }

    /// Use `usageViewModel.totalCostToday` instead.
    var totalCostToday: Double { usageViewModel.totalCostToday }

    /// Use `usageViewModel.totalCostThisWeek` instead.
    var totalCostThisWeek: Double { usageViewModel.totalCostThisWeek }

    /// Use `usageViewModel.totalCostThisMonth` instead.
    var totalCostThisMonth: Double { usageViewModel.totalCostThisMonth }

    /// Use `usageViewModel.totalCostAllTime` instead.
    var totalCostAllTime: Double { usageViewModel.totalCostAllTime }

    /// Use `usageViewModel.totalTokensToday` instead.
    var totalTokensToday: Int { usageViewModel.totalTokensToday }

    /// Use `usageViewModel.totalTokensThisWeek` instead.
    var totalTokensThisWeek: Int { usageViewModel.totalTokensThisWeek }

    /// Use `usageViewModel.totalTokensThisMonth` instead.
    var totalTokensThisMonth: Int { usageViewModel.totalTokensThisMonth }

    /// Use `usageViewModel.totalTokensAllTime` instead.
    var totalTokensAllTime: Int { usageViewModel.totalTokensAllTime }

    /// Use `usageViewModel.last7DayCosts` instead.
    var last7DayCosts: [Double] { usageViewModel.last7DayCosts }

    /// Use `usageViewModel.last7DayTokenTotals` instead.
    var last7DayTokenTotals: [Int] { usageViewModel.last7DayTokenTotals }

    /// Use `usageViewModel.rollingDailyAverage` instead.
    var rollingDailyAverage: Double { usageViewModel.rollingDailyAverage }

    /// Use `usageViewModel.providerSummaries` instead.
    var providerSummaries: [ProviderSummary] { usageViewModel.providerSummaries }

    /// Use `usageViewModel.hasEstimatedProviders` instead.
    var hasEstimatedProviders: Bool { usageViewModel.hasEstimatedProviders }

    /// Use `usageViewModel.modelSummaries` instead.
    var modelSummaries: [ModelSummary] { usageViewModel.modelSummaries }

    func providerSummaries(in dateRange: ClosedRange<Date>?) -> [ProviderSummary] {
        usageViewModel.providerSummaries(in: dateRange)
    }

    func modelSummaries(in dateRange: ClosedRange<Date>?) -> [ModelSummary] {
        usageViewModel.modelSummaries(in: dateRange)
    }

    func cacheEfficiency(in dateRange: ClosedRange<Date>?) -> CacheEfficiency {
        usageViewModel.cacheEfficiency(in: dateRange)
    }

    func usages(in dateRange: ClosedRange<Date>?) -> [TokenUsage] {
        usageViewModel.usages(in: dateRange)
    }

    func usages(forModel normalizedName: String) -> [TokenUsage] {
        usageViewModel.usages(forModel: normalizedName)
    }

    func usages(forModel normalizedName: String, in dateRange: ClosedRange<Date>) -> [TokenUsage] {
        usageViewModel.usages(forModel: normalizedName, in: dateRange)
    }

    var dailySummaries: [DailyUsageSummary] {
        usageViewModel.dailySummaries
    }

    func usages(for provider: AgentProvider) -> [TokenUsage] {
        usageViewModel.usages(for: provider)
    }

    func usages(for provider: AgentProvider, in dateRange: ClosedRange<Date>) -> [TokenUsage] {
        usageViewModel.usages(for: provider, in: dateRange)
    }

    func topProviderToday() -> (provider: AgentProvider, cost: Double)? {
        usageViewModel.topProviderToday()
    }

    // MARK: - Initialization

    /// Creates the database pool. Reads `databaseEncryptionEnabled` directly from
    /// UserDefaults so this can be called before SettingsManager is initialized.
    /// Enables WAL mode for better read concurrency and write performance.
    private static func makeDatabasePool(path: String) throws -> DatabasePool {
        let defaults = UserDefaults.standard
        let encryptionEnabled = defaults.bool(forKey: "databaseEncryptionEnabled")
        let encryptionKey: String? = encryptionEnabled
            ? DatabaseEncryptionService.getOrCreateKey()
            : nil
        let config = DatabaseEncryptionService.makeConfiguration(encryptionKey: encryptionKey)
        return try DatabasePool(path: path, configuration: config)
    }

    /// Post-open WAL mode configuration (idempotent).
    /// WAL is automatically enabled by GRDB's DatabasePool, but we explicitly
    /// tune the checkpoint threshold for our workload.
    private static func configureWALMode(_ dbQueue: any DatabaseWriter) throws {
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
        }
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
    }

    convenience init() throws {
        let appDir = try OpenBurnBarMigration.prepareSupportDirectory()
        let dbPath = appDir.appendingPathComponent(OpenBurnBarIdentity.databaseFileName).path
        // DatabasePool enables concurrent reads (WAL mode) for read-heavy workloads
        // like dashboard aggregation and search queries. Writes remain serialized.
        let pool = try Self.makeDatabasePool(path: dbPath)
        try Self.configureWALMode(pool)
        try self.init(databaseQueue: pool)
    }

    init(
        databaseQueue: any DatabaseWriter,
        runMigrations: Bool = true,
        refreshOnInit: Bool = true
    ) throws {
        let actor = try DataStoreActor(databaseQueue: databaseQueue, runMigrations: runMigrations)
        self.actor = actor

        if refreshOnInit {
            Task { await refresh() }
        }
    }

    // MARK: - Cache Refresh

    func replaceUsages(_ newUsages: [TokenUsage]) {
        let sortedUsages = newUsages.sorted { $0.startTime > $1.startTime }
        usages = sortedUsages
        usageViewModel.replaceUsages(sortedUsages)
        lastRefresh = Date()
    }

    func refresh() async {
        isLoading = true

        do {
            let records = try await actor.fetchRecentUsage(limit: 5000)
            replaceUsages(records)
        } catch {
            AppLogger.dataStore.silentFailure("refresh_failed", error: error)
        }

        isLoading = false
    }

    func deleteAll() async throws {
        try await actor.deleteAll()
        await refresh()
    }
}
