import Foundation
import GRDB
import OpenBurnBarCore

extension UsageStore {
    /// Columns `decodeUsage` reads. Covering dashboard / session-list scans
    /// omit ledger sync hashes, paths, and other identity that the UI does
    /// not decode.
    static let usageDecodeSelectColumns = [
        "id",
        "provider",
        "sessionId",
        "projectName",
        "model",
        "inputTokens",
        "outputTokens",
        "cacheCreationTokens",
        "cacheReadTokens",
        "reasoningTokens",
        "cost",
        "startTime",
        "endTime",
        "createdAt",
        "usageSource",
        "executionSourceID",
        "executionSourceName",
        "executionSourceKind",
        "executionSourceConfidence",
        "sourceDeviceId",
        "sourceDeviceName",
        "isRemote",
        "providerID",
        "providerAccountID",
        "providerAccountLabel",
        "providerAccountSource",
        "provenanceMethod",
        "provenanceConfidence",
        "estimatorVersion",
        "parentRequestID",
        "billingKind"
    ]

    /// SELECT-order indexes for `usageDecodeSelectColumns`. GRDB named lookup is
    /// case-insensitive; index decode is the covering-scan hot path.
    enum UsageDecodeCol: Int {
        case id = 0
        case provider
        case sessionId
        case projectName
        case model
        case inputTokens
        case outputTokens
        case cacheCreationTokens
        case cacheReadTokens
        case reasoningTokens
        case cost
        case startTime
        case endTime
        case createdAt
        case usageSource
        case executionSourceID
        case executionSourceName
        case executionSourceKind
        case executionSourceConfidence
        case sourceDeviceId
        case sourceDeviceName
        case isRemote
        case providerID
        case providerAccountID
        case providerAccountLabel
        case providerAccountSource
        case provenanceMethod
        case provenanceConfidence
        case estimatorVersion
        case parentRequestID
        case billingKind
    }

    static let chartFactSelectColumns = [
        "startTime",
        "endTime",
        "cost",
        "sessionId",
        "projectName",
        "model",
        "provider",
        "billingKind",
        "usageSource",
        "inputTokens",
        "outputTokens",
        "cacheCreationTokens",
        "cacheReadTokens",
        "reasoningTokens",
        "provenanceConfidence",
        "isRemote"
    ]

    enum ChartFactCol: Int {
        case startTime = 0
        case endTime
        case cost
        case sessionId
        case projectName
        case model
        case provider
        case billingKind
        case usageSource
        case inputTokens
        case outputTokens
        case cacheCreationTokens
        case cacheReadTokens
        case reasoningTokens
        case provenanceConfidence
        case isRemote
    }

    static let chartSessionSelectColumns = [
        "startTime",
        "cost",
        "sessionId",
        "projectName",
        "model",
        "provider"
    ]

    enum ChartSessionCol: Int {
        case startTime = 0
        case cost
        case sessionId
        case projectName
        case model
        case provider
    }

    static func indexed(_ row: Row, _ index: Int) -> Any? {
        let value: (any DatabaseValueConvertible)? = row[index]
        return value
    }

    static func compactMapCachedRows<T>(
        db: Database,
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        transform: (Row) -> T?
    ) throws -> [T] {
        let statement = try db.cachedStatement(sql: sql)
        let cursor = try Row.fetchCursor(statement, arguments: arguments)
        var result: [T] = []
        while let row = try cursor.next() {
            if let value = transform(row) {
                result.append(value)
            }
        }
        return result
    }

    static let usageAggregateIdentityColumns = [
        "provider",
        "model",
        "executionSourceID",
        "executionSourceName",
        "executionSourceKind",
        "executionSourceConfidence",
        "provenanceConfidence",
        "provenanceMethod",
        "projectName",
        "providerAccountID",
        "providerAccountLabel",
        "providerAccountSource"
    ]

    static func fetchUsageRows( // pure-move: was private
        db: Database,
        dateRange: ClosedRange<Date>?,
        limit: Int
    ) throws -> [TokenUsage] {
        let predicate = dateRangePredicate(dateRange)
        var arguments = predicate.arguments
        arguments += StatementArguments([limit])
        return try compactMapCachedRows(
            db: db,
            sql: """
                SELECT \(usageDecodeSelectColumns.joined(separator: ", "))
                FROM token_usage\(predicate.whereSQL)
                ORDER BY startTime DESC LIMIT ?
                """,
            arguments: arguments,
            transform: Self.decodeUsage
        )
    }

