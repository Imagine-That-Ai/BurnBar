import Foundation
import CryptoKit
import GRDB
import OpenBurnBarCore

// MARK: - UsageStore

/// Token-usage CRUD, sync helpers, refresh reads, and provider/model summary builders.
final class UsageStore: Sendable {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Insert

    func insert(_ usage: TokenUsage) throws {
        try dbQueue.write { db in
            try deleteKimiRequestIDModelRows(replacedBy: usage, in: db)
            if try shouldSuppressFactoryRoutedMirror(usage, in: db) {
                return
            }
            try deleteFactoryRoutedMirrorRows(replacedBy: usage, in: db)
            try deleteStaleLowerConfidenceModelRows(replacedBy: usage, in: db)
            try upsertUsage(usage, in: db)
        }
        SearchQueryCache.shared.clear()
    }

    func insert(_ newUsages: [TokenUsage]) throws {
        guard !newUsages.isEmpty else { return }
        try dbQueue.write { db in
            for usage in newUsages {
                try deleteKimiRequestIDModelRows(replacedBy: usage, in: db)
                if try shouldSuppressFactoryRoutedMirror(usage, in: db) {
                    continue
                }
                try deleteFactoryRoutedMirrorRows(replacedBy: usage, in: db)
                try deleteStaleLowerConfidenceModelRows(replacedBy: usage, in: db)
                try upsertUsage(usage, in: db)
            }
        }
        SearchQueryCache.shared.clear()
    }

    /// Inserts `newUsages` in fixed-size chunks, each in its own transaction.
    ///
    /// On a transient `SQLITE_IOERR` (commonly an APFS/WAL shared-memory hiccup
    /// during a large import), the failed chunk is retried once after running
    /// `PRAGMA wal_checkpoint(TRUNCATE)` to reset the WAL/SHM files. Successful
    /// chunks committed before the failure are preserved, so users don't lose
    /// progress on a long import to a single bad commit.
    ///
    /// `chunkSize` is a balance between transaction overhead and rollback blast
    /// radius. 100 keeps each commit small enough that even a worst-case retry
    /// reprocesses a small batch.
    func insertChunked(_ newUsages: [TokenUsage], chunkSize: Int = 100) throws {
        guard !newUsages.isEmpty else { return }
        var index = 0
        while index < newUsages.count {
            let end = min(index + chunkSize, newUsages.count)
            let chunk = Array(newUsages[index..<end])
            try insertChunkWithIOErrorRecovery(chunk)
            index = end
        }
    }

    private func insertChunkWithIOErrorRecovery(_ chunk: [TokenUsage]) throws {
        do {
            try insert(chunk)
        } catch let dbError as DatabaseError where dbError.resultCode == .SQLITE_IOERR {
            AppLogger.dataStore.error(
                "INSERT INTO token_usage hit SQLITE_IOERR; attempting WAL checkpoint truncate then retry",
                metadata: [
                    "resultCode": "\(dbError.resultCode.rawValue)",
                    "extendedResultCode": "\(dbError.extendedResultCode.rawValue)",
                    "chunkSize": "\(chunk.count)"
                ]
            )
            try checkpointTruncate()
            try insert(chunk)
        }
    }

    /// Forces SQLite to drain and truncate the WAL/SHM files. Used as a recovery
    /// step when an INSERT fails with `SQLITE_IOERR`, which on macOS is most
    /// commonly an APFS-level issue with the `-wal` / `-shm` sidecar files.
    func checkpointTruncate() throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    private func deleteKimiRequestIDModelRows(replacedBy usage: TokenUsage, in db: Database) throws {
        guard usage.provider == .kimi,
              !Self.isKimiRequestIDModel(usage.model) else { return }
        let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)

