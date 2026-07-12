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

    /// Per-credential all-time cost totals for billing drift detection.
    ///
    /// Replaces the previous approach of materializing EVERY `token_usage`
    /// row into memory each refresh tick just to reduce per-credential cost
    /// sums. One `GROUP BY` query returns ~#credentials rows instead.
    ///
    /// Key format matches the in-memory grouping in
    /// `BillingRefreshCoordinator`: `"providerID:providerAccountID"` with
    /// `"default"` when the account id is NULL. The `providerID` fallback for
    /// NULL columns mirrors `decodeUsage` (`provider.providerID`), and rows
    /// whose provider fails to decode are skipped, exactly like the decoded
    /// row path was.
    func driftCredentialCostTotals() async throws -> [String: Double] {
        try await dbQueue.read { db -> [String: Double] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT provider,
                           providerID,
                           providerAccountID,
                           COALESCE(SUM(cost), 0) AS cost
                    FROM token_usage
                    GROUP BY provider, providerID, providerAccountID
                    """
            )
            var totals: [String: Double] = [:]
            for row in rows {
                guard let providerRaw = row["provider"] as? String,
                      let provider = AgentProvider(rawValue: providerRaw) else { continue }
                let providerID = (row["providerID"] as? String).map(ProviderID.init(rawValue:))
                    ?? provider.providerID
                let accountID = row["providerAccountID"] as? String ?? "default"
                totals["\(providerID.rawValue):\(accountID)", default: 0] += Self.doubleValue(row["cost"])
            }
            return totals
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
