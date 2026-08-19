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

    /// Index-backed start-time window for bounded background work.
    ///
    /// Daily digest and daemon activity export need recent sessions, not the
    /// dashboard's overlap semantics or multi-window aggregate snapshot.
    func fetchUsage(startingIn dateRange: Range<Date>, limit: Int) async throws -> [TokenUsage] {
        try await dbQueue.read { db -> [TokenUsage] in
            try Self.fetchUsageRows(db: db, startingIn: dateRange, limit: limit)
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

    func fetchDashboardUsageSnapshot(
        loadedUsageLimit: Int,
        now: Date = Date()
    ) async throws -> DashboardUsageSnapshot {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)

        return try await dbQueue.read { db in
            let windows = TimeRange.allCases.map { ($0, $0.dateRange(now: now)) }
            let aggregatesByRange = try Self.fetchUsageAggregateRowsByTimeRange(
                db: db,
                windows: windows
            )
            // One covering scan (newest `loadedUsageLimit` rows, all-time).
            // Bounded windows previously each `SELECT * … LIMIT N` — five
            // full-row decodes — even though provider/model totals already
            // come from the GROUP BY fan-out. Session lists filter this
            // newest-N set. Credential / project summaries fold from the
            // same identity `GROUP BY` as provider/model (including a
            // long-runner whose `startTime` is older than the newest N).
            // Window **totals** still use intersection SQL and stay exact.
            let coveringUsages = try Self.fetchUsageRows(
                db: db,
                dateRange: nil,
                limit: loadedUsageLimit
            )
            var windowSummaries: [TimeRange: DashboardUsageWindowSummary] = [:]
            for (timeRange, dateRange) in windows {
                let windowCovering: [TokenUsage]
                if let dateRange {
                    windowCovering = coveringUsages.filter { $0.intersects(dateRange: dateRange) }
                } else {
                    windowCovering = coveringUsages
                }
                windowSummaries[timeRange] = Self.makeWindowSummary(
                    loadedUsages: windowCovering,
                    aggregateRows: aggregatesByRange[timeRange] ?? []
                )
            }

            let today = windowSummaries[.today] ?? .empty

            let dayTotals = try Self.fetchOverlappingDayCostAndTokens(
                db: db,
                calendar: calendar,
                todayStart: todayStart,
                offsets: 0...7
            )
            let last7DayCosts = (0..<7).reversed().map { offset in
                dayTotals[offset]?.cost ?? 0
            }
            let last7DayTokenTotals = (0..<7).reversed().map { offset in
                dayTotals[offset]?.tokens ?? 0
            }
            let rollingDailyTotal = (1...7).reduce(0.0) { partial, offset in
                partial + (dayTotals[offset]?.cost ?? 0)
            }

            let dailySummaries = try Self.fetchDailySummaries(db: db)
            return DashboardUsageSnapshot(
                loadedUsages: coveringUsages,
                windowSummaries: windowSummaries,
                rollingDailyAverage: rollingDailyTotal / 7,
                distinctUsageDayCount: dailySummaries.count,
                last7DayCosts: last7DayCosts,
                last7DayTokenTotals: last7DayTokenTotals,
                dailySummaries: dailySummaries,
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

    /// Lightweight per-provider totals for several overlapping time windows.
    ///
    /// Smart Hub needs the selected period plus rolling 5-hour and 7-day
    /// burn-rate windows. Running the single-window query once per period
    /// caused three encrypted table reads every 30 seconds on large databases.
    /// This variant bounds one scan to the widest requested window and fans
    /// each row into every matching window inside that same SQL statement.
    ///
    /// Results preserve the input order. An empty input performs no database
    /// work and returns an empty array.
    func providerRunCostTotals(
        in dateRanges: [ClosedRange<Date>]
    ) async throws -> [[AgentProvider: ProviderRunCostTotals]] {
        guard !dateRanges.isEmpty else { return [] }

        return try await dbQueue.read { db in
            let widestRange = dateRanges.dropFirst().reduce(dateRanges[0]) { widest, range in
                min(widest.lowerBound, range.lowerBound)...max(widest.upperBound, range.upperBound)
            }
            let widestPredicate = Self.dateRangePredicate(widestRange)

            var innerSelectParts = [
                "provider",
                "totalTokens",
                "cost"
            ]
            var outerSelectParts = ["provider"]
            var arguments = StatementArguments()

            for (index, dateRange) in dateRanges.enumerated() {
                let membershipColumn = "in_window_\(index)"
                innerSelectParts.append(
                    "CASE WHEN \(Self.intersectionSQL) THEN 1 ELSE 0 END AS \(membershipColumn)"
                )
                arguments += Self.intersectionArguments(dateRange)
                outerSelectParts.append(
                    "COALESCE(SUM(\(membershipColumn)), 0) AS sessionCount_\(index)"
                )
                outerSelectParts.append(
                    "COALESCE(SUM(\(membershipColumn) * totalTokens), 0) AS totalTokens_\(index)"
                )
                outerSelectParts.append(
                    "COALESCE(SUM(\(membershipColumn) * cost), 0) AS cost_\(index)"
                )
            }
            arguments += widestPredicate.arguments

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(outerSelectParts.joined(separator: ",\n                           "))
                    FROM (
                        SELECT \(innerSelectParts.joined(separator: ",\n                               "))
                        FROM token_usage
                        \(widestPredicate.whereSQL)
                    ) AS bounded_usage
                    GROUP BY provider
                    """,
                arguments: arguments
            )

            var results = Array(
                repeating: [AgentProvider: ProviderRunCostTotals](),
                count: dateRanges.count
            )
            for row in rows {
                guard let rawProvider = row["provider"] as? String,
                      let provider = AgentProvider(rawValue: rawProvider) else { continue }
                for index in dateRanges.indices {
                    let sessionCount = Self.intValue(row["sessionCount_\(index)"])
                    guard sessionCount > 0 else { continue }
                    results[index][provider] = ProviderRunCostTotals(
                        sessionCount: sessionCount,
                        totalTokens: Self.intValue(row["totalTokens_\(index)"]),
                        totalCost: Self.doubleValue(row["cost_\(index)"])
                    )
                }
            }
            return results
        }
    }
}