        try db.execute(
            sql: """
                DELETE FROM token_usage
                WHERE provider = ?
                  AND sessionId = ?
                  AND model LIKE 'chatcmpl-%'
                  AND COALESCE(sourceDeviceId, '') = COALESCE(?, '')
                  AND COALESCE(providerAccountID, '') = COALESCE(?, '')
                """,
            arguments: [
                usage.provider.rawValue,
                usage.sessionId,
                usage.sourceDeviceId,
                usagePartition,
            ]
        )
    }

    private static func isKimiRequestIDModel(_ model: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("chatcmpl-")
    }

    private func shouldSuppressFactoryRoutedMirror(_ usage: TokenUsage, in db: Database) throws -> Bool {
        guard Self.isFactoryRoutedMirrorProvider(usage.provider) else { return false }
        let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)
        let count = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM token_usage
                WHERE provider = ?
                  AND sessionId = ?
                  AND COALESCE(sourceDeviceId, '') = COALESCE(?, '')
                  AND COALESCE(providerAccountID, '') = COALESCE(?, '')
                """,
            arguments: [
                AgentProvider.factory.rawValue,
                usage.sessionId,
                usage.sourceDeviceId,
                usagePartition,
            ]
        ) ?? 0
        return count > 0
    }

    private func deleteFactoryRoutedMirrorRows(replacedBy usage: TokenUsage, in db: Database) throws {
        guard usage.provider == .factory else { return }
        let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)
        try db.execute(
            sql: """
                DELETE FROM token_usage
                WHERE provider IN (?, ?, ?)
                  AND sessionId = ?
                  AND COALESCE(sourceDeviceId, '') = COALESCE(?, '')
                  AND COALESCE(providerAccountID, '') = COALESCE(?, '')
                """,
            arguments: [
                AgentProvider.zai.rawValue,
                AgentProvider.minimax.rawValue,
                AgentProvider.ollama.rawValue,
                usage.sessionId,
                usage.sourceDeviceId,
                usagePartition,
            ]
        )
    }

    private func deleteStaleLowerConfidenceModelRows(replacedBy usage: TokenUsage, in db: Database) throws {
        let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)
        try db.execute(
            sql: """
                DELETE FROM token_usage
                WHERE provider = ?
                  AND sessionId = ?
                  AND model != ?
                  AND COALESCE(sourceDeviceId, '') = COALESCE(?, '')
                  AND COALESCE(providerAccountID, '') = COALESCE(?, '')
                  AND (
                    CASE provenanceConfidence
                        WHEN 'exact' THEN 4
                        WHEN 'derived_exact' THEN 3
                        WHEN 'high_confidence_estimate' THEN 2
                        WHEN 'low_confidence_estimate' THEN 1
                        ELSE 0
                    END
                  ) < ?
                """,
            arguments: [
                usage.provider.rawValue,
                usage.sessionId,
                usage.model,
                usage.sourceDeviceId,
                usagePartition,
                usage.provenanceConfidence.precedence,
            ]
        )
    }

    private static func isFactoryRoutedMirrorProvider(_ provider: AgentProvider) -> Bool {
        provider == .zai || provider == .minimax || provider == .ollama
    }

    /// Inserts remote usage with update-to-correction semantics.
    ///
    /// VAL-TOKEN-012: Remote re-ingest follows explicit "update-to-correction" semantics.
    /// If remote data provides a correction for the same logical key, the canonical row
    /// converges to the corrected values.
    ///
    /// VAL-PERSIST-009: Remote correction convergence is enforced.
    /// When upstream remote data corrects a previously ingested remote row for the same
    /// logical key, local persistence converges to corrected canonical values.
    ///
    /// Precedence is still respected: higher-confidence data wins over lower-confidence.
    /// Cloud sync data with equal or higher confidence than existing row will update it.
    func insertRemoteUsage(_ usage: TokenUsage) throws {
        try dbQueue.write { db in
            let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)
            try db.execute(
                sql: """
                    INSERT INTO token_usage (
                        id, provider, sessionId, projectName, model,
                        inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                        reasoningTokens, totalTokens, cost, startTime, endTime, createdAt,
                        usageSource, sourceDeviceId, sourceDeviceName, isRemote, syncedAt,
                        providerID, providerAccountID, providerAccountLabel, providerAccountSource,
                        provenanceMethod, provenanceConfidence, estimatorVersion
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider, sessionId, model, COALESCE(sourceDeviceId, ''), COALESCE(providerAccountID, '')) DO UPDATE SET
                        projectName = excluded.projectName,
                        inputTokens = excluded.inputTokens,
                        outputTokens = excluded.outputTokens,
                        cacheCreationTokens = excluded.cacheCreationTokens,
                        cacheReadTokens = excluded.cacheReadTokens,
                        reasoningTokens = excluded.reasoningTokens,
                        totalTokens = excluded.totalTokens,
                        cost = excluded.cost,
                        startTime = excluded.startTime,
                        endTime = excluded.endTime,
                        createdAt = excluded.createdAt,
                        -- VAL-TOKEN-009: Preserve source identity on equal-confidence upserts.
                        -- Only update usageSource when incoming confidence is strictly higher.
                        usageSource = CASE
                            WHEN
                                CASE excluded.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                                >
                                CASE token_usage.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                            THEN excluded.usageSource
                            ELSE token_usage.usageSource
                        END,
                        sourceDeviceId = CASE
                            WHEN CASE excluded.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                                >=
                                CASE token_usage.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                            THEN excluded.sourceDeviceId
                            ELSE token_usage.sourceDeviceId
                        END,
                        sourceDeviceName = CASE
                            WHEN CASE excluded.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                                >=
                                CASE token_usage.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                            THEN excluded.sourceDeviceName
                            ELSE token_usage.sourceDeviceName
                        END,
                        isRemote = excluded.isRemote,
                        providerID = excluded.providerID,
                        providerAccountID = excluded.providerAccountID,
                        providerAccountLabel = excluded.providerAccountLabel,
                        providerAccountSource = excluded.providerAccountSource,
                        provenanceMethod = excluded.provenanceMethod,
                        provenanceConfidence = CASE
                            WHEN
                                CASE excluded.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                                >=
                                CASE token_usage.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                            THEN excluded.provenanceConfidence
                            ELSE token_usage.provenanceConfidence
                        END,
                        estimatorVersion = excluded.estimatorVersion,
                        syncedAt = NULL
                    WHERE
                        CASE excluded.provenanceConfidence
                            WHEN 'exact' THEN 4
                            WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1
                            ELSE 0
                        END
                        >=
                        CASE token_usage.provenanceConfidence
                            WHEN 'exact' THEN 4
                            WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1
                            ELSE 0
                        END
                    """,
                arguments: [
                    usage.id.uuidString, usage.provider.rawValue, usage.sessionId,
                    usage.projectName, usage.model,
                    usage.inputTokens, usage.outputTokens, usage.cacheCreationTokens,
                    usage.cacheReadTokens, usage.reasoningTokens, usage.totalTokens, usage.cost,
                    usage.startTime, usage.endTime, usage.createdAt,
                    usage.usageSource.rawValue,
                    usage.sourceDeviceId, usage.sourceDeviceName, usage.isRemote, Date(),
                    usage.providerID.rawValue,
                    usagePartition,
                    usage.providerAccountLabel,
                    usage.providerAccountSource?.rawValue,
                    usage.provenanceMethod.rawValue,
                    usage.provenanceConfidence.rawValue,
                    usage.estimatorVersion
                ]
            )
        }
        SearchQueryCache.shared.clear()
    }

    // MARK: - Refresh

    func fetchAllUsage() throws -> [TokenUsage] {
        try fetchRecentUsage(limit: Int.max)
    }

    func fetchRecentUsage(limit: Int) throws -> [TokenUsage] {
        try dbQueue.read { db -> [TokenUsage] in
            try Self.fetchUsageRows(db: db, dateRange: nil, limit: limit)
        }
    }

    func fetchDashboardUsageSnapshot(loadedUsageLimit: Int) throws -> DashboardUsageSnapshot {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)

        return try dbQueue.read { db in
            var windowSummaries: [TimeRange: DashboardUsageWindowSummary] = [:]
            for timeRange in TimeRange.allCases {
                windowSummaries[timeRange] = try Self.fetchWindowSummary(
                    db: db,
                    dateRange: timeRange.dateRange(),
                    loadedUsageLimit: loadedUsageLimit
                )
            }

            let allTime = windowSummaries[.allTime] ?? .empty
            let today = windowSummaries[.today] ?? .empty

            var last7DayCosts: [Double] = []
            var last7DayTokenTotals: [Int] = []
            for offset in (0..<7).reversed() {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                      let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                    last7DayCosts.append(0)
                    last7DayTokenTotals.append(0)
                    continue
                }
                let totals = try Self.fetchUsageTotals(db: db, dateRange: day...nextDay)
                last7DayCosts.append(totals.cost)
                last7DayTokenTotals.append(totals.tokens)
            }

            var rollingDailyTotal: Double = 0
            for dayOffset in 1...7 {
                guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: todayStart),
                      let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
                rollingDailyTotal += try Self.fetchUsageTotals(db: db, dateRange: day...nextDay).cost
            }

            return DashboardUsageSnapshot(
                loadedUsages: allTime.usages,
                windowSummaries: windowSummaries,
                rollingDailyAverage: rollingDailyTotal / 7,
                distinctUsageDayCount: try Self.fetchDistinctUsageDayCount(db: db),
                last7DayCosts: last7DayCosts,
                last7DayTokenTotals: last7DayTokenTotals,
                dailySummaries: try Self.fetchDailySummaries(db: db),
                topProviderToday: today.providerSummaries
                    .max { $0.totalCost < $1.totalCost }
                    .map { ($0.provider, $0.totalCost) }
            )
        }
    }

    /// Lightweight per-provider totals (runs + cost + tokens) for a single
    /// time window, used by the Smart Hub bridge to populate the footer of
    /// each provider card on the Nest Hub.
    ///
    /// This is intentionally cheap compared to `fetchDashboardUsageSnapshot`
    /// — one `GROUP BY provider` query, no per-model breakdown, no daily
    /// series. The bridge calls it on its 5s snapshot pump so it has to
    /// stay cheap.
    func providerRunCostTotals(in dateRange: ClosedRange<Date>?) throws -> [AgentProvider: ProviderRunCostTotals] {
        try dbQueue.read { db in
            let predicate = Self.dateRangePredicate(dateRange)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT provider,
                           COUNT(*) AS sessionCount,
                           COALESCE(SUM(totalTokens), 0) AS totalTokens,
                           COALESCE(SUM(cost), 0) AS cost
                    FROM token_usage
                    \(predicate.whereSQL)
                    GROUP BY provider
                    """,
                arguments: predicate.arguments
            )

            var result: [AgentProvider: ProviderRunCostTotals] = [:]
            for row in rows {
                guard let raw = row["provider"] as? String,
                      let provider = AgentProvider(rawValue: raw) else { continue }
                result[provider] = ProviderRunCostTotals(
                    sessionCount: Self.intValue(row["sessionCount"]),
                    totalTokens: Self.intValue(row["totalTokens"]),
                    totalCost: Self.doubleValue(row["cost"])
                )
            }
            return result
        }
    }

    // MARK: - Delete

    func deleteAll() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM token_usage")
        }
    }

    // VAL-PERSIST-013: Reconciliation cleanup is source-scoped.
    // Cleanup of prior API-reconciliation rows must be constrained by source semantics
    // (billing_api) in addition to identifier prefix policy, so non-reconciliation rows
    // are never deleted accidentally.
    func deleteUsage(sessionIDPrefix: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM token_usage
                    WHERE sessionId LIKE ?
                    AND COALESCE(sourceDeviceId, '') = ''
                    AND usageSource = 'billing_api'
                    """,
                arguments: ["\(sessionIDPrefix)%"]
            )
        }
    }

    // MARK: - Sync

    func fetchUnsynced() throws -> [TokenUsage] {
        try dbQueue.read { db -> [TokenUsage] in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM token_usage WHERE syncedAt IS NULL AND isRemote = 0 ORDER BY startTime ASC LIMIT 400"
            )
            return rows.compactMap(Self.decodeUsage)
        }
    }

    func markSynced(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let idStrings: [String] = ids.map { $0.uuidString }
        try dbQueue.write { db in
            var args = StatementArguments([Date()])
            args += StatementArguments(idStrings)
            try db.execute(
                sql: "UPDATE token_usage SET syncedAt = ? WHERE id IN (\(placeholders))",
                arguments: args
            )
        }
    }

    // MARK: - Session Facets Lookup

    /// Aggregates token + cost + timing facets per `(provider:rootSession)` so the encrypted
    /// session-log backup can attach plaintext cockpit facets to each manifest without ever
    /// touching the conversation body. Mirrors `sessionModelMap()` keying so the two maps align.
    func sessionFacetsMap() throws -> [String: SessionUsageFacets] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT provider, sessionId, model,
                    SUM(inputTokens) AS input,
                    SUM(outputTokens) AS output,
                    SUM(cacheCreationTokens) AS cacheCreation,
                    SUM(cacheReadTokens) AS cacheRead,
                    SUM(totalTokens) AS total,
                    SUM(cost) AS cost,
                    MIN(startTime) AS startTime,
                    MAX(endTime) AS endTime
                FROM token_usage
                GROUP BY provider, sessionId
                """)
            var result: [String: SessionUsageFacets] = [:]
            for row in rows {
                guard let provider = row["provider"] as? String,
                      let sessionId = row["sessionId"] as? String else { continue }
                let rootSession: String
                if let slashIdx = sessionId.firstIndex(of: "/") {
                    rootSession = String(sessionId[..<slashIdx])
                } else {
                    rootSession = sessionId
                }
                let key = "\(provider):\(rootSession)"
                let facets = SessionUsageFacets(
                    model: row["model"] as? String ?? "unknown",
                    inputTokens: Self.intColumn(row, "input"),
                    outputTokens: Self.intColumn(row, "output"),
                    cacheCreationTokens: Self.intColumn(row, "cacheCreation"),
                    cacheReadTokens: Self.intColumn(row, "cacheRead"),
                    totalTokens: Self.intColumn(row, "total"),
                    costUSD: row["cost"] as? Double ?? 0,
                    startTime: row["startTime"] as? Date,
                    endTime: row["endTime"] as? Date
                )
                if let existing = result[key] {
                    result[key] = existing.merging(facets)
                } else {
                    result[key] = facets
                }
            }
            return result
        }
    }

    private static func intColumn(_ row: Row, _ name: String) -> Int {
        if let value: Int = row[name] { return value }
        if let value: Int64 = row[name] { return Int(value) }
        if let value: Double = row[name] { return Int(value.rounded()) }
        return 0
    }

    // MARK: - Session Model Lookup

    func sessionModelMap() throws -> [String: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT provider, sessionId, model, SUM(cost) AS totalCost
                FROM token_usage
                GROUP BY provider, sessionId, model
                ORDER BY provider, sessionId, totalCost DESC
                """)
            var result: [String: String] = [:]
            for row in rows {
                guard let provider = row["provider"] as? String,
                      let sessionId = row["sessionId"] as? String,
                      let model = row["model"] as? String else { continue }
                let rootSession: String
                if let slashIdx = sessionId.firstIndex(of: "/") {
                    rootSession = String(sessionId[..<slashIdx])
                } else {
                    rootSession = sessionId
                }
                let key = "\(provider):\(rootSession)"
                if result[key] == nil {
                    result[key] = model
                }
            }
            return result
        }
    }

    // MARK: - Summary Builders

    static func makeProviderSummaries(from usages: [TokenUsage]) -> [ProviderSummary] {
        AgentProvider.allCases.compactMap { provider -> ProviderSummary? in
            let providerUsages = usages.filter { $0.provider == provider }
            guard !providerUsages.isEmpty else { return nil }

            let totalCost = providerUsages.reduce(0) { $0 + $1.cost }
            let totalTokens = providerUsages.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = providerUsages.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = providerUsages.reduce(0) { $0 + $1.outputTokens }

            // Track model data including provenance
            var modelData: [String: (input: Int, output: Int, cacheCreation: Int, cacheRead: Int, reasoning: Int, cost: Double, bestConfidence: UsageProvenanceConfidence, bestMethod: UsageProvenanceMethod, hasEstimated: Bool)] = [:]
            for usage in providerUsages {
                let existing = modelData[usage.model]
                let newConfidence = usage.provenanceConfidence
                let newMethod = usage.provenanceMethod
                let bestConfidence: UsageProvenanceConfidence
                let bestMethod: UsageProvenanceMethod
                if let existingRec = existing {
                    bestConfidence = newConfidence > existingRec.bestConfidence ? newConfidence : existingRec.bestConfidence
                    if newConfidence == existingRec.bestConfidence {
                        bestMethod = newMethod.precedence > existingRec.bestMethod.precedence ? newMethod : existingRec.bestMethod
                    } else {
                        bestMethod = newConfidence > existingRec.bestConfidence ? newMethod : existingRec.bestMethod
                    }
                } else {
                    bestConfidence = newConfidence
                    bestMethod = newMethod
                }
                let rowIsEstimated = newConfidence != .exact && newConfidence != .derivedExact
                let existingHasEstimated = existing?.hasEstimated ?? false
                modelData[usage.model] = (
                    (existing?.0 ?? 0) + usage.inputTokens,
                    (existing?.1 ?? 0) + usage.outputTokens,
                    (existing?.2 ?? 0) + usage.cacheCreationTokens,
                    (existing?.3 ?? 0) + usage.cacheReadTokens,
                    (existing?.4 ?? 0) + usage.reasoningTokens,
                    (existing?.5 ?? 0) + usage.cost,
                    bestConfidence,
                    bestMethod,
                    existingHasEstimated || rowIsEstimated
                )
            }

            // Compute dominant provenance for the provider overall
            // Also track whether any row has estimated provenance
            var dominantConfidence: UsageProvenanceConfidence = .unknown
            var dominantMethod: UsageProvenanceMethod = .unknown
            var bestCostSoFar: Double = 0
            var hasAnyEstimated: Bool = false
            for usage in providerUsages {
                // Track estimated contributions
                let rowIsEstimated = usage.provenanceConfidence != .exact && usage.provenanceConfidence != .derivedExact
                hasAnyEstimated = hasAnyEstimated || rowIsEstimated
                let weight = usage.cost > 0 ? usage.cost : 0.001
                if usage.provenanceConfidence > dominantConfidence {
                    dominantConfidence = usage.provenanceConfidence
                    dominantMethod = usage.provenanceMethod
                    bestCostSoFar = weight
                } else if usage.provenanceConfidence == dominantConfidence && weight > bestCostSoFar {
                    dominantMethod = usage.provenanceMethod
                    bestCostSoFar = weight
                }
            }

            let modelBreakdown = modelData.map { modelName, data in
                let totalModelTokens = data.0 + data.1 + data.2 + data.3 + data.4
                return ModelUsage(
                    modelName: modelName,
                    inputTokens: data.0,
                    outputTokens: data.1,
                    cacheCreationTokens: data.2,
                    cacheReadTokens: data.3,
                    reasoningTokens: data.4,
                    totalTokens: totalModelTokens,
                    cost: data.5,
                    percentage: totalCost > 0 ? (data.5 / totalCost) * 100 : 0,
                    provenanceConfidence: data.bestConfidence,
                    provenanceMethod: data.bestMethod,
                    hasEstimatedContributions: data.hasEstimated
                )
            }.sorted { $0.cost > $1.cost }

            return ProviderSummary(
                provider: provider,
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: providerUsages.count,
                modelBreakdown: modelBreakdown,
                provenanceConfidence: dominantConfidence,
                provenanceMethod: dominantMethod,
                hasEstimatedContributions: hasAnyEstimated,
                cacheEfficiency: CacheEfficiency.aggregate(providerUsages)
            )
        }.sorted { $0.totalCost > $1.totalCost }
    }


    /// Aggregates `token_usage` rows by `(provider, providerAccountID)` to power the
    /// "Spend by Credential" dashboard lane. Mirrors `makeProviderSummaries` but slices
    /// at the credential dimension so users with multiple API keys (or distinct OAuth
    /// identities) per provider see distinct totals.
    static func makeCredentialSummaries(from usages: [TokenUsage]) -> [CredentialSummary] {
        struct GroupKey: Hashable {
            let provider: AgentProvider
            let accountID: String?
        }

        var groups: [GroupKey: [TokenUsage]] = [:]
        for usage in usages {
            let key = GroupKey(provider: usage.provider, accountID: usage.providerAccountID)
            groups[key, default: []].append(usage)
        }

        return groups.compactMap { (key, rows) -> CredentialSummary? in
            guard !rows.isEmpty else { return nil }

            let totalCost = rows.reduce(0) { $0 + $1.cost }
            let totalTokens = rows.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = rows.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = rows.reduce(0) { $0 + $1.outputTokens }

            // Derive the best display label and storage scope across rows.
            // Some rows may have richer metadata than others; prefer the most informative.
            let nonEmptyLabel = rows.first(where: { ($0.providerAccountLabel ?? "").isEmpty == false })?.providerAccountLabel
            let accountLabel: String = {
                if let label = nonEmptyLabel, !label.isEmpty { return label }
                if let id = key.accountID, !id.isEmpty {
                    let suffix = id.suffix(6)
                    return "\(key.provider.displayName) · …\(suffix)"
                }
                return "\(key.provider.displayName) · default"
            }()
            let accountSource = rows.compactMap { $0.providerAccountSource }.first

            // Per-model rollup (same shape as makeProviderSummaries).
            var modelData: [String: (input: Int, output: Int, cacheCreation: Int, cacheRead: Int, reasoning: Int, cost: Double, bestConfidence: UsageProvenanceConfidence, bestMethod: UsageProvenanceMethod, hasEstimated: Bool)] = [:]
            for usage in rows {
                let existing = modelData[usage.model]
                let newConfidence = usage.provenanceConfidence
                let newMethod = usage.provenanceMethod
                let bestConfidence: UsageProvenanceConfidence
                let bestMethod: UsageProvenanceMethod
                if let existingRec = existing {
                    bestConfidence = newConfidence > existingRec.bestConfidence ? newConfidence : existingRec.bestConfidence
                    if newConfidence == existingRec.bestConfidence {
                        bestMethod = newMethod.precedence > existingRec.bestMethod.precedence ? newMethod : existingRec.bestMethod
                    } else {
                        bestMethod = newConfidence > existingRec.bestConfidence ? newMethod : existingRec.bestMethod
                    }
                } else {
                    bestConfidence = newConfidence
                    bestMethod = newMethod
                }
                let rowIsEstimated = newConfidence != .exact && newConfidence != .derivedExact
                let existingHasEstimated = existing?.hasEstimated ?? false
                modelData[usage.model] = (
                    (existing?.0 ?? 0) + usage.inputTokens,
                    (existing?.1 ?? 0) + usage.outputTokens,
                    (existing?.2 ?? 0) + usage.cacheCreationTokens,
                    (existing?.3 ?? 0) + usage.cacheReadTokens,
                    (existing?.4 ?? 0) + usage.reasoningTokens,
                    (existing?.5 ?? 0) + usage.cost,
                    bestConfidence,
                    bestMethod,
                    existingHasEstimated || rowIsEstimated
                )
            }

            // Dominant provenance across the credential's rows.
            var dominantConfidence: UsageProvenanceConfidence = .unknown
            var dominantMethod: UsageProvenanceMethod = .unknown
            var bestCostSoFar: Double = 0
            var hasAnyEstimated: Bool = false
            for usage in rows {
                let rowIsEstimated = usage.provenanceConfidence != .exact && usage.provenanceConfidence != .derivedExact
                hasAnyEstimated = hasAnyEstimated || rowIsEstimated
                let weight = usage.cost > 0 ? usage.cost : 0.001
                if usage.provenanceConfidence > dominantConfidence {
                    dominantConfidence = usage.provenanceConfidence
                    dominantMethod = usage.provenanceMethod
                    bestCostSoFar = weight
                } else if usage.provenanceConfidence == dominantConfidence && weight > bestCostSoFar {
                    dominantMethod = usage.provenanceMethod
                    bestCostSoFar = weight
                }
            }

            let modelBreakdown = modelData.map { modelName, data in
                let totalModelTokens = data.0 + data.1 + data.2 + data.3 + data.4
                return ModelUsage(
                    modelName: modelName,
                    inputTokens: data.0,
                    outputTokens: data.1,
                    cacheCreationTokens: data.2,
                    cacheReadTokens: data.3,
                    reasoningTokens: data.4,
                    totalTokens: totalModelTokens,
                    cost: data.5,
                    percentage: totalCost > 0 ? (data.5 / totalCost) * 100 : 0,
                    provenanceConfidence: data.bestConfidence,
                    provenanceMethod: data.bestMethod,
                    hasEstimatedContributions: data.hasEstimated
                )
            }.sorted { $0.cost > $1.cost }

            return CredentialSummary(
                provider: key.provider,
                accountID: key.accountID,
                accountLabel: accountLabel,
                accountSource: accountSource,
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: rows.count,
                modelBreakdown: modelBreakdown,
                provenanceConfidence: dominantConfidence,
                provenanceMethod: dominantMethod,
                hasEstimatedContributions: hasAnyEstimated,
                cacheEfficiency: CacheEfficiency.aggregate(rows)
            )
        }
        .sorted { $0.totalCost > $1.totalCost }
    }


    /// Aggregates `token_usage` rows by `projectName` to power the "Spend by Project" lane.
    /// Mirrors `makeCredentialSummaries` but slices on the project dimension. Free-text
    /// project names are deduplicated by exact match (no case folding) so users see what
    /// the parsers actually wrote.
    static func makeProjectSpendSummaries(from usages: [TokenUsage]) -> [ProjectSpendSummary] {
        var groups: [String: [TokenUsage]] = [:]
        for usage in usages {
            let key = usage.projectName.isEmpty ? "Unattributed" : usage.projectName
            groups[key, default: []].append(usage)
        }

        return groups.compactMap { (projectName, rows) -> ProjectSpendSummary? in
            guard !rows.isEmpty else { return nil }

            let totalCost = rows.reduce(0) { $0 + $1.cost }
            let totalTokens = rows.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = rows.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = rows.reduce(0) { $0 + $1.outputTokens }

            // Provider rollup within this project.
            let byProvider = Dictionary(grouping: rows) { $0.provider }
            let providerBreakdown = byProvider.map { provider, providerRows -> ProviderUsage in
                let providerCost = providerRows.reduce(0) { $0 + $1.cost }
                let providerTokens = providerRows.reduce(0) { $0 + $1.totalTokens }
                return ProviderUsage(
                    provider: provider,
                    sessionCount: providerRows.count,
                    totalTokens: providerTokens,
                    cost: providerCost,
                    percentage: totalCost > 0 ? (providerCost / totalCost) * 100 : 0,
                    cacheEfficiency: CacheEfficiency.aggregate(providerRows)
                )
            }
            .sorted { $0.cost > $1.cost }

            // Model rollup within this project.
            var modelData: [String: (input: Int, output: Int, cacheCreation: Int, cacheRead: Int, reasoning: Int, cost: Double, bestConfidence: UsageProvenanceConfidence, bestMethod: UsageProvenanceMethod, hasEstimated: Bool)] = [:]
            for usage in rows {
                let existing = modelData[usage.model]
                let newConfidence = usage.provenanceConfidence
                let newMethod = usage.provenanceMethod
                let bestConfidence: UsageProvenanceConfidence
                let bestMethod: UsageProvenanceMethod
                if let existingRec = existing {
                    bestConfidence = newConfidence > existingRec.bestConfidence ? newConfidence : existingRec.bestConfidence
                    if newConfidence == existingRec.bestConfidence {
                        bestMethod = newMethod.precedence > existingRec.bestMethod.precedence ? newMethod : existingRec.bestMethod
                    } else {
                        bestMethod = newConfidence > existingRec.bestConfidence ? newMethod : existingRec.bestMethod
                    }
                } else {
                    bestConfidence = newConfidence
                    bestMethod = newMethod
                }
                let rowIsEstimated = newConfidence != .exact && newConfidence != .derivedExact
                let existingHasEstimated = existing?.hasEstimated ?? false
                modelData[usage.model] = (
                    (existing?.0 ?? 0) + usage.inputTokens,
                    (existing?.1 ?? 0) + usage.outputTokens,
                    (existing?.2 ?? 0) + usage.cacheCreationTokens,
                    (existing?.3 ?? 0) + usage.cacheReadTokens,
                    (existing?.4 ?? 0) + usage.reasoningTokens,
                    (existing?.5 ?? 0) + usage.cost,
                    bestConfidence,
                    bestMethod,
                    existingHasEstimated || rowIsEstimated
                )
            }

            // Dominant provenance across this project's rows.
            var dominantConfidence: UsageProvenanceConfidence = .unknown
            var dominantMethod: UsageProvenanceMethod = .unknown
            var bestCostSoFar: Double = 0
            var hasAnyEstimated: Bool = false
            for usage in rows {
                let rowIsEstimated = usage.provenanceConfidence != .exact && usage.provenanceConfidence != .derivedExact
                hasAnyEstimated = hasAnyEstimated || rowIsEstimated
                let weight = usage.cost > 0 ? usage.cost : 0.001
                if usage.provenanceConfidence > dominantConfidence {
                    dominantConfidence = usage.provenanceConfidence
                    dominantMethod = usage.provenanceMethod
                    bestCostSoFar = weight
                } else if usage.provenanceConfidence == dominantConfidence && weight > bestCostSoFar {
                    dominantMethod = usage.provenanceMethod
                    bestCostSoFar = weight
                }
            }

            let modelBreakdown = modelData.map { modelName, data in
                let totalModelTokens = data.0 + data.1 + data.2 + data.3 + data.4
                return ModelUsage(
                    modelName: modelName,
                    inputTokens: data.0,
                    outputTokens: data.1,
                    cacheCreationTokens: data.2,
                    cacheReadTokens: data.3,
                    reasoningTokens: data.4,
                    totalTokens: totalModelTokens,
                    cost: data.5,
                    percentage: totalCost > 0 ? (data.5 / totalCost) * 100 : 0,
                    provenanceConfidence: data.bestConfidence,
                    provenanceMethod: data.bestMethod,
                    hasEstimatedContributions: data.hasEstimated
                )
            }.sorted { $0.cost > $1.cost }

            return ProjectSpendSummary(
                projectName: projectName,
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: rows.count,
                providerBreakdown: providerBreakdown,
                modelBreakdown: modelBreakdown,
                provenanceConfidence: dominantConfidence,
                provenanceMethod: dominantMethod,
                hasEstimatedContributions: hasAnyEstimated,
                cacheEfficiency: CacheEfficiency.aggregate(rows)
            )
        }
        .sorted { $0.totalCost > $1.totalCost }
    }

    static func makeModelSummaries(from usages: [TokenUsage]) -> [ModelSummary] {
        let grouped = Dictionary(grouping: usages) {
            TokenExtractionUtility.normalizeModelKey($0.model)
        }
        return grouped.compactMap { key, modelUsages -> ModelSummary? in
            guard !modelUsages.isEmpty else { return nil }
            let totalCost = modelUsages.reduce(0) { $0 + $1.cost }
            let totalTokens = modelUsages.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = modelUsages.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = modelUsages.reduce(0) { $0 + $1.outputTokens }

            let byProvider = Dictionary(grouping: modelUsages) { $0.provider }
            let providerBreakdown = byProvider.map { provider, pUsages -> ProviderUsage in
                let pCost = pUsages.reduce(0) { $0 + $1.cost }
                let pTokens = pUsages.reduce(0) { $0 + $1.totalTokens }
                return ProviderUsage(
                    provider: provider,
                    sessionCount: pUsages.count,
                    totalTokens: pTokens,
                    cost: pCost,
                    percentage: totalCost > 0 ? (pCost / totalCost) * 100 : 0,
                    cacheEfficiency: CacheEfficiency.aggregate(pUsages)
                )
            }.sorted { $0.cost > $1.cost }

            return ModelSummary(
                modelName: key,
                displayName: TokenExtractionUtility.displayNameForModel(modelUsages.first?.model ?? key),
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: modelUsages.count,
                providerBreakdown: providerBreakdown,
                cacheEfficiency: CacheEfficiency.aggregate(modelUsages)
            )
        }.sorted { $0.totalCost > $1.totalCost }
    }

    private func upsertUsage(_ usage: TokenUsage, in db: Database) throws {
        let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)
        let statement = try db.cachedStatement(
            sql: """
                INSERT INTO token_usage (
                    id, provider, sessionId, projectName, model,
                    inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                    reasoningTokens, totalTokens, cost, startTime, endTime, createdAt,
                    usageSource, sourceDeviceId, sourceDeviceName, isRemote,
                    providerID, providerAccountID, providerAccountLabel, providerAccountSource,
                    provenanceMethod, provenanceConfidence, estimatorVersion
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(provider, sessionId, model, COALESCE(sourceDeviceId, ''), COALESCE(providerAccountID, '')) DO UPDATE SET
                    projectName = excluded.projectName,
                    inputTokens = excluded.inputTokens,
                    outputTokens = excluded.outputTokens,
                    cacheCreationTokens = excluded.cacheCreationTokens,
                    cacheReadTokens = excluded.cacheReadTokens,
                    reasoningTokens = excluded.reasoningTokens,
                    totalTokens = excluded.totalTokens,
                    cost = excluded.cost,
                    startTime = excluded.startTime,
                    endTime = excluded.endTime,
                    createdAt = excluded.createdAt,
                    -- VAL-TOKEN-009: Preserve source identity on equal-confidence upserts.
                    -- Only update usageSource when incoming confidence is strictly higher.
                    usageSource = CASE
                        WHEN
                            CASE excluded.provenanceConfidence
                                WHEN 'exact' THEN 4
                                WHEN 'derived_exact' THEN 3
                                WHEN 'high_confidence_estimate' THEN 2
                                WHEN 'low_confidence_estimate' THEN 1
                                ELSE 0
                            END
                            >
                            CASE token_usage.provenanceConfidence
                                WHEN 'exact' THEN 4
                                WHEN 'derived_exact' THEN 3
                                WHEN 'high_confidence_estimate' THEN 2
                                WHEN 'low_confidence_estimate' THEN 1
                                ELSE 0
                            END
                        THEN excluded.usageSource
                        ELSE token_usage.usageSource
                    END,
                    providerID = excluded.providerID,
                    providerAccountID = excluded.providerAccountID,
                    providerAccountLabel = excluded.providerAccountLabel,
                    providerAccountSource = excluded.providerAccountSource,
                    provenanceMethod = excluded.provenanceMethod,
                    provenanceConfidence = CASE
                        WHEN
                            CASE excluded.provenanceConfidence
                                WHEN 'exact' THEN 4
                                WHEN 'derived_exact' THEN 3
                                WHEN 'high_confidence_estimate' THEN 2
                                WHEN 'low_confidence_estimate' THEN 1
                                ELSE 0
                            END
                            >=
                            CASE token_usage.provenanceConfidence
                                WHEN 'exact' THEN 4
                                WHEN 'derived_exact' THEN 3
                                WHEN 'high_confidence_estimate' THEN 2
                                WHEN 'low_confidence_estimate' THEN 1
                                ELSE 0
                            END
                        THEN excluded.provenanceConfidence
                        ELSE token_usage.provenanceConfidence
                    END,
                    estimatorVersion = excluded.estimatorVersion,
                    syncedAt = NULL
                WHERE
                    CASE excluded.provenanceConfidence
                        WHEN 'exact' THEN 4
                        WHEN 'derived_exact' THEN 3
                        WHEN 'high_confidence_estimate' THEN 2
                        WHEN 'low_confidence_estimate' THEN 1
                        ELSE 0
                    END
                    >=
                    CASE token_usage.provenanceConfidence
                        WHEN 'exact' THEN 4
                        WHEN 'derived_exact' THEN 3
                        WHEN 'high_confidence_estimate' THEN 2
                        WHEN 'low_confidence_estimate' THEN 1
                        ELSE 0
                    END
                    AND (
                        token_usage.projectName != excluded.projectName
                        OR token_usage.inputTokens != excluded.inputTokens
                        OR token_usage.outputTokens != excluded.outputTokens
                        OR token_usage.cacheCreationTokens != excluded.cacheCreationTokens
                        OR token_usage.cacheReadTokens != excluded.cacheReadTokens
                        OR token_usage.reasoningTokens != excluded.reasoningTokens
                        OR token_usage.totalTokens != excluded.totalTokens
                        OR token_usage.cost != excluded.cost
                        OR token_usage.startTime != excluded.startTime
                        OR token_usage.endTime != excluded.endTime
                        OR token_usage.usageSource != excluded.usageSource
                        OR COALESCE(token_usage.providerAccountID, '') != COALESCE(excluded.providerAccountID, '')
                        OR COALESCE(token_usage.providerAccountLabel, '') != COALESCE(excluded.providerAccountLabel, '')
                        OR COALESCE(token_usage.providerAccountSource, '') != COALESCE(excluded.providerAccountSource, '')
                    )
                """,
        )
        try statement.execute(
            arguments: [
                usage.id.uuidString,
                usage.provider.rawValue,
                usage.sessionId,
                usage.projectName,
                usage.model,
                usage.inputTokens,
                usage.outputTokens,
                usage.cacheCreationTokens,
                usage.cacheReadTokens,
                usage.reasoningTokens,
                usage.totalTokens,
                usage.cost,
                usage.startTime,
                usage.endTime,
                usage.createdAt,
                usage.usageSource.rawValue,
                usage.sourceDeviceId,
                usage.sourceDeviceName,
                usage.isRemote ? 1 : 0,
                usage.providerID.rawValue,
                usagePartition,
                usage.providerAccountLabel,
                usage.providerAccountSource?.rawValue,
                usage.provenanceMethod.rawValue,
                usage.provenanceConfidence.rawValue,
                usage.estimatorVersion
            ]
        )
    }

    private static func usagePartitionToken(from rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "acct_sha256_\(hex.prefix(24))"
    }

    private static func decodeUsage(row: Row) -> TokenUsage? {
        guard let idString = row["id"] as? String,
              let id = UUID(uuidString: idString),
              let providerString = row["provider"] as? String,
              let provider = AgentProvider(rawValue: providerString),
              let sessionId = row["sessionId"] as? String,
              let projectName = row["projectName"] as? String,
              let model = row["model"] as? String else { return nil }

        let inputTokens = intValue(row["inputTokens"])
        let outputTokens = intValue(row["outputTokens"])
        let cacheCreationTokens = intValue(row["cacheCreationTokens"])
        let cacheReadTokens = intValue(row["cacheReadTokens"])
        let reasoningTokens = intValue(row["reasoningTokens"])
        let usageSourceRaw = row["usageSource"] as? String
        let usageSource = usageSourceRaw.flatMap { UsageSource(rawValue: $0) } ?? .unknown
        let provenanceMethodRaw = row["provenanceMethod"] as? String
        let provenanceMethod = provenanceMethodRaw.flatMap { UsageProvenanceMethod(rawValue: $0) } ?? .unknown
        let provenanceConfidenceRaw = row["provenanceConfidence"] as? String
        let provenanceConfidence = provenanceConfidenceRaw.flatMap { UsageProvenanceConfidence(rawValue: $0) } ?? .unknown
        let estimatorVersion = row["estimatorVersion"] as? String ?? ""
        let cost = (row["cost"] as? Double) ?? ((row["cost"] as? NSNumber)?.doubleValue) ?? 0
        let startTime = OpenBurnBarDatabase.parseDateValue(row["startTime"])
        let endTime = OpenBurnBarDatabase.parseDateValue(row["endTime"])
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date()
        guard let startTime, let endTime else { return nil }

        let providerID = (row["providerID"] as? String).map(ProviderID.init(rawValue:)) ?? provider.providerID
        let providerAccountSourceRaw = row["providerAccountSource"] as? String

        return TokenUsage(
            id: id,
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime,
            createdAt: createdAt,
            usageSource: usageSource,
            sourceDeviceId: row["sourceDeviceId"] as? String,
            sourceDeviceName: row["sourceDeviceName"] as? String,
            isRemote: intValue(row["isRemote"]) != 0,
            providerID: providerID,
            providerAccountID: row["providerAccountID"] as? String,
            providerAccountLabel: row["providerAccountLabel"] as? String,
            providerAccountSource: providerAccountSourceRaw.flatMap { ProviderAccountStorageScope(rawValue: $0) },
            provenanceMethod: provenanceMethod,
            provenanceConfidence: provenanceConfidence,
            estimatorVersion: estimatorVersion
        )
    }

    fileprivate static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    fileprivate static func doubleValue(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return 0
    }

    private static func fetchUsageRows(
        db: Database,
        dateRange: ClosedRange<Date>?,
        limit: Int
    ) throws -> [TokenUsage] {
        let predicate = dateRangePredicate(dateRange)
        var arguments = predicate.arguments
        arguments += StatementArguments([limit])
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM token_usage\(predicate.whereSQL) ORDER BY startTime DESC LIMIT ?",
            arguments: arguments
        )
        return rows.compactMap(Self.decodeUsage)
    }

    private static func fetchWindowSummary(
        db: Database,
        dateRange: ClosedRange<Date>?,
        loadedUsageLimit: Int
    ) throws -> DashboardUsageWindowSummary {
        let loadedUsages = try fetchUsageRows(db: db, dateRange: dateRange, limit: loadedUsageLimit)
        let aggregateRows = try fetchUsageAggregateRows(db: db, dateRange: dateRange)
        let totals = usageTotals(from: aggregateRows)

        return DashboardUsageWindowSummary(
            usages: loadedUsages,
            totalCost: totals.cost,
            totalTokens: totals.tokens,
            sessionCount: totals.sessionCount,
            activeProviderCount: Set(aggregateRows.map(\.provider)).count,
            providerSummaries: Self.makeProviderSummaries(fromAggregateRows: aggregateRows),
            modelSummaries: Self.makeModelSummaries(fromAggregateRows: aggregateRows),
            credentialSummaries: Self.makeCredentialSummaries(from: loadedUsages),
            projectSpendSummaries: Self.makeProjectSpendSummaries(from: loadedUsages),
            cacheEfficiency: CacheEfficiency(
                inputTokens: totals.inputTokens,
                cacheCreationTokens: totals.cacheCreationTokens,
                cacheReadTokens: totals.cacheReadTokens
            )
        )
    }

    private static func fetchUsageAggregateRows(
        db: Database,
        dateRange: ClosedRange<Date>?
    ) throws -> [UsageAggregateRow] {
        let predicate = dateRangePredicate(dateRange)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT provider,
                       model,
                       provenanceConfidence,
                       provenanceMethod,
                       COUNT(*) AS sessionCount,
                       COALESCE(SUM(inputTokens), 0) AS inputTokens,
                       COALESCE(SUM(outputTokens), 0) AS outputTokens,
                       COALESCE(SUM(cacheCreationTokens), 0) AS cacheCreationTokens,
                       COALESCE(SUM(cacheReadTokens), 0) AS cacheReadTokens,
                       COALESCE(SUM(reasoningTokens), 0) AS reasoningTokens,
                       COALESCE(SUM(totalTokens), 0) AS totalTokens,
                       COALESCE(SUM(cost), 0) AS cost
                FROM token_usage
                \(predicate.whereSQL)
                GROUP BY provider, model, provenanceConfidence, provenanceMethod
                """,
            arguments: predicate.arguments
        )
        return rows.compactMap(UsageAggregateRow.init(row:))
    }

    private static func fetchUsageTotals(
        db: Database,
        dateRange: ClosedRange<Date>?
    ) throws -> UsageTotals {
        let predicate = dateRangePredicate(dateRange)
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) AS sessionCount,
                       COALESCE(SUM(inputTokens), 0) AS inputTokens,
                       COALESCE(SUM(outputTokens), 0) AS outputTokens,
                       COALESCE(SUM(cacheCreationTokens), 0) AS cacheCreationTokens,
                       COALESCE(SUM(cacheReadTokens), 0) AS cacheReadTokens,
                       COALESCE(SUM(reasoningTokens), 0) AS reasoningTokens,
                       COALESCE(SUM(totalTokens), 0) AS totalTokens,
                       COALESCE(SUM(cost), 0) AS cost
                FROM token_usage
                \(predicate.whereSQL)
                """,
            arguments: predicate.arguments
        )
        return UsageTotals(
            sessionCount: intValue(row?["sessionCount"]),
            inputTokens: intValue(row?["inputTokens"]),
            outputTokens: intValue(row?["outputTokens"]),
            cacheCreationTokens: intValue(row?["cacheCreationTokens"]),
            cacheReadTokens: intValue(row?["cacheReadTokens"]),
            reasoningTokens: intValue(row?["reasoningTokens"]),
            tokens: intValue(row?["totalTokens"]),
            cost: doubleValue(row?["cost"])
        )
    }

    private static func usageTotals(from rows: [UsageAggregateRow]) -> UsageTotals {
        rows.reduce(into: UsageTotals.empty) { totals, row in
            totals.sessionCount += row.sessionCount
            totals.inputTokens += row.inputTokens
            totals.outputTokens += row.outputTokens
            totals.cacheCreationTokens += row.cacheCreationTokens
            totals.cacheReadTokens += row.cacheReadTokens
            totals.reasoningTokens += row.reasoningTokens
            totals.tokens += row.totalTokens
            totals.cost += row.cost
        }
    }

    private static func fetchDistinctUsageDayCount(db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT DATE(startTime)) FROM token_usage") ?? 0
    }

    private static func fetchDailySummaries(db: Database) throws -> [DailyUsageSummary] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT DATE(startTime) AS usageDay,
                   provider,
                   model,
                   COUNT(*) AS sessionCount,
                   COALESCE(SUM(inputTokens), 0) AS inputTokens,
                   COALESCE(SUM(outputTokens), 0) AS outputTokens,
                   COALESCE(SUM(cacheCreationTokens), 0) AS cacheCreationTokens,
                   COALESCE(SUM(cacheReadTokens), 0) AS cacheReadTokens,
                   COALESCE(SUM(totalTokens), 0) AS totalTokens,
                   COALESCE(SUM(cost), 0) AS cost
            FROM token_usage
            GROUP BY usageDay, provider, model
            ORDER BY usageDay DESC
            """)

        var accumulators: [String: DailySummaryAccumulator] = [:]
        for row in rows {
            guard let dayString = row["usageDay"] as? String,
                  let providerRaw = row["provider"] as? String,
                  let provider = AgentProvider(rawValue: providerRaw),
                  let model = row["model"] as? String else { continue }

            accumulators[dayString, default: DailySummaryAccumulator(dayString: dayString)]
                .record(row: row, provider: provider, model: model)
        }

        return accumulators.values
            .compactMap(\.summary)
            .sorted { $0.date > $1.date }
    }

    private static func dateRangePredicate(_ dateRange: ClosedRange<Date>?) -> (whereSQL: String, arguments: StatementArguments) {
        guard let dateRange else {
            return ("", StatementArguments())
        }
        let lowerBound = OpenBurnBarDatabase.sqliteDateString(dateRange.lowerBound)
        let upperBound = OpenBurnBarDatabase.sqliteDateString(dateRange.upperBound)
        return (
            " WHERE ((startTime <= ? AND endTime >= ?) OR (endTime <= ? AND startTime >= ?))",
            StatementArguments([
                upperBound,
                lowerBound,
                upperBound,
                lowerBound
            ])
        )
    }

    private static func makeProviderSummaries(fromAggregateRows rows: [UsageAggregateRow]) -> [ProviderSummary] {
        var providers: [AgentProvider: ProviderSummaryAccumulator] = [:]
        for row in rows {
            providers[row.provider, default: ProviderSummaryAccumulator()].record(row)
        }
        return providers.compactMap { provider, accumulator in
            accumulator.summary(for: provider)
        }
        .sorted { $0.totalCost > $1.totalCost }
    }

    private static func makeModelSummaries(fromAggregateRows rows: [UsageAggregateRow]) -> [ModelSummary] {
        var models: [String: ModelSummaryAccumulator] = [:]
        for row in rows {
            let normalized = TokenExtractionUtility.normalizeModelKey(row.model)
            models[normalized, default: ModelSummaryAccumulator(modelName: normalized)].record(row)
        }
        return models.values
            .map(\.summary)
            .sorted { $0.totalCost > $1.totalCost }
    }

    // MARK: - Org Rollup

    /// Cross-seat spend rollup grouped by user, project, credential, or provider.
    /// Reuses the same `token_usage` table that `CloudSyncService` already syncs from
    /// every seat — `sourceDeviceID` / `sourceDeviceName` distinguish per-seat rows.
    func fetchOrgRollup(groupBy: OrgGroupBy, period: BudgetPeriod) throws -> [OrgRollupRow] {
        let windowStart = period.windowStart()
        let column: String
        switch groupBy {
        case .user:       column = "COALESCE(sourceDeviceName, sourceDeviceID, 'local')"
        case .project:    column = "COALESCE(NULLIF(projectName, ''), 'Unassigned')"
        case .credential: column = "COALESCE(NULLIF(providerAccountLabel, ''), NULLIF(providerAccountID, ''), providerID || ' default')"
        case .provider:   column = "provider"
        }

        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        if let windowStart {
            clauses.append("startTime >= ?")
            args.append(windowStart)
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")

        let sql = """
            SELECT \(column) AS label,
                   COALESCE(SUM(cost), 0) AS totalCost,
                   COALESCE(SUM(totalTokens), 0) AS totalTokens,
                   COUNT(DISTINCT sessionId) AS sessionCount,
                   COUNT(DISTINCT COALESCE(sourceDeviceID, 'local')) AS deviceCount
            FROM token_usage
            \(whereSQL)
            GROUP BY \(column)
            ORDER BY totalCost DESC
            LIMIT 100
        """

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row -> OrgRollupRow? in
                guard let label = row["label"] as? String else { return nil }
                let totalCost = (row["totalCost"] as? Double) ?? 0
                let totalTokens = (row["totalTokens"] as? Double) ?? 0
                let sessionCount = Int(row["sessionCount"] as? Int64 ?? 0)
                let deviceCount = Int(row["deviceCount"] as? Int64 ?? 0)
                return OrgRollupRow(
                    label: label,
                    totalCost: totalCost,
                    totalTokens: totalTokens,
                    sessionCount: sessionCount,
                    deviceCount: deviceCount
                )
            }
        }
    }
}