    /// Fetches rows whose session starts inside a half-open time window.
    ///
    /// Unlike the dashboard's overlap predicate, this shape maps directly to
    /// the `token_usage.startTime` index created by v1 and is intended for
    /// bounded background consumers that do not need dashboard aggregates.
    static func fetchUsageRows(
        db: Database,
        startingIn dateRange: Range<Date>,
        limit: Int
    ) throws -> [TokenUsage] {
        guard limit > 0, dateRange.lowerBound < dateRange.upperBound else {
            return []
        }
        return try compactMapCachedRows(
            db: db,
            sql: """
                SELECT \(usageDecodeSelectColumns.joined(separator: ", "))
                FROM token_usage
                \(startTimeRangeWhereSQL)
                ORDER BY startTime DESC
                LIMIT ?
                """,
            arguments: [
                OpenBurnBarDatabase.sqliteDateString(dateRange.lowerBound),
                OpenBurnBarDatabase.sqliteDateString(dateRange.upperBound),
                limit
            ],
            transform: Self.decodeUsage
        )
    }

    static let startTimeRangeWhereSQL = "WHERE startTime >= ? AND startTime < ?"

    static func fetchWindowSummary( // pure-move: was private
        db: Database,
        dateRange: ClosedRange<Date>?,
        loadedUsageLimit: Int
    ) throws -> DashboardUsageWindowSummary {
        let loadedUsages = try fetchUsageRows(db: db, dateRange: dateRange, limit: loadedUsageLimit)
        let aggregateRows = try fetchUsageAggregateRows(db: db, dateRange: dateRange)
        return makeWindowSummary(loadedUsages: loadedUsages, aggregateRows: aggregateRows)
    }

