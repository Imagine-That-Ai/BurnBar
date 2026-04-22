import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - UsageStore

/// Token-usage CRUD, sync helpers, refresh reads, and provider/model summary builders.
final class UsageStore: Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Insert

    func insert(_ usage: TokenUsage) throws {
        try dbQueue.write { db in
            try upsertUsage(usage, in: db)
        }
    }

    func insert(_ newUsages: [TokenUsage]) throws {
        guard !newUsages.isEmpty else { return }
        try dbQueue.write { db in
            for usage in newUsages {
                try upsertUsage(usage, in: db)
            }
        }
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
            try db.execute(
                sql: """
                    INSERT INTO token_usage (
                        id, provider, sessionId, projectName, model,
                        inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                        reasoningTokens, totalTokens, cost, startTime, endTime, createdAt,
                        usageSource, sourceDeviceId, sourceDeviceName, isRemote, syncedAt,
                        provenanceMethod, provenanceConfidence, estimatorVersion
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                    ON CONFLICT(provider, sessionId, model, COALESCE(sourceDeviceId, '')) DO UPDATE SET
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
                    usage.sourceDeviceId, usage.sourceDeviceName, Date(),
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
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM token_usage ORDER BY startTime DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.compactMap { row -> TokenUsage? in
                guard let idString = row["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let providerString = row["provider"] as? String,
                      let provider = AgentProvider(rawValue: providerString),
                      let sessionId = row["sessionId"] as? String,
                      let projectName = row["projectName"] as? String,
                      let model = row["model"] as? String else {
                    return nil
                }

                let inputTokens = (row["inputTokens"] as? Int) ?? Int(row["inputTokens"] as? Int64 ?? 0)
                let outputTokens = (row["outputTokens"] as? Int) ?? Int(row["outputTokens"] as? Int64 ?? 0)
                let cacheCreationTokens = (row["cacheCreationTokens"] as? Int) ?? Int(row["cacheCreationTokens"] as? Int64 ?? 0)
                let cacheReadTokens = (row["cacheReadTokens"] as? Int) ?? Int(row["cacheReadTokens"] as? Int64 ?? 0)
                let reasoningTokens = (row["reasoningTokens"] as? Int) ?? Int(row["reasoningTokens"] as? Int64 ?? 0)
                let usageSourceRaw = row["usageSource"] as? String
                let usageSource = usageSourceRaw.flatMap { UsageSource(rawValue: $0) } ?? .unknown

                let provenanceMethodRaw = row["provenanceMethod"] as? String
                let provenanceMethod = provenanceMethodRaw.flatMap { UsageProvenanceMethod(rawValue: $0) } ?? .unknown
                let provenanceConfidenceRaw = row["provenanceConfidence"] as? String
                let provenanceConfidence = provenanceConfidenceRaw.flatMap { UsageProvenanceConfidence(rawValue: $0) } ?? .unknown
                let estimatorVersion = row["estimatorVersion"] as? String ?? ""

                let cost = (row["cost"] as? Double)
                    ?? ((row["cost"] as? NSNumber)?.doubleValue)
                    ?? 0

                let startTime = OpenBurnBarDatabase.parseDateValue(row["startTime"])
                let endTime = OpenBurnBarDatabase.parseDateValue(row["endTime"])
                let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date()
                guard let startTime, let endTime else { return nil }

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
                    isRemote: ((row["isRemote"] as? Int) ?? Int(row["isRemote"] as? Int64 ?? 0)) != 0,
                    provenanceMethod: provenanceMethod,
                    provenanceConfidence: provenanceConfidence,
                    estimatorVersion: estimatorVersion
                )
            }
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
            return rows.compactMap { row -> TokenUsage? in
                guard let idString = row["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let providerString = row["provider"] as? String,
                      let provider = AgentProvider(rawValue: providerString),
                      let sessionId = row["sessionId"] as? String,
                      let projectName = row["projectName"] as? String,
                      let model = row["model"] as? String else { return nil }

                let inputTokens = (row["inputTokens"] as? Int) ?? Int(row["inputTokens"] as? Int64 ?? 0)
                let outputTokens = (row["outputTokens"] as? Int) ?? Int(row["outputTokens"] as? Int64 ?? 0)
                let cacheCreationTokens = (row["cacheCreationTokens"] as? Int) ?? Int(row["cacheCreationTokens"] as? Int64 ?? 0)
                let cacheReadTokens = (row["cacheReadTokens"] as? Int) ?? Int(row["cacheReadTokens"] as? Int64 ?? 0)
                let reasoningTokens = (row["reasoningTokens"] as? Int) ?? Int(row["reasoningTokens"] as? Int64 ?? 0)
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
                    provenanceMethod: provenanceMethod,
                    provenanceConfidence: provenanceConfidence,
                    estimatorVersion: estimatorVersion
                )
            }
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
                hasEstimatedContributions: hasAnyEstimated
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
                    percentage: totalCost > 0 ? (pCost / totalCost) * 100 : 0
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
                providerBreakdown: providerBreakdown
            )
        }.sorted { $0.totalCost > $1.totalCost }
    }

    private func upsertUsage(_ usage: TokenUsage, in db: Database) throws {
        let statement = try db.cachedStatement(
            sql: """
                INSERT INTO token_usage (
                    id, provider, sessionId, projectName, model,
                    inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                    reasoningTokens, totalTokens, cost, startTime, endTime, createdAt,
                    usageSource, sourceDeviceId, sourceDeviceName, isRemote,
                    provenanceMethod, provenanceConfidence, estimatorVersion
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(provider, sessionId, model, COALESCE(sourceDeviceId, '')) DO UPDATE SET
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
                usage.provenanceMethod.rawValue,
                usage.provenanceConfidence.rawValue,
                usage.estimatorVersion
            ]
        )
    }
}