struct ProviderRunCostTotals: Equatable, Sendable {
    let sessionCount: Int
    let totalTokens: Int
    let totalCost: Double
}

private struct UsageTotals {
    var sessionCount: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var reasoningTokens: Int
    var tokens: Int
    var cost: Double

    static let empty = UsageTotals(
        sessionCount: 0,
        inputTokens: 0,
        outputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        reasoningTokens: 0,
        tokens: 0,
        cost: 0
    )
}

private struct UsageAggregateRow {
    let provider: AgentProvider
    let model: String
    let provenanceConfidence: UsageProvenanceConfidence
    let provenanceMethod: UsageProvenanceMethod
    let sessionCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let cost: Double

    init?(row: Row) {
        guard let providerRaw = row["provider"] as? String,
              let provider = AgentProvider(rawValue: providerRaw),
              let model = row["model"] as? String else { return nil }
        self.provider = provider
        self.model = model
        provenanceConfidence = (row["provenanceConfidence"] as? String)
            .flatMap { UsageProvenanceConfidence(rawValue: $0) } ?? .unknown
        provenanceMethod = (row["provenanceMethod"] as? String)
            .flatMap { UsageProvenanceMethod(rawValue: $0) } ?? .unknown
        sessionCount = UsageStore.intValue(row["sessionCount"])
        inputTokens = UsageStore.intValue(row["inputTokens"])
        outputTokens = UsageStore.intValue(row["outputTokens"])
        cacheCreationTokens = UsageStore.intValue(row["cacheCreationTokens"])
        cacheReadTokens = UsageStore.intValue(row["cacheReadTokens"])
        reasoningTokens = UsageStore.intValue(row["reasoningTokens"])
        totalTokens = UsageStore.intValue(row["totalTokens"])
        cost = UsageStore.doubleValue(row["cost"])
    }
}