    static func makeWindowSummary(
        loadedUsages: [TokenUsage],
        aggregateRows: [UsageAggregateRow]
    ) -> DashboardUsageWindowSummary {
        let totals = usageTotals(from: aggregateRows)

        return DashboardUsageWindowSummary(
            usages: loadedUsages,
            totalCost: totals.cost,
            totalTokens: totals.tokens,
            sessionCount: totals.sessionCount,
            activeProviderCount: Set(aggregateRows.map(\.provider)).count,
            providerSummaries: Self.makeProviderSummaries(fromAggregateRows: aggregateRows),
            modelSummaries: Self.makeModelSummaries(fromAggregateRows: aggregateRows),
            credentialSummaries: Self.makeCredentialSummaries(fromAggregateRows: aggregateRows),
            projectSpendSummaries: Self.makeProjectSpendSummaries(fromAggregateRows: aggregateRows),
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
                       executionSourceID,
                       executionSourceName,
                       executionSourceKind,
                       executionSourceConfidence,
                       provenanceConfidence,
                       provenanceMethod,
                       projectName,
                       providerAccountID,
                       providerAccountLabel,
                       providerAccountSource,
                       MAX(startTime) AS latestStartTime,
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
                GROUP BY provider, model, executionSourceID, executionSourceName,
                         executionSourceKind, executionSourceConfidence,
                         provenanceConfidence, provenanceMethod,
                         projectName, providerAccountID, providerAccountLabel,
                         providerAccountSource
                """,
                arguments: predicate.arguments
            )
        return rows.compactMap(UsageAggregateRow.init(row:))
    }

    /// One `GROUP BY` scan that fans each TimeRange window out with
    /// membership flags so dashboard hydration does not re-read
    /// `token_usage` once per window. Intersection is evaluated once per
    /// window per row; metrics are `flag * column`. Window membership is
    /// the same predicate as `fetchUsageAggregateRows`.
    static func fetchUsageAggregateRowsByTimeRange(
        db: Database,
        windows: [(TimeRange, ClosedRange<Date>?)]
    ) throws -> [TimeRange: [UsageAggregateRow]] {
        let identityColumns = usageAggregateIdentityColumns
        let metricColumns: [(alias: String, expression: String)] = [
            ("inputTokens", "inputTokens"),
            ("outputTokens", "outputTokens"),
            ("cacheCreationTokens", "cacheCreationTokens"),
            ("cacheReadTokens", "cacheReadTokens"),
            ("reasoningTokens", "reasoningTokens"),
            ("totalTokens", "totalTokens"),
            ("cost", "cost")
        ]

        var flagParts: [String] = []
        var arguments = StatementArguments()
        var windowFlags: [(range: TimeRange, flag: String)] = []
        flagParts.reserveCapacity(windows.count)
        windowFlags.reserveCapacity(windows.count)

        for (range, dateRange) in windows {
            let suffix = windowSQLAlias(range)
            let flag = "in_\(suffix)"
            if let dateRange {
                flagParts.append("CASE WHEN \(intersectionSQL) THEN 1 ELSE 0 END AS \(flag)")
                arguments += intersectionArguments(dateRange)
            } else {
                flagParts.append("1 AS \(flag)")
            }
            windowFlags.append((range, flag))
        }

        var selectParts = identityColumns
        selectParts.reserveCapacity(identityColumns.count + windowFlags.count * (metricColumns.count + 1))
        for (range, flag) in windowFlags {
            let suffix = windowSQLAlias(range)
            selectParts.append("COALESCE(SUM(\(flag)), 0) AS sessionCount_\(suffix)")
            selectParts.append(
                "MAX(CASE WHEN \(flag) = 1 THEN startTime END) AS latestStartTime_\(suffix)"
            )
            for metric in metricColumns {
                selectParts.append(
                    "COALESCE(SUM(\(flag) * \(metric.expression)), 0) AS \(metric.alias)_\(suffix)"
                )
            }
        }

        let innerSelect = (identityColumns + [
            "inputTokens",
            "outputTokens",
            "cacheCreationTokens",
            "cacheReadTokens",
            "reasoningTokens",
            "totalTokens",
            "cost",
            "startTime"
        ] + flagParts).joined(separator: ",\n                       ")

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(selectParts.joined(separator: ",\n                       "))
                FROM (
                    SELECT \(innerSelect)
                    FROM token_usage
                ) AS windowed
                GROUP BY provider, model, executionSourceID, executionSourceName,
                         executionSourceKind, executionSourceConfidence,
                         provenanceConfidence, provenanceMethod,
                         projectName, providerAccountID, providerAccountLabel,
                         providerAccountSource
                """,
            arguments: arguments
        )

        var result: [TimeRange: [UsageAggregateRow]] = [:]
        result.reserveCapacity(windows.count)
        for (range, _) in windows {
            result[range] = []
        }

        for row in rows {
            guard let providerRaw = row["provider"] as? String,
                  let provider = AgentProvider(rawValue: providerRaw),
                  let model = row["model"] as? String else { continue }
            let executionSourceID = row["executionSourceID"] as? String ?? "unknown"
            let executionSourceName = row["executionSourceName"] as? String ?? "Unknown"
            let executionSourceKind = (row["executionSourceKind"] as? String)
                .flatMap { UsageExecutionSourceKind(rawValue: $0) } ?? .unknown
            let executionSourceConfidence = (row["executionSourceConfidence"] as? String)
                .flatMap { UsageProvenanceConfidence(rawValue: $0) } ?? .unknown
            let provenanceConfidence = (row["provenanceConfidence"] as? String)
                .flatMap { UsageProvenanceConfidence(rawValue: $0) } ?? .unknown
            let provenanceMethod = (row["provenanceMethod"] as? String)
                .flatMap { UsageProvenanceMethod(rawValue: $0) } ?? .unknown

            for (range, _) in windows {
                let suffix = windowSQLAlias(range)
                let sessionCount = intValue(row["sessionCount_\(suffix)"])
                guard sessionCount > 0 else { continue }
                result[range, default: []].append(
                    UsageAggregateRow(
                        provider: provider,
                        model: model,
                        executionSourceID: executionSourceID,
                        executionSourceName: executionSourceName,
                        executionSourceKind: executionSourceKind,
                        executionSourceConfidence: executionSourceConfidence,
                        provenanceConfidence: provenanceConfidence,
                        provenanceMethod: provenanceMethod,
                        projectName: row["projectName"] as? String ?? "",
                        providerAccountID: row["providerAccountID"] as? String,
                        providerAccountLabel: row["providerAccountLabel"] as? String,
                        providerAccountSource: (row["providerAccountSource"] as? String)
                            .flatMap { ProviderAccountStorageScope(rawValue: $0) },
                        latestStartTime: OpenBurnBarDatabase.parseDateValue(
                            row["latestStartTime_\(suffix)"]
                        ) ?? .distantPast,
                        sessionCount: sessionCount,
                        inputTokens: intValue(row["inputTokens_\(suffix)"]),
                        outputTokens: intValue(row["outputTokens_\(suffix)"]),
                        cacheCreationTokens: intValue(row["cacheCreationTokens_\(suffix)"]),
                        cacheReadTokens: intValue(row["cacheReadTokens_\(suffix)"]),
                        reasoningTokens: intValue(row["reasoningTokens_\(suffix)"]),
                        totalTokens: intValue(row["totalTokens_\(suffix)"]),
                        cost: doubleValue(row["cost_\(suffix)"])
                    )
                )
            }
        }

        return result
    }

