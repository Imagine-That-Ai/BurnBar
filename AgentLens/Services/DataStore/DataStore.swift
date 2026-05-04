import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - DataStoreActor
//
// Actor that owns the database queue and all sub-stores.
// Heavy I/O and aggregation run here, off the main thread.
// Kept in this file (rather than DataStore/) because DataStoreCoordinator
// imports this module and moving it would require updating all import sites.

actor DataStoreActor {
    nonisolated let dbQueue: any DatabaseWriter
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
    nonisolated let providerAccountStore: ProviderAccountStore

    init(databaseQueue: any DatabaseWriter, runMigrations: Bool = true) throws {
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
        providerAccountStore = ProviderAccountStore(dbQueue: databaseQueue)

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

    func fetchConversations(limit: Int = 500) async throws -> [ConversationRecord] {
        try conversationStore.fetchConversations(limit: limit)
    }

    nonisolated func updateConversationSummary(
        id: String,
        title: String?,
        summary: String?,
        provider: String?,
        model: String?,
        updatedAt: Date = Date(),
        runCostUSD: Double = 0
    ) throws {
        try conversationStore.updateConversationSummary(
            id: id,
            title: title,
            summary: summary,
            provider: provider,
            model: model,
            updatedAt: updatedAt,
            runCostUSD: runCostUSD
        )
    }

    nonisolated func markConversationSummaryAttempt(id: String, attemptedAt: Date = Date()) throws {
        try conversationStore.markConversationSummaryAttempt(id: id, attemptedAt: attemptedAt)
    }

    nonisolated func summarySpendToday(now: Date = Date()) throws -> Double {
        try conversationStore.summarySpendToday(now: now)
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

        // Build the WHERE clause once and reuse it in each UNION ALL branch.
        // This collapses O(n) DB round-trips into a single query.
        var baseWhere = ""
        var baseArgs: [any DatabaseValueConvertible] = []
        if let provider {
            baseWhere += " AND c.provider = ?"
            baseArgs.append(provider.rawValue)
        }
        if let projectName {
            baseWhere += " AND c.projectName = ?"
            baseArgs.append(projectName)
        }
        if let range = dateRange {
            baseWhere += """
             AND COALESCE(c.endTime, c.startTime, c.fileModifiedAt, c.indexedAt) >= ?
             AND COALESCE(c.startTime, c.endTime, c.fileModifiedAt, c.indexedAt) <= ?
            """
            baseArgs.append(range.lowerBound)
            baseArgs.append(range.upperBound)
        }
        if let sources = conversationSources, sources.isEmpty == false {
            let rawValues = sources.map(\.rawValue)
            let placeholders = Array(repeating: "?", count: rawValues.count).joined(separator: ", ")
            baseWhere += " AND c.sourceType IN (\(placeholders))"
            baseArgs.append(contentsOf: rawValues)
        }

        // Build UNION ALL query: one SELECT per pattern, summed together.
        // Each branch gets pattern, pattern as args (for the LENGTH(?) divisor).
        var unionParts: [String] = []
        var allArgs: [any DatabaseValueConvertible] = []
        for pattern in cleaned {
            let p = pattern.lowercased()
            guard p.isEmpty == false else { continue }
            unionParts.append("""
            SELECT COALESCE(SUM(
                (LENGTH(COALESCE(c.fullText,'')) - LENGTH(REPLACE(LOWER(COALESCE(c.fullText,'')), ?, ?))) / LENGTH(?)
            ), 0) AS cnt
            FROM conversations AS c
            WHERE 1=1\(baseWhere)
            """)
            allArgs.append(p)
            allArgs.append(p)
            allArgs.append(p)
            allArgs.append(contentsOf: baseArgs)
        }
        let unionSQL = "SELECT COALESCE(SUM(cnt), 0) FROM (\(unionParts.joined(separator: " UNION ALL ")))"

        return try await dbQueue.read { db -> Int in
            let value = try Int64.fetchOne(db, sql: unionSQL, arguments: StatementArguments(allArgs)) ?? 0
            return Int(value)
        }
    }
}

// MARK: - DataStore (deprecated typealias)
//
// The DataStore class has been renamed to DataStoreCoordinator and moved to
// AgentLens/Services/DataStore/DataStoreCoordinator.swift. All existing code
// that imports this module will continue to work via the typealias below.
// TODO(1.0): Remove this typealias and update all import sites.

@available(*, deprecated, message: "DataStore is renamed to DataStoreCoordinator. Update your import to use DataStoreCoordinator instead.")
typealias DataStore = DataStoreCoordinator