private struct ProviderSummaryAccumulator {
    var totalCost: Double = 0
    var totalTokens = 0
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var sessionCount = 0
    var modelData: [String: ModelUsageAccumulator] = [:]
    var dominantConfidence: UsageProvenanceConfidence = .unknown
    var dominantMethod: UsageProvenanceMethod = .unknown
    var bestCostSoFar: Double = 0
    var hasAnyEstimated = false

    mutating func record(_ row: UsageAggregateRow) {
        totalCost += row.cost
        totalTokens += row.totalTokens
        totalInputTokens += row.inputTokens
        totalOutputTokens += row.outputTokens
        cacheCreationTokens += row.cacheCreationTokens
        cacheReadTokens += row.cacheReadTokens
        sessionCount += row.sessionCount
        modelData[row.model, default: ModelUsageAccumulator(modelName: row.model)].record(row)

        let estimated = row.provenanceConfidence != .exact && row.provenanceConfidence != .derivedExact
        hasAnyEstimated = hasAnyEstimated || estimated
        let weight = row.cost > 0 ? row.cost : 0.001
        if row.provenanceConfidence > dominantConfidence {
            dominantConfidence = row.provenanceConfidence
            dominantMethod = row.provenanceMethod
            bestCostSoFar = weight
        } else if row.provenanceConfidence == dominantConfidence && weight > bestCostSoFar {
            dominantMethod = row.provenanceMethod
            bestCostSoFar = weight
        }
    }

