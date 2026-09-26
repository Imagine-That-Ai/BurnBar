import Foundation
import GRDB
import OpenBurnBarInsights
import OpenBurnBarKernel
import OpenBurnBarLogParsers
import OpenBurnBarUI
import OpenBurnBarData

/// Ledger-wide analytic core of `DashboardUsageSnapshot`: per-window
/// aggregate rows, the trailing 8-day cost/token series (offset 0 == today),
/// and the per-day summaries. The covering newest-N rows are intentionally
/// NOT part of this — they stay a live index-backed scan so session lists
/// never serve rows past `loadedUsageLimit` staleness.
struct DashboardRollupParts: Sendable {
    /// Per-window GROUP BY rows keyed by time range.
    let aggregatesByRange: [TimeRange: [UsageAggregateRow]]
    /// Trailing cost series, offsets `0...7` (8 entries, 0 == today).
    let dayCosts: [Double]
    /// Trailing token series, offsets `0...7` (8 entries, 0 == today).
    let dayTokens: [Int]
    let dailySummaries: [DailyUsageSummary]
}

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

    /// Usage rows for specific session identities. `sessionId` is indexed, so
    /// this is how the receipt close-monitor joins long-lived Factory / Claude
    /// chats whose original `startTime` fell out of the newest-N usage window.
    ///
    /// `limit` is per session. A single global `LIMIT` would keep only the
    /// newest rows across every candidate and mint older chats with empty
    /// totals.
    func fetchUsage(sessionIDs: [String], limit: Int = 800) async throws -> [TokenUsage] {
        let ids = Array(Set(sessionIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        guard !ids.isEmpty, limit > 0 else { return [] }
        return try await dbQueue.read { db in
            let placeholders = OpenBurnBarDatabase.sqlPlaceholders(count: ids.count)
            var arguments = StatementArguments(ids)
            arguments += [limit]
            let columns = Self.usageDecodeSelectColumns.joined(separator: ", ")
            return try Self.compactMapCachedRows(
                db: db,
                sql: """
                    SELECT \(columns)
                    FROM (
                        SELECT \(columns),
                               ROW_NUMBER() OVER (
                                   PARTITION BY sessionId
                                   ORDER BY endTime DESC
                               ) AS usage_row_number
                        FROM token_usage
                        WHERE sessionId IN (\(placeholders))
                    )
                    WHERE usage_row_number <= ?
                    ORDER BY endTime DESC
                    """,
                arguments: arguments,
                transform: Self.decodeUsage
            )
        }
    }

    /// Every `token_usage` row for the given session identities.
    /// Receipt mint must not truncate Warp / event-oriented sessions.
    func fetchAllUsage(sessionIDs: [String]) async throws -> [TokenUsage] {
        let ids = Array(Set(sessionIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        guard !ids.isEmpty else { return [] }
        return try await dbQueue.read { db in
            let placeholders = OpenBurnBarDatabase.sqlPlaceholders(count: ids.count)
            let columns = Self.usageDecodeSelectColumns.joined(separator: ", ")
            return try Self.compactMapCachedRows(
                db: db,
                sql: """
                    SELECT \(columns)
                    FROM token_usage
                    WHERE sessionId IN (\(placeholders))
                    ORDER BY endTime DESC
                    """,
                arguments: StatementArguments(ids),
                transform: Self.decodeUsage
            )
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

    /// Index-friendly end-time window for usage-only harnesses whose
    /// original start fell out of the six-hour start horizon.
    func fetchUsage(endingIn dateRange: Range<Date>, limit: Int) async throws -> [TokenUsage] {
        try await dbQueue.read { db -> [TokenUsage] in
            try Self.fetchUsageRows(db: db, endingIn: dateRange, limit: limit)
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
                      let provider = AgentProvider.resolve(providerRaw) else { continue }
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

    /// Today's burn from the `startTime` index, for first dashboard paint.
    ///
    /// The full snapshot GROUP-BYs every overlapping window across the whole
    /// ledger. On a multi-gigabyte SQLCipher file that can sit behind other
    /// readers for minutes, leaving the burn rail at 0. This path is exact for
    /// sessions that started today; long-runners that started yesterday land
    /// on the subsequent full snapshot.
    func fetchQuickTodayUsageSnapshot(
        loadedUsageLimit: Int,
        now: Date = Date()
    ) async throws -> DashboardUsageSnapshot {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)
            ?? todayStart.addingTimeInterval(86_400)
        let starting = todayStart..<tomorrow

        return try await dbQueue.read { db in
            let covering = try Self.fetchUsageRows(
                db: db,
                startingIn: starting,
                limit: loadedUsageLimit
            )
            let aggregates = try Self.fetchUsageAggregateRowsStartingIn(
                db: db,
                dateRange: starting
            )
            let today = Self.makeWindowSummary(
                loadedUsages: covering,
                aggregateRows: aggregates
            )
            return DashboardUsageSnapshot(
                loadedUsages: covering,
                windowSummaries: [
                    .today: today,
                    .last7Days: .empty,
                    .last30Days: .empty,
                    .thisMonth: .empty,
                    .allTime: .empty
                ],
                rollingDailyAverage: today.totalCost,
                distinctUsageDayCount: today.sessionCount > 0 ? 1 : 0,
                last7DayCosts: Array(repeating: 0, count: 6) + [today.totalCost],
                last7DayTokenTotals: Array(repeating: 0, count: 6) + [today.totalTokens],
                dailySummaries: [],
                // `providerSummaries` is sorted by (cents desc, key asc):
                // `.first` is the deterministic top provider. A raw-double
                // `.max` would let ULP accumulation noise pick the winner.
                topProviderToday: today.providerSummaries
                    .first
                    .map { ($0.provider, $0.totalCost) }
            )
        }
    }

    /// Materializable analytic core of the dashboard snapshot: every
    /// ledger-wide aggregate EXCEPT the covering newest-N rows.
    /// `DashboardRollupService` persists these parts as JSON in the
    /// `dashboard_rollups` retrieval-health row so a fresh reload costs one
    /// health read + one covering scan instead of the full multi-window
    /// GROUP BY fan-out. See Wave 2.8.
    static func fetchDashboardRollupParts(
        db: Database,
        now: Date
    ) throws -> DashboardRollupParts {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let windows = TimeRange.allCases.map { ($0, $0.dateRange(now: now)) }
        let aggregatesByRange = try Self.fetchUsageAggregateRowsByTimeRange(
            db: db,
            windows: windows
        )
        let dayTotals = try Self.fetchOverlappingDayCostAndTokens(
            db: db,
            calendar: calendar,
            todayStart: todayStart,
            offsets: 0...7
        )
        return DashboardRollupParts(
            aggregatesByRange: aggregatesByRange,
            dayCosts: (0...7).map { dayTotals[$0]?.cost ?? 0 },
            dayTokens: (0...7).map { dayTotals[$0]?.tokens ?? 0 },
            dailySummaries: try Self.fetchDailySummaries(db: db)
        )
    }

    /// Assembles a dashboard snapshot from live covering rows + analytic
    /// parts. The stale path fetches both in one read transaction; the
    /// materialized fresh path pairs a live covering scan with persisted
    /// parts. Both produce identical snapshots for the same ledger state.
    static func makeDashboardSnapshot(
        coveringUsages: [TokenUsage],
        parts: DashboardRollupParts,
        now: Date
    ) -> DashboardUsageSnapshot {
        let windows = TimeRange.allCases.map { ($0, $0.dateRange(now: now)) }
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
                aggregateRows: parts.aggregatesByRange[timeRange] ?? []
            )
        }

        let today = windowSummaries[.today] ?? .empty

        let last7DayCosts = (0..<7).reversed().map { offset in
            parts.dayCosts[offset]
        }
        let last7DayTokenTotals = (0..<7).reversed().map { offset in
            parts.dayTokens[offset]
        }
        let rollingDailyTotal = (1...7).reduce(0.0) { partial, offset in
            partial + parts.dayCosts[offset]
        }

        return DashboardUsageSnapshot(
            loadedUsages: coveringUsages,
            windowSummaries: windowSummaries,
            rollingDailyAverage: rollingDailyTotal / 7,
            distinctUsageDayCount: parts.dailySummaries.count,
            last7DayCosts: last7DayCosts,
            last7DayTokenTotals: last7DayTokenTotals,
            dailySummaries: parts.dailySummaries,
            // `providerSummaries` is sorted by (cents desc, key asc):
            // `.first` is the deterministic top provider. A raw-double
            // `.max` would let ULP accumulation noise pick the winner.
            topProviderToday: today.providerSummaries
                .first
                .map { ($0.provider, $0.totalCost) }
        )
    }

    func fetchDashboardUsageSnapshot(
        loadedUsageLimit: Int,
        now: Date = Date()
    ) async throws -> DashboardUsageSnapshot {
        try await fetchDashboardUsageSnapshotWithParts(
            loadedUsageLimit: loadedUsageLimit,
            now: now
        ).snapshot
    }

    /// Snapshot + the materializable parts behind it, from a single read
    /// transaction. `DashboardRollupService` persists the parts on its stale
    /// path so later fresh-path reloads can skip the GROUP BY fan-out.
    func fetchDashboardUsageSnapshotWithParts(
        loadedUsageLimit: Int,
        now: Date = Date()
    ) async throws -> (snapshot: DashboardUsageSnapshot, parts: DashboardRollupParts) {
        try await dbQueue.read { db in
            let parts = try Self.fetchDashboardRollupParts(db: db, now: now)
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
            let snapshot = Self.makeDashboardSnapshot(
                coveringUsages: coveringUsages,
                parts: parts,
                now: now
            )
            return (snapshot, parts)
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
                      let provider = AgentProvider.resolve(raw) else { continue }
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
                      let provider = AgentProvider.resolve(rawProvider) else { continue }
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
