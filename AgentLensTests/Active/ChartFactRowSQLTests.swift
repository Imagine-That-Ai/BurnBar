import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore

@MainActor
final class ChartFactRowSQLTests: XCTestCase {
    func test_factRows_matchTokenUsageSnapshot_last7DaysCoveringScan() async throws {
        let (usageStore, now) = try await seededStore()
        let recent = ChartsDataService.recentRange(now: now)
        let requested = try XCTUnwrap(TimeRange.last7Days.dateRange(now: now))

        let usages = try await usageStore.fetchUsage(in: recent, limit: Int.max)
        let facts = try await usageStore.fetchChartFactRows(in: recent)
        XCTAssertEqual(facts.count, usages.count)
        XCTAssertEqual(facts.map(\.sessionId), usages.map(\.sessionId))

        let usageWindows = ChartsDataService.deriveWindows(
            coveringRows: usages,
            requestedRange: requested,
            recentRange: recent
        )
        let factWindows = ChartsDataService.deriveWindows(
            coveringRows: facts,
            requestedRange: requested,
            recentRange: recent
        )
        XCTAssertEqual(factWindows.selected.map(\.sessionId), usageWindows.selected.map(\.sessionId))
        XCTAssertEqual(factWindows.recent.map(\.sessionId), usageWindows.recent.map(\.sessionId))

        let fromUsage = ChartsSnapshot.build(
            rows: usageWindows.selected,
            recentRows: usageWindows.recent,
            timeRange: .last7Days,
            usagesVersion: 3,
            now: now
        )
        let fromFacts = ChartsSnapshot.build(
            rows: factWindows.selected,
            recentRows: factWindows.recent,
            timeRange: .last7Days,
            usagesVersion: 3,
            now: now
        )
        XCTAssertEqual(fromFacts, fromUsage)
    }

    func test_factRows_matchTokenUsageSnapshot_allTimeWithoutDecodeUsage() async throws {
        let (usageStore, now) = try await seededStore()
        let recent = ChartsDataService.recentRange(now: now)

        let usages = try await usageStore.fetchAllUsage()
        let facts = try await usageStore.fetchChartFactRows(in: nil)
        XCTAssertEqual(facts.count, usages.count)

        let usageWindows = ChartsDataService.deriveWindows(
            coveringRows: usages,
            requestedRange: nil,
            recentRange: recent
        )
        let factWindows = ChartsDataService.deriveWindows(
            coveringRows: facts,
            requestedRange: nil,
            recentRange: recent
        )

        let fromUsage = ChartsSnapshot.build(
            rows: usageWindows.selected,
            recentRows: usageWindows.recent,
            timeRange: .allTime,
            usagesVersion: 0,
            now: now
        )
        let fromFacts = ChartsSnapshot.build(
            rows: factWindows.selected,
            recentRows: factWindows.recent,
            timeRange: .allTime,
            usagesVersion: 0,
            now: now
        )
        XCTAssertEqual(fromFacts, fromUsage)
        XCTAssertEqual(fromFacts.cacheReadTokens, fromUsage.cacheReadTokens)
        XCTAssertEqual(fromFacts.exactShare, fromUsage.exactShare, accuracy: 1e-12)
        XCTAssertEqual(fromFacts.remoteCost, fromUsage.remoteCost, accuracy: 1e-12)
        XCTAssertEqual(fromFacts.apiCost, fromUsage.apiCost, accuracy: 1e-12)
        XCTAssertEqual(fromFacts.subscriptionCost, fromUsage.subscriptionCost, accuracy: 1e-12)
        XCTAssertEqual(fromFacts.unknownBillingCost, fromUsage.unknownBillingCost, accuracy: 1e-12)
    }

    func test_factRows_clampsCrossingSessionToRangeLowerBound() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
        let startOfToday = calendar.startOfDay(for: now)
        let row = TokenUsage(
            provider: .claudeCode,
            sessionId: "crossing",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: 2.0,
            startTime: startOfToday.addingTimeInterval(-300),
            endTime: startOfToday.addingTimeInterval(300)
        )
        try await usageStore.insert(row)