    func summary(for provider: AgentProvider) -> ProviderSummary? {
        guard sessionCount > 0 else { return nil }
        return ProviderSummary(
            provider: provider,
            totalCost: totalCost,
            totalTokens: totalTokens,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            sessionCount: sessionCount,
            modelBreakdown: modelData.values
                .map { $0.modelUsage(providerTotalCost: totalCost) }
                .sorted { $0.cost > $1.cost },
            provenanceConfidence: dominantConfidence,
            provenanceMethod: dominantMethod,
            hasEstimatedContributions: hasAnyEstimated,
            cacheEfficiency: CacheEfficiency(
                inputTokens: totalInputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens
            )
        )
    }
}

private struct ModelUsageAccumulator {
    let modelName: String
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0
    var reasoning = 0
    var totalTokens = 0
    var cost: Double = 0
    var bestConfidence: UsageProvenanceConfidence = .unknown
    var bestMethod: UsageProvenanceMethod = .unknown
    var hasEstimated = false

    mutating func record(_ row: UsageAggregateRow) {
        input += row.inputTokens
        output += row.outputTokens
        cacheCreation += row.cacheCreationTokens
        cacheRead += row.cacheReadTokens
        reasoning += row.reasoningTokens
        totalTokens += row.totalTokens
        cost += row.cost
        hasEstimated = hasEstimated || (row.provenanceConfidence != .exact && row.provenanceConfidence != .derivedExact)
        if row.provenanceConfidence > bestConfidence {
            bestConfidence = row.provenanceConfidence
            bestMethod = row.provenanceMethod
        } else if row.provenanceConfidence == bestConfidence,
                  row.provenanceMethod.precedence > bestMethod.precedence {
            bestMethod = row.provenanceMethod
        }
    }