    private static func windowSQLAlias(_ range: TimeRange) -> String {
        switch range {
        case .today: return "today"
        case .last7Days: return "d7"
        case .last30Days: return "d30"
        case .thisMonth: return "month"
        case .allTime: return "all"
        }
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

    /// One table scan for N calendar-day windows using the same intersection
    /// predicate as `fetchUsageTotals`. Replaces the 14 per-day round-trips
    /// the dashboard snapshot used for last-7-day series + rolling average.
    static func fetchOverlappingDayCostAndTokens(
        db: Database,
        calendar: Calendar,
        todayStart: Date,
        offsets: ClosedRange<Int>
    ) throws -> [Int: (cost: Double, tokens: Int)] {
        var flagParts: [String] = []
        var selectParts: [String] = []
        var arguments = StatementArguments()
        var includedOffsets: [Int] = []
        flagParts.reserveCapacity(offsets.count)
        selectParts.reserveCapacity(offsets.count * 2)

        for offset in offsets {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                continue
            }
            let flag = "in_\(offset)"
            flagParts.append("CASE WHEN \(dayIntersectionSQL) THEN 1 ELSE 0 END AS \(flag)")
            arguments += dayIntersectionArguments(dayStart: day, nextDay: nextDay)
            selectParts.append("COALESCE(SUM(\(flag) * cost), 0) AS cost_\(offset)")
            selectParts.append("COALESCE(SUM(\(flag) * totalTokens), 0) AS tokens_\(offset)")
            includedOffsets.append(offset)
        }

        guard !selectParts.isEmpty else { return [:] }

        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT \(selectParts.joined(separator: ",\n                       "))
                FROM (
                    SELECT cost, totalTokens,
                           \(flagParts.joined(separator: ",\n                           "))
                    FROM token_usage
                ) AS windowed
                """,
            arguments: arguments
        )

        var result: [Int: (cost: Double, tokens: Int)] = [:]
        for offset in includedOffsets {
            result[offset] = (
                cost: doubleValue(row?["cost_\(offset)"]),
                tokens: intValue(row?["tokens_\(offset)"])
            )
        }
        return result
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
        try fetchDistinctUsageDayCount(db: db, calendar: .current)
    }

    /// Distinct local calendar days that at least one session overlaps.
    /// Same membership as `fetchDailySummaries` / last-7-day intersection SQL.
    static func fetchDistinctUsageDayCount(db: Database, calendar: Calendar) throws -> Int {
        try fetchDailySummaries(db: db, calendar: calendar).count
    }

    static func fetchDailySummaries(db: Database) throws -> [DailyUsageSummary] { // pure-move: was private
        try fetchDailySummaries(db: db, calendar: .current)
    }

    static func fetchDailySummaries(db: Database, calendar: Calendar) throws -> [DailyUsageSummary] {
        let windows = try usageDayWindows(db: db, calendar: calendar)
        var accumulators: [Date: DailySummaryAccumulator] = [:]
        for batchStart in stride(from: 0, to: windows.count, by: usageDayWindowBatchSize) {
            let batchEnd = min(batchStart + usageDayWindowBatchSize, windows.count)
            let batch = windows[batchStart..<batchEnd]
            let placeholders = Array(repeating: "(?, ?)", count: batch.count).joined(separator: ", ")
            let arguments = StatementArguments(batch.flatMap { window in
                [
                    OpenBurnBarDatabase.sqliteDateString(window.dayStart),
                    OpenBurnBarDatabase.sqliteDateString(window.nextDay)
                ]
            })
            let rows = try Row.fetchAll(
                db,
                sql: """
                    WITH day_windows(dayStart, nextDay) AS (
                        VALUES \(placeholders)
                    )
                    SELECT day_windows.dayStart,
                           provider,
                           model,
                           COUNT(*) AS sessionCount,
                           COALESCE(SUM(inputTokens), 0) AS inputTokens,
                           COALESCE(SUM(outputTokens), 0) AS outputTokens,
                           COALESCE(SUM(cacheCreationTokens), 0) AS cacheCreationTokens,
                           COALESCE(SUM(cacheReadTokens), 0) AS cacheReadTokens,
                           COALESCE(SUM(totalTokens), 0) AS totalTokens,
                           COALESCE(SUM(cost), 0) AS cost
                    FROM day_windows
                    JOIN token_usage ON \(dayWindowIntersectionSQL)
                    GROUP BY day_windows.dayStart, provider, model
                    """,
                arguments: arguments
            )
            for row in rows {
                guard let dayStart = OpenBurnBarDatabase.parseDateValue(row["dayStart"]),
                      let providerRaw = row["provider"] as? String,
                      let provider = AgentProvider(rawValue: providerRaw),
                      let model = row["model"] as? String else {
                    continue
                }
                accumulators[
                    dayStart,
                    default: DailySummaryAccumulator(
                        dayString: overlappingDayString(dayStart, calendar: calendar),
                        date: dayStart
                    )
                ].record(row: row, provider: provider, model: model)
            }
        }
        return accumulators.values
            .compactMap(\.summary)
            .sorted { $0.date > $1.date }
    }

    /// Per-day intersection `GROUP BY` used as the equality oracle for the
    /// folded all-time daily-summary scan. Not a production hot path.
    static func fetchDailySummariesByPerDayIntersection(
        db: Database,
        calendar: Calendar
    ) throws -> [DailyUsageSummary] {
        let windows = try usageDayWindows(db: db, calendar: calendar)
        var accumulators: [Date: DailySummaryAccumulator] = [:]
        for window in windows {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT provider, model,
                           COUNT(*) AS sessionCount,
                           COALESCE(SUM(inputTokens), 0) AS inputTokens,
                           COALESCE(SUM(outputTokens), 0) AS outputTokens,
                           COALESCE(SUM(cacheCreationTokens), 0) AS cacheCreationTokens,
                           COALESCE(SUM(cacheReadTokens), 0) AS cacheReadTokens,
                           COALESCE(SUM(totalTokens), 0) AS totalTokens,
                           COALESCE(SUM(cost), 0) AS cost
                    FROM token_usage
                    WHERE \(dayIntersectionSQL)
                    GROUP BY provider, model
                    """,
                arguments: dayIntersectionArguments(
                    dayStart: window.dayStart,
                    nextDay: window.nextDay
                )
            )
            let dayString = overlappingDayString(window.dayStart, calendar: calendar)
            for row in rows {
                guard let providerRaw = row["provider"] as? String,
                      let provider = AgentProvider(rawValue: providerRaw),
                      let model = row["model"] as? String else { continue }
                accumulators[
                    window.dayStart,
                    default: DailySummaryAccumulator(dayString: dayString, date: window.dayStart)
                ]
                    .record(row: row, provider: provider, model: model)
            }
        }
        return accumulators.values
            .compactMap(\.summary)
            .sorted { $0.date > $1.date }
    }

    private static func overlappingDayString(_ day: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    private struct UsageDayWindow {
        let dayStart: Date
        let nextDay: Date
    }

    /// 400 bound values per statement, below SQLite's legacy 999-variable
    /// ceiling while avoiding one table scan per historical day.
    private static let usageDayWindowBatchSize = 200

    private static func usageDayWindows(
        db: Database,
        calendar: Calendar
    ) throws -> [UsageDayWindow] {
        let bounds = try Row.fetchOne(
            db,
            sql: """
                SELECT MIN(MIN(startTime, endTime)) AS lowerBound,
                       MAX(MAX(startTime, endTime)) AS upperBound
                FROM token_usage
                """
        )
        guard let lowerBound = OpenBurnBarDatabase.parseDateValue(bounds?["lowerBound"]),
              let upperBound = OpenBurnBarDatabase.parseDateValue(bounds?["upperBound"]) else {
            return []
        }

        let firstDay = calendar.startOfDay(for: lowerBound)
        let lastDay = calendar.startOfDay(for: upperBound)
        var windows: [UsageDayWindow] = []
        var day = firstDay
        while day <= lastDay {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                  nextDay > day else {
                break
            }
            windows.append(UsageDayWindow(dayStart: day, nextDay: nextDay))
            day = nextDay
        }
        return windows
    }

    private static let dayWindowIntersectionSQL = """
        (
            (startTime < day_windows.nextDay AND endTime > day_windows.dayStart)
            OR (endTime < day_windows.nextDay AND startTime > day_windows.dayStart)
            OR (
                startTime = endTime
                AND startTime >= day_windows.dayStart
                AND startTime < day_windows.nextDay
            )
        )
        """

    static let dayIntersectionSQL = """
        (
            (startTime < ? AND endTime > ?)
            OR (endTime < ? AND startTime > ?)
            OR (startTime = endTime AND startTime >= ? AND startTime < ?)
        )
        """

    static func dayIntersectionArguments(
        dayStart: Date,
        nextDay: Date
    ) -> StatementArguments {
        let lowerBound = OpenBurnBarDatabase.sqliteDateString(dayStart)
        let upperBound = OpenBurnBarDatabase.sqliteDateString(nextDay)
        return StatementArguments([
            upperBound,
            lowerBound,
            upperBound,
            lowerBound,
            lowerBound,
            upperBound
        ])
    }

    static let intersectionSQL = "((startTime <= ? AND endTime >= ?) OR (endTime <= ? AND startTime >= ?))"

    static func intersectionArguments(_ dateRange: ClosedRange<Date>) -> StatementArguments {
        let lowerBound = OpenBurnBarDatabase.sqliteDateString(dateRange.lowerBound)
        let upperBound = OpenBurnBarDatabase.sqliteDateString(dateRange.upperBound)
        return StatementArguments([
            upperBound,
            lowerBound,
            upperBound,
            lowerBound
        ])
    }

    static func dateRangePredicate(_ dateRange: ClosedRange<Date>?) -> (whereSQL: String, arguments: StatementArguments) { // pure-move: was private
        guard let dateRange else {
            return ("", StatementArguments())
        }
        return (
            " WHERE \(intersectionSQL)",
            intersectionArguments(dateRange)
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

    private static func makeCredentialSummaries(fromAggregateRows rows: [UsageAggregateRow]) -> [CredentialSummary] {
        struct Key: Hashable {
            let provider: AgentProvider
            let accountID: String?
        }
        var groups: [Key: CredentialSummaryAccumulator] = [:]
        for row in rows {
            let key = Key(provider: row.provider, accountID: row.providerAccountID)
            groups[key, default: CredentialSummaryAccumulator()].record(row)
        }
        return groups.compactMap { key, accumulator in
            accumulator.summary(for: key.provider, accountID: key.accountID)
        }
        .sorted { $0.totalCost > $1.totalCost }
    }

    private static func makeProjectSpendSummaries(fromAggregateRows rows: [UsageAggregateRow]) -> [ProjectSpendSummary] {
        var groups: [String: ProjectSpendSummaryAccumulator] = [:]
        for row in rows {
            let key = row.projectName.isEmpty ? "Unattributed" : row.projectName
            groups[key, default: ProjectSpendSummaryAccumulator()].record(row)
        }
        return groups.compactMap { projectName, accumulator in
            accumulator.summary(projectName: projectName)
        }
        .sorted { $0.totalCost > $1.totalCost }
    }

    private static func makeModelSummaries(fromAggregateRows rows: [UsageAggregateRow]) -> [ModelSummary] {
        var models: [String: ModelSummaryAccumulator] = [:]
        for row in rows {
            let normalized = OpenBurnBarCore.TokenExtractionUtility.normalizeModelKey(row.model)
            models[normalized, default: ModelSummaryAccumulator(modelName: normalized)].record(row)
        }
        return models.values
            .map(\.summary)
            .sorted { $0.totalCost > $1.totalCost }
    }
}
