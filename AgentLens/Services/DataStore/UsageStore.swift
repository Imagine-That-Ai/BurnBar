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
            try upsertUsage(usage, in: db)
        }
    }

    func insert(_ newUsages: [TokenUsage]) throws {
        guard !newUsages.isEmpty else { return }
        try dbQueue.write { db in
            for usage in newUsages {
                try deleteKimiRequestIDModelRows(replacedBy: usage, in: db)
                try upsertUsage(usage, in: db)
            }
        }
    }

    private func deleteKimiRequestIDModelRows(replacedBy usage: TokenUsage, in db: Database) throws {
        guard usage.provider == .kimi,
              !Self.isKimiRequestIDModel(usage.model) else { return }
        let persistedAccountKey = Self.persistedNonSecretAccountKey(fromRawAccountIdentifier: usage.providerAccountID)

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
                persistedAccountKey,
            ]
        )
    }

    private static func isKimiRequestIDModel(_ model: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("chatcmpl-")
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
            let persistedAccountKey = Self.persistedNonSecretAccountKey(fromRawAccountIdentifier: usage.providerAccountID)
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
                    persistedAccountKey,
                    usage.providerAccountLabel,
                    usage.providerAccountSource?.rawValue,
                    usage.provenanceMethod.rawValue,
                    usage.provenanceConfidence.rawValue,
                    usage.estimatorVersion
                ]
            )
        }
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
        let persistedAccountKey = Self.persistedNonSecretAccountKey(fromRawAccountIdentifier: usage.providerAccountID)
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
                persistedAccountKey,
                usage.providerAccountLabel,
                usage.providerAccountSource?.rawValue,
                usage.provenanceMethod.rawValue,
                usage.provenanceConfidence.rawValue,
                usage.estimatorVersion
            ]
        )
    }

    private static func persistedNonSecretAccountKey(fromRawAccountIdentifier rawValue: String?) -> String? {
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
        return (
            " WHERE ((startTime <= ? AND endTime >= ?) OR (endTime <= ? AND startTime >= ?))",
            StatementArguments([
                dateRange.upperBound,
                dateRange.lowerBound,
                dateRange.upperBound,
                dateRange.lowerBound
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