    func modelUsage(providerTotalCost: Double) -> ModelUsage {
        ModelUsage(
            modelName: modelName,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            totalTokens: totalTokens,
            cost: cost,
            percentage: providerTotalCost > 0 ? (cost / providerTotalCost) * 100 : 0,
            provenanceConfidence: bestConfidence,
            provenanceMethod: bestMethod,
            hasEstimatedContributions: hasEstimated
        )
    }
}

private struct ModelSummaryAccumulator {
    let modelName: String
    var displayModelName: String?
    var totalCost: Double = 0
    var totalTokens = 0
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var sessionCount = 0
    var providerData: [AgentProvider: ProviderUsageAccumulator] = [:]

    mutating func record(_ row: UsageAggregateRow) {
        if displayModelName == nil {
            displayModelName = row.model
        }
        totalCost += row.cost
        totalTokens += row.totalTokens
        totalInputTokens += row.inputTokens
        totalOutputTokens += row.outputTokens
        cacheCreationTokens += row.cacheCreationTokens
        cacheReadTokens += row.cacheReadTokens
        sessionCount += row.sessionCount
        providerData[row.provider, default: ProviderUsageAccumulator(provider: row.provider)].record(row)
    }

    var summary: ModelSummary {
        ModelSummary(
            modelName: modelName,
            displayName: TokenExtractionUtility.displayNameForModel(displayModelName ?? modelName),
            totalCost: totalCost,
            totalTokens: totalTokens,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            sessionCount: sessionCount,
            providerBreakdown: providerData.values
                .map { $0.providerUsage(modelTotalCost: totalCost) }
                .sorted { $0.cost > $1.cost },
            cacheEfficiency: CacheEfficiency(
                inputTokens: totalInputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens
            )
        )
    }
}

