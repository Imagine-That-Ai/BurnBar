import Foundation
import GRDB
import OpenBurnBarCore

extension UsageStore {
    static func fetchUsageRows( // pure-move: was private
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

    static func fetchWindowSummary( // pure-move: was private
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

    static func fetchUsageAggregateRows( // pure-move: was private
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

    static func fetchUsageTotals( // pure-move: was private
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

    static func usageTotals(from rows: [UsageAggregateRow]) -> UsageTotals { // pure-move: was private
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

    static func fetchProjectCostBuckets( // pure-move: was private
        db: Database,
        dateRange: ClosedRange<Date>?,
        limit: Int
    ) throws -> [UsageCostBucket] {
        guard limit > 0 else { return [] }
        let predicate = dateRangePredicate(dateRange)
        var arguments = predicate.arguments
        arguments += StatementArguments([limit])
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT COALESCE(NULLIF(projectName, ''), 'Unassigned') AS label,
                       COALESCE(SUM(cost), 0) AS cost
                FROM token_usage
                \(predicate.whereSQL)
                GROUP BY label
                ORDER BY cost DESC, label ASC
                LIMIT ?
                """,
            arguments: arguments
        )
        return rows.compactMap { row in
            guard let label = row["label"] as? String else { return nil }
            return UsageCostBucket(label: label, cost: doubleValue(row["cost"]))
        }
    }

    static func costBuckets( // pure-move: was private
        from rows: [UsageAggregateRow],
        label: KeyPath<UsageAggregateRow, String>,
        limit: Int
    ) -> [UsageCostBucket] {
        guard limit > 0 else { return [] }
        let totals = rows.reduce(into: [String: Double]()) { partial, row in
            partial[row[keyPath: label], default: 0] += row.cost
        }
        let sortedBuckets = totals
            .map { UsageCostBucket(label: $0.key, cost: $0.value) }
            .sorted {
                if $0.cost == $1.cost { return $0.label < $1.label }
                return $0.cost > $1.cost
            }
        return Array(sortedBuckets.prefix(limit))
    }

    static func fetchDistinctUsageDayCount(db: Database) throws -> Int { // pure-move: was private
        try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT DATE(startTime)) FROM token_usage") ?? 0
    }

    static func fetchDailySummaries(db: Database) throws -> [DailyUsageSummary] { // pure-move: was private
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

    static func dateRangePredicate(_ dateRange: ClosedRange<Date>?) -> (whereSQL: String, arguments: StatementArguments) { // pure-move: was private
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
}