        let today = try XCTUnwrap(TimeRange.today.dateRange(now: now))
        let usages = try await usageStore.fetchUsage(in: today, limit: Int.max)
        let facts = try await usageStore.fetchChartFactRows(in: today)
        XCTAssertEqual(facts.map(\.sessionId), ["crossing"])

        let fromUsage = ChartsSnapshot.build(
            rows: usages,
            recentRows: usages,
            timeRange: .today,
            usagesVersion: 0,
            now: now,
            calendar: calendar
        )
        let fromFacts = ChartsSnapshot.build(
            rows: facts,
            recentRows: facts,
            timeRange: .today,
            usagesVersion: 0,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(fromFacts, fromUsage)
        XCTAssertEqual(fromFacts.burnSeries.reduce(0) { $0 + $1.value }, 2.0, accuracy: 1e-9)
    }

    func test_factRows_stampedApiBillingKind_doesNotReclassifyToSubscription() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()
        // Claude Code is subscription-first. A stamped `.api` row must stay
        // API after the fact-row scan or Spend Lens would silently rebucket.
        let stamped = TokenUsage(
            provider: .claudeCode,
            sessionId: "stamped-api",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: 4.0,
            startTime: now.addingTimeInterval(-3_600),
            endTime: now.addingTimeInterval(-1_800),
            billingKind: .api
        )
        let unclassified = TokenUsage(
            provider: .openCode,
            sessionId: "unclassified",
            projectName: "",
            model: "mystery-model",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: 7.5,
            startTime: now.addingTimeInterval(-2 * 3_600),
            endTime: now.addingTimeInterval(-1.5 * 3_600),
            provenanceConfidence: .lowConfidenceEstimate
        )
        try await usageStore.insert([stamped, unclassified])

        let usages = try await usageStore.fetchAllUsage()
        let facts = try await usageStore.fetchChartFactRows(in: nil)
        XCTAssertEqual(facts.first { $0.sessionId == "stamped-api" }?.billingKind, .api)