private struct ProviderUsageAccumulator {
    let provider: AgentProvider
    var sessionCount = 0
    var totalTokens = 0
    var cost: Double = 0
    var inputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0

    mutating func record(_ row: UsageAggregateRow) {
        sessionCount += row.sessionCount
        totalTokens += row.totalTokens
        cost += row.cost
        inputTokens += row.inputTokens
        cacheCreationTokens += row.cacheCreationTokens
        cacheReadTokens += row.cacheReadTokens
    }

    func providerUsage(modelTotalCost: Double) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            sessionCount: sessionCount,
            totalTokens: totalTokens,
            cost: cost,
            percentage: modelTotalCost > 0 ? (cost / modelTotalCost) * 100 : 0,
            cacheEfficiency: CacheEfficiency(
                inputTokens: inputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens
            )
        )
    }
}

private struct DailySummaryAccumulator {
    let dayString: String
    var providerCosts: [AgentProvider: Double] = [:]
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var totalCacheCreationTokens = 0
    var totalCacheReadTokens = 0
    var totalTokens = 0
    var totalCost: Double = 0
    var sessionCount = 0
    var models: Set<String> = []

    mutating func record(row: Row, provider: AgentProvider, model: String) {
        let cost = UsageStore.doubleValue(row["cost"])
        providerCosts[provider, default: 0] += cost
        totalInputTokens += UsageStore.intValue(row["inputTokens"])
        totalOutputTokens += UsageStore.intValue(row["outputTokens"])
        totalCacheCreationTokens += UsageStore.intValue(row["cacheCreationTokens"])
        totalCacheReadTokens += UsageStore.intValue(row["cacheReadTokens"])
        totalTokens += UsageStore.intValue(row["totalTokens"])
        totalCost += cost
        sessionCount += UsageStore.intValue(row["sessionCount"])
        models.insert(model)
    }

    var summary: DailyUsageSummary? {
        guard let date = Self.dayFormatter.date(from: dayString) else { return nil }
        return DailyUsageSummary(
            date: date,
            provider: providerCosts.max { $0.value < $1.value }?.key ?? .factory,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCacheCreationTokens: totalCacheCreationTokens,
            totalCacheReadTokens: totalCacheReadTokens,
            totalTokens: totalTokens,
            totalCost: totalCost,
            sessionCount: sessionCount,
            models: Array(models)
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
