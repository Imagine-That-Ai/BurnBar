import Foundation
import GRDB
import OpenBurnBarCore

extension UsageStore {
    // MARK: - Refresh

    func fetchAllUsage() async throws -> [TokenUsage] {
        try await fetchRecentUsage(limit: Int.max)
    }

    func fetchRecentUsage(limit: Int) async throws -> [TokenUsage] {
        try await dbQueue.read { db -> [TokenUsage] in
            try Self.fetchUsageRows(db: db, dateRange: nil, limit: limit)
        }
    }

    func fetchUsage(in dateRange: ClosedRange<Date>, limit: Int) async throws -> [TokenUsage] {
        try await dbQueue.read { db -> [TokenUsage] in
            try Self.fetchUsageRows(db: db, dateRange: dateRange, limit: limit)
        }
    }

    /// Fetches only the scalar totals needed by dashboard comparison telemetry.
    /// The query stays on the database worker and does not decode or materialize
    /// any usage rows, which keeps large windows off the main actor.
    func fetchUsageTotals(in dateRange: ClosedRange<Date>?) async throws -> UsageTotals {
        try await dbQueue.read { db in
            try Self.fetchUsageTotals(db: db, dateRange: dateRange)
        }
    }

    func fetchUsageCostBreakdown(in dateRange: ClosedRange<Date>, limit: Int = 20) async throws -> UsageCostBreakdown {
        try await dbQueue.read { db in
            let aggregateRows = try Self.fetchUsageAggregateRows(db: db, dateRange: dateRange)
            let totals = Self.usageTotals(from: aggregateRows)
            return UsageCostBreakdown(
                sessionCount: totals.sessionCount,
                totalTokens: totals.tokens,
                totalCost: totals.cost,
                modelCosts: Self.costBuckets(from: aggregateRows, label: \.model, limit: limit),
                projectCosts: try Self.fetchProjectCostBuckets(db: db, dateRange: dateRange, limit: limit)
            )
        }
    }

    func fetchDashboardUsageSnapshot(loadedUsageLimit: Int) async throws -> DashboardUsageSnapshot {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)

        return try await dbQueue.read { db in
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
    func providerRunCostTotals(in dateRange: ClosedRange<Date>?) async throws -> [AgentProvider: ProviderRunCostTotals] {
        try await dbQueue.read { db in
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
}