        let fromUsage = ChartsSnapshot.build(
            rows: usages,
            recentRows: usages,
            timeRange: .last7Days,
            usagesVersion: 1,
            now: now
        )
        let fromFacts = ChartsSnapshot.build(
            rows: facts,
            recentRows: facts,
            timeRange: .last7Days,
            usagesVersion: 1,
            now: now
        )
        XCTAssertEqual(fromFacts, fromUsage)
        XCTAssertEqual(fromFacts.apiCost, 4.0, accuracy: 1e-9)
        XCTAssertEqual(fromFacts.unknownBillingCost, 7.5, accuracy: 1e-9)
        XCTAssertEqual(
            fromFacts.apiCost + fromFacts.subscriptionCost + fromFacts.unknownBillingCost,
            fromFacts.totalCost,
            accuracy: 0.0001
        )
    }

    func test_selectColumnOrder_matchesIndexEnums() {
        XCTAssertEqual(
            UsageStore.usageDecodeSelectColumns[UsageStore.UsageDecodeCol.id.rawValue],
            "id"
        )
        XCTAssertEqual(
            UsageStore.usageDecodeSelectColumns[UsageStore.UsageDecodeCol.billingKind.rawValue],
            "billingKind"
        )
        XCTAssertEqual(
            UsageStore.usageDecodeSelectColumns.count,
            UsageStore.UsageDecodeCol.billingKind.rawValue + 1
        )
        XCTAssertEqual(
            UsageStore.chartFactSelectColumns[UsageStore.ChartFactCol.startTime.rawValue],
            "startTime"
        )
        XCTAssertEqual(
            UsageStore.chartFactSelectColumns[UsageStore.ChartFactCol.isRemote.rawValue],
            "isRemote"
        )
        XCTAssertEqual(
            UsageStore.chartFactSelectColumns.count,
            UsageStore.ChartFactCol.isRemote.rawValue + 1
        )
        XCTAssertEqual(
            UsageStore.chartSessionSelectColumns[UsageStore.ChartSessionCol.provider.rawValue],
            "provider"
        )
        XCTAssertEqual(
            UsageStore.chartSessionSelectColumns.count,
            UsageStore.ChartSessionCol.provider.rawValue + 1
        )
    }

    func test_chartFactIndexDecode_matchesNamedColumnOracle() async throws {
        let (usageStore, _) = try await seededStore()
        let (named, indexed) = try await usageStore.dbQueue.read { db -> ([ChartFactRow], [ChartFactRow]) in
            let sql = """
                SELECT \(UsageStore.chartFactSelectColumns.joined(separator: ", "))
                FROM token_usage
                ORDER BY startTime DESC
                """
            let rows = try Row.fetchAll(db, sql: sql)
            return (rows.compactMap(Self.namedChartFact), rows.compactMap(UsageStore.decodeChartFactRow))
        }
        XCTAssertFalse(indexed.isEmpty)
        XCTAssertEqual(indexed, named)
    }

    func test_usageIndexDecode_matchesNamedColumnOracle() async throws {
        let (usageStore, _) = try await seededStore()
        let fromStore = try await usageStore.fetchAllUsage()
        let (named, indexed) = try await usageStore.dbQueue.read { db -> ([TokenUsage], [TokenUsage]) in
            let sql = """
                SELECT \(UsageStore.usageDecodeSelectColumns.joined(separator: ", "))
                FROM token_usage
                ORDER BY startTime DESC
                """
            let rows = try Row.fetchAll(db, sql: sql)
            return (rows.compactMap(Self.namedUsage), rows.compactMap(UsageStore.decodeUsage))
        }
        XCTAssertEqual(indexed, named)
        XCTAssertEqual(indexed.map(\.sessionId), fromStore.map(\.sessionId))
    }

    func test_databasePoolTuning_appliesReaderCountAndBusyTimeout() {
        var config = Configuration()
        OpenBurnBarDatabase.applyPoolTuning(&config)
        XCTAssertEqual(config.maximumReaderCount, OpenBurnBarDatabase.PoolTuning.maximumReaderCount)
        XCTAssertEqual(OpenBurnBarDatabase.PoolTuning.maximumReaderCount, 8)
        XCTAssertEqual(OpenBurnBarDatabase.PoolTuning.busyTimeoutSeconds, 5)
    }

    func test_explainQueryPlan_onDiskPool_unsyncedUsesSyncPendingIndex() async throws {
        let (pool, _, _) = try await makeOnDiskPoolStore()
        defer { try? pool.close() }
        try await pool.write { db in
            try db.execute(sql: "ANALYZE")
        }
        let plan = try await pool.read { db in
            try Self.explainQueryPlan(
                db,
                sql: """
                    SELECT \(UsageStore.usageDecodeSelectColumns.joined(separator: ", "))
                    FROM token_usage
                    WHERE syncedAt IS NULL AND isRemote = 0
                    ORDER BY startTime ASC LIMIT 400
                    """
            )
        }
        XCTAssertTrue(
            plan.localizedCaseInsensitiveContains("token_usage_sync_pending_idx"),
            "unsynced path must use the existing sync-pending index; got:\n\(plan)"
        )
        let indexes = try await pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'token_usage'"
            )
        }
        XCTAssertFalse(
            indexes.contains { $0.localizedCaseInsensitiveContains("covering") },
            "covering-index migration is out of this PR; indexes=\(indexes)"
        )
    }

    func test_explainQueryPlan_onDiskPool_chartIntersectionNeedsNoNewCoveringIndex() async throws {
        let (pool, _, now) = try await makeOnDiskPoolStore()
        defer { try? pool.close() }
        try await pool.write { db in
            try db.execute(sql: "ANALYZE")
        }
        let recent = ChartsDataService.recentRange(now: now)
        let predicate = UsageStore.dateRangePredicate(recent)
        let plan = try await pool.read { db in
            try Self.explainQueryPlan(
                db,
                sql: """
                    SELECT \(UsageStore.chartFactSelectColumns.joined(separator: ", "))
                    FROM token_usage
                    \(predicate.whereSQL)
                    ORDER BY startTime DESC
                    """,
                arguments: predicate.arguments
            )
        }
        XCTAssertTrue(plan.localizedCaseInsensitiveContains("token_usage"), plan)
        XCTAssertFalse(
            plan.localizedCaseInsensitiveContains("token_usage_chart_fact_covering"),
            "no chart covering-index migration this round; got:\n\(plan)"
        )
    }

    // GRDB `DatabasePool.read` / `DatabaseQueue.read` closures are nonisolated.
    // Keep these oracles off MainActor so compactMap/EXPLAIN stay valid after
    // the suite itself is isolated for DataStore inits.
    nonisolated private static func explainQueryPlan(
        _ db: Database,
        sql: String,
        arguments: StatementArguments = StatementArguments()
    ) throws -> String {
        let rows = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
        return rows.map { row in
            if let detail: String = row["detail"] {
                return detail
            }
            return (0..<row.count).compactMap { row[$0] as? String }.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    private func makeOnDiskPoolStore() async throws -> (DatabasePool, UsageStore, Date) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-eqp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("openburnbar.sqlite").path
        var config = Configuration()
        OpenBurnBarDatabase.applyPoolTuning(&config)
        let pool = try DatabasePool(path: path, configuration: config)
        XCTAssertEqual(pool.configuration.maximumReaderCount, OpenBurnBarDatabase.PoolTuning.maximumReaderCount)
        _ = try DataStore(databaseQueue: pool, runMigrations: true, refreshOnInit: false)
        try OpenBurnBarDatabase.configureWALMode(pool)
        let usageStore = UsageStore(dbQueue: pool)
        let now = Date()
        var rows = ChartsSnapshotFixtures.sampleRows(now: now)
        rows.append(
            TokenUsage(
                provider: .openCode,
                sessionId: "session-unclassified",
                projectName: "",
                model: "mystery-model",
                inputTokens: 10,
                outputTokens: 10,
                costUSD: 7.5,
                startTime: now.addingTimeInterval(-3 * 3_600),
                endTime: now.addingTimeInterval(-2.5 * 3_600),
                provenanceConfidence: .lowConfidenceEstimate
            )
        )
        for index in 0..<400 {
            rows.append(
                TokenUsage(
                    provider: .codex,
                    sessionId: "eqp-unsynced-\(index)",
                    projectName: "eqp",
                    model: "gpt-5.6",
                    inputTokens: 1,
                    outputTokens: 1,
                    startTime: now.addingTimeInterval(Double(-index) * 60),
                    endTime: now.addingTimeInterval(Double(-index) * 60 + 30)
                )
            )
        }
        try await usageStore.insert(rows)
        return (pool, usageStore, now)
    }

    nonisolated private static func namedChartFact(_ row: Row) -> ChartFactRow? {
        guard let startTime = OpenBurnBarDatabase.parseDateValue(row["startTime"]),
              let endTime = OpenBurnBarDatabase.parseDateValue(row["endTime"]),
              let sessionId = row["sessionId"] as? String,
              let projectName = row["projectName"] as? String,
              let model = row["model"] as? String,
              let providerRaw = row["provider"] as? String,
              let provider = AgentProvider(rawValue: providerRaw) else {
            return nil
        }
        let inputTokens = UsageStore.intValue(row["inputTokens"])
        let outputTokens = UsageStore.intValue(row["outputTokens"])
        let cacheCreationTokens = UsageStore.intValue(row["cacheCreationTokens"])
        let cacheReadTokens = UsageStore.intValue(row["cacheReadTokens"])
        let reasoningTokens = UsageStore.intValue(row["reasoningTokens"])
        return ChartFactRow(
            startTime: startTime,
            endTime: endTime,
            cost: UsageStore.doubleValue(row["cost"]),
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            provider: provider,
            billingKind: (row["billingKind"] as? String)
                .flatMap(BurnBarBillingKind.init(rawValue:)) ?? .unknown,
            usageSource: (row["usageSource"] as? String)
                .flatMap(UsageSource.init(rawValue:)) ?? .unknown,
            inputTokens: inputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: TokenUsage.billedTotalTokens(
                input: inputTokens,
                output: outputTokens,
                cacheCreation: cacheCreationTokens,
                cacheRead: cacheReadTokens,
                reasoning: reasoningTokens
            ),
            provenanceConfidence: (row["provenanceConfidence"] as? String)
                .flatMap(UsageProvenanceConfidence.init(rawValue:)) ?? .unknown,
            isRemote: UsageStore.intValue(row["isRemote"]) != 0
        )
    }

    nonisolated private static func namedUsage(_ row: Row) -> TokenUsage? {
        guard let idString = row["id"] as? String,
              let id = UUID(uuidString: idString),
              let providerString = row["provider"] as? String,
              let provider = AgentProvider(rawValue: providerString),
              let sessionId = row["sessionId"] as? String,
              let projectName = row["projectName"] as? String,
              let model = row["model"] as? String else { return nil }
        let inputTokens = UsageStore.intValue(row["inputTokens"])
        let outputTokens = UsageStore.intValue(row["outputTokens"])
        let cacheCreationTokens = UsageStore.intValue(row["cacheCreationTokens"])
        let cacheReadTokens = UsageStore.intValue(row["cacheReadTokens"])
        let reasoningTokens = UsageStore.intValue(row["reasoningTokens"])
        let usageSource = (row["usageSource"] as? String).flatMap(UsageSource.init(rawValue:)) ?? .unknown
        let executionSourceKind = (row["executionSourceKind"] as? String)
            .flatMap(UsageExecutionSourceKind.init(rawValue:))
        let executionSourceConfidence = (row["executionSourceConfidence"] as? String)
            .flatMap(UsageProvenanceConfidence.init(rawValue:))
        let provenanceMethod = (row["provenanceMethod"] as? String)
            .flatMap(UsageProvenanceMethod.init(rawValue:)) ?? .unknown
        let provenanceConfidence = (row["provenanceConfidence"] as? String)
            .flatMap(UsageProvenanceConfidence.init(rawValue:)) ?? .unknown
        let estimatorVersion = row["estimatorVersion"] as? String ?? ""
        let cost: Double = row["cost"] ?? 0
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
            executionSourceID: row["executionSourceID"] as? String,
            executionSourceName: row["executionSourceName"] as? String,
            executionSourceKind: executionSourceKind,
            executionSourceConfidence: executionSourceConfidence,
            sourceDeviceId: row["sourceDeviceId"] as? String,
            sourceDeviceName: row["sourceDeviceName"] as? String,
            isRemote: UsageStore.intValue(row["isRemote"]) != 0,
            providerID: providerID,
            providerAccountID: row["providerAccountID"] as? String,
            providerAccountLabel: row["providerAccountLabel"] as? String,
            providerAccountSource: providerAccountSourceRaw.flatMap(ProviderAccountStorageScope.init(rawValue:)),
            provenanceMethod: provenanceMethod,
            provenanceConfidence: provenanceConfidence,
            estimatorVersion: estimatorVersion,
            parentRequestID: row["parentRequestID"] as? String,
            billingKind: (row["billingKind"] as? String)
                .flatMap(BurnBarBillingKind.init(rawValue:)) ?? .unknown
        )
    }

    private func seededStore() async throws -> (UsageStore, Date) {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()
        var rows = ChartsSnapshotFixtures.sampleRows(now: now)
        rows.append(
            TokenUsage(
                provider: .openCode,
                sessionId: "session-unclassified",
                projectName: "",
                model: "mystery-model",
                inputTokens: 10,
                outputTokens: 10,
                costUSD: 7.5,
                startTime: now.addingTimeInterval(-3 * 3_600),
                endTime: now.addingTimeInterval(-2.5 * 3_600),
                provenanceConfidence: .lowConfidenceEstimate
            )
        )
        try await usageStore.insert(rows)
        return (usageStore, now)
    }
}
