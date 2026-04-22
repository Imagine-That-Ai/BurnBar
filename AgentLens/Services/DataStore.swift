import Foundation
import GRDB
import SwiftUI
import OpenBurnBarCore

// MARK: - DataStoreActor

/// Actor that owns the database queue and all sub-stores.
/// Heavy I/O and aggregation run here, off the main thread.
actor DataStoreActor {
    nonisolated let dbQueue: DatabaseQueue
    nonisolated let database: OpenBurnBarDatabase
    nonisolated let usageStore: UsageStore
    nonisolated let conversationStore: ConversationStore
    nonisolated let searchIndexStore: SearchIndexStore
    nonisolated let artifactStore: ArtifactStore
    nonisolated let projectionStore: ProjectionStore
    nonisolated let controlPlaneStore: ControlPlaneStore
    nonisolated let deviceStore: DeviceStore
    nonisolated let checkpointStore: ParserCheckpointStore
    nonisolated let remoteSyncWatermarkStore: RemoteSyncWatermarkStore
    nonisolated let switcherStore: SwitcherProfileStore
    nonisolated let backfillCursorStore: BackfillCursorStore

    init(databaseQueue: DatabaseQueue, runMigrations: Bool = true) throws {
        dbQueue = databaseQueue
        database = OpenBurnBarDatabase(databaseQueue: databaseQueue)
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

        if runMigrations {
            try database.runMigrationsSafely()
        }
    }

    // MARK: - Heavy Usage Queries

    func fetchAllUsage() async throws -> [TokenUsage] {
        try usageStore.fetchAllUsage()
    }

    func fetchRecentUsage(limit: Int) async throws -> [TokenUsage] {
        try usageStore.fetchRecentUsage(limit: limit)
    }

    func deleteAll() async throws {
        try usageStore.deleteAll()
    }

    // MARK: - Search / Retrieval

    func searchLexicalChunks(
        ftsQuery: String,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        sourceKinds: [SearchSourceKind]? = nil,
        dateRange: ClosedRange<Date>? = nil,
        visibility: SearchVisibilityScope = .all,
        sharedArtifactAccessContext: SharedArtifactAccessContext? = nil,
        sourceIDs: [String]? = nil,
        limit: Int = 120
    ) async throws -> [SearchChunkLexicalMatch] {
        let trimmed = ftsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        return try searchIndexStore.searchLexicalChunks(
            ftsQuery: trimmed,
            provider: provider?.rawValue,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange,
            visibility: visibility,
            sharedArtifactAccessContext: sharedArtifactAccessContext,
            sourceIDs: sourceIDs,
            limit: limit
        )
    }

    func fetchSearchChunks(ids: [String]) async throws -> [SearchChunkRecord] {
        try searchIndexStore.fetchChunks(ids: ids)
    }

    func fetchSearchDocuments(ids: [String]) async throws -> [SearchDocumentRecord] {
        try searchIndexStore.fetchDocuments(ids: ids)
    }

    func fetchConversation(id: String) async throws -> ConversationRecord? {
        try conversationStore.fetchConversation(id: id)
    }

    func fetchReadableSharedArtifactSourceIDs(
        accessContext: SharedArtifactAccessContext,
        limit: Int = 2_000
    ) async throws -> Set<String> {
        Set(try artifactStore.fetchReadableSharedArtifactSourceIDs(accessContext: accessContext, limit: limit))
    }

    func countOccurrencesInConversationFullText(
        patterns: [String],
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        conversationSources: Set<ConversationSourceType>? = nil
    ) async throws -> Int {
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard cleaned.isEmpty == false else { return 0 }

        var total = 0
        for raw in cleaned {
            let pattern = raw.lowercased()
            guard pattern.isEmpty == false else { continue }
            let count = try await dbQueue.read { db -> Int in
                var sql = """
                SELECT COALESCE(SUM(
                    (LENGTH(COALESCE(c.fullText,'')) - LENGTH(REPLACE(LOWER(COALESCE(c.fullText,'')), ?, ''))) / LENGTH(?)
                ), 0)
                FROM conversations AS c
                WHERE 1 = 1
                """
                var args: [any DatabaseValueConvertible] = [pattern, pattern]
                if let provider {
                    sql += " AND c.provider = ?"
                    args.append(provider.rawValue)
                }
                if let projectName {
                    sql += " AND c.projectName = ?"
                    args.append(projectName)
                }
                if let range = dateRange {
                    sql += """
                     AND COALESCE(c.endTime, c.startTime, c.fileModifiedAt, c.indexedAt) >= ?
                     AND COALESCE(c.startTime, c.endTime, c.fileModifiedAt, c.indexedAt) <= ?
                    """
                    args.append(range.lowerBound)
                    args.append(range.upperBound)
                }
                if let sources = conversationSources, sources.isEmpty == false {
                    let rawValues = sources.map(\.rawValue)
                    let placeholders = Array(repeating: "?", count: rawValues.count).joined(separator: ", ")
                    sql += " AND c.sourceType IN (\(placeholders))"
                    args.append(contentsOf: rawValues)
                }
                let value = try Int64.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
                return Int(value)
            }
            total += count
        }

        return total
    }
}

// MARK: - DataStore

@Observable
@MainActor
final class DataStore {
    nonisolated static let legacyChatThreadID = "openburnbar-chat-legacy"

    let actor: DataStoreActor

    nonisolated var dbQueue: DatabaseQueue { actor.dbQueue }
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

    convenience init() throws {
        let appDir = try OpenBurnBarMigration.prepareSupportDirectory()
        let dbPath = appDir.appendingPathComponent(OpenBurnBarIdentity.databaseFileName).path
        let queue = try DatabaseQueue(path: dbPath)
        try self.init(databaseQueue: queue)
    }

    init(
        databaseQueue: DatabaseQueue,
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
            print("DataStore: Failed to refresh data: \(error)")
        }

        isLoading = false
    }

    func deleteAll() async throws {
        try await actor.deleteAll()
        await refresh()
    }
}
