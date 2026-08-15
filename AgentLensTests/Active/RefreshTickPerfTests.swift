import XCTest
import GRDB
import FirebaseFirestore
@testable import OpenBurnBar
@testable import OpenBurnBarCore

// MARK: - Shared fixtures

/// Builds a realistic multi-provider usage history spanning ~120 days:
/// old rows far outside any billing window, a long-running session that
/// STARTED outside the 30-day window but ends inside it (the intersection
/// edge case the bounded baseline must not drop), and recent rows that
/// billing records partially cover.
private func makeRealisticUsageHistory(now: Date = Date()) -> [TokenUsage] {
    var rows: [TokenUsage] = []

    // 90 days of steady history, one session per day, two providers.
    for dayOffset in 1...90 {
        let start = now.addingTimeInterval(TimeInterval(-dayOffset) * 86_400)
        rows.append(
            TokenUsage(
                provider: .factory,
                sessionId: "factory-day-\(dayOffset)",
                projectName: "history",
                model: "test-model",
                inputTokens: 1_000 + dayOffset,
                outputTokens: 500 + dayOffset,
                costUSD: 0.25 + Double(dayOffset) * 0.01,
                startTime: start,
                endTime: start.addingTimeInterval(600)
            )
        )
        rows.append(
            TokenUsage(
                provider: .cursor,
                sessionId: "cursor-day-\(dayOffset)",
                projectName: "history",
                model: "cursor-model",
                inputTokens: 400,
                outputTokens: 200,
                costUSD: 0.10,
                startTime: start.addingTimeInterval(3_600),
                endTime: start.addingTimeInterval(4_200),
                providerAccountID: dayOffset % 2 == 0 ? "acct-a" : nil
            )
        )
    }

    // Long-running session: starts 45 days ago, ends 10 days ago — its
    // [start, end] INTERSECTS recent billing windows even though startTime
    // is far outside them.
    let longStart = now.addingTimeInterval(-45 * 86_400)
    rows.append(
        TokenUsage(
            provider: .factory,
            sessionId: "factory-long-runner",
            projectName: "marathon",
            model: "test-model",
            inputTokens: 50_000,
            outputTokens: 25_000,
            costUSD: 12.5,
            startTime: longStart,
            endTime: now.addingTimeInterval(-10 * 86_400)
        )
    )

    // Very old row (120 days) — must never affect supplemental reconciliation.
    let ancient = now.addingTimeInterval(-120 * 86_400)
    rows.append(
        TokenUsage(
            provider: .factory,
            sessionId: "factory-ancient",
            projectName: "history",
            model: "test-model",
            inputTokens: 9_999,
            outputTokens: 9_999,
            costUSD: 42.0,
            startTime: ancient,
            endTime: ancient.addingTimeInterval(600)
        )
    )

    return rows
}

/// Billing-API records over the last 30 days: some fully covered by local
/// rows, some with missing cost/tokens that produce supplemental rows.
private func makeRealisticBillingRecords(now: Date = Date()) -> [ProviderUsageRecord] {
    var records: [ProviderUsageRecord] = []
    for dayOffset in [1, 3, 7, 14, 29] {
        let date = now.addingTimeInterval(TimeInterval(-dayOffset) * 86_400)
        // Exceeds local totals for the day → produces a supplemental row.
        records.append(
            ProviderUsageRecord(
                providerName: "Factory",
                model: "test-model",
                date: date,
                inputTokens: 100_000,
                outputTokens: 50_000,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 9.99,
                requestCount: 10
            )
        )
        // Fully covered by local rows → no supplemental row.
        records.append(
            ProviderUsageRecord(
                providerName: "Cursor",
                model: "cursor-model",
                date: date,
                inputTokens: 1,
                outputTokens: 1,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 0.0001,
                requestCount: 1
            )
        )
    }
    return records
}

/// Order-insensitive, id-insensitive content key for a supplemental row
/// (the reconciliation constructor assigns fresh UUIDs on every run).
private func supplementalKey(_ usage: TokenUsage) -> String {
    [
        usage.provider.rawValue,
        usage.sessionId,
        usage.projectName,
        usage.model,
        "\(usage.inputTokens)",
        "\(usage.outputTokens)",
        "\(usage.cacheCreationTokens)",
        "\(usage.cacheReadTokens)",
        String(format: "%.12f", usage.cost),
        "\(usage.startTime.timeIntervalSince1970)",
        "\(usage.endTime.timeIntervalSince1970)"
    ].joined(separator: "|")
}

// MARK: - Bounded billing baseline == full recompute

/// The billing reconcile used to fetch EVERY `token_usage` row per refresh
/// tick as its baseline. The bounded-window baseline must produce
/// byte-identical supplemental output, and the SQL credential rollup must
/// match the in-memory reduce it replaced.
@MainActor
final class BillingReconcileBoundedBaselineTests: XCTestCase {

    func test_supplementalUsages_boundedBaselineEqualsFullBaseline() {
        let now = Date()
        let fullHistory = makeRealisticUsageHistory(now: now)
        let records = makeRealisticBillingRecords(now: now)

        // The exact bound the production closure receives: the earliest
        // window start any fetched record can match.
        let calendar = Calendar.current
        let cutoff = records.map { calendar.startOfDay(for: $0.date) }.min()!
        let boundedHistory = fullHistory.filter { $0.intersects(dateRange: cutoff...Date.distantFuture) }

        XCTAssertLessThan(boundedHistory.count, fullHistory.count, "Fixture must actually exercise the bound")
        XCTAssertTrue(
            boundedHistory.contains { $0.sessionId == "factory-long-runner" },
            "A session that STARTED outside the window but intersects it must stay in the baseline"
        )
        XCTAssertFalse(boundedHistory.contains { $0.sessionId == "factory-ancient" })

        let full = BillingUsageReconciliation.supplementalUsages(from: records, existingUsages: fullHistory)
        let bounded = BillingUsageReconciliation.supplementalUsages(from: records, existingUsages: boundedHistory)

        XCTAssertFalse(full.isEmpty, "Fixture must produce supplemental rows")
        XCTAssertEqual(
            full.map(supplementalKey).sorted(),
            bounded.map(supplementalKey).sorted(),
            "Bounded-window baseline must reproduce the full-history supplemental rows exactly"
        )
    }

    func test_driftCredentialCostTotals_sqlAggregateMatchesInMemoryReduce() async throws {
        let dataStore = try DataStoreCoordinator(
            databaseQueue: DatabaseQueue(),
            runMigrations: true,
            refreshOnInit: false
        )
        try await dataStore.insertChunked(makeRealisticUsageHistory(), chunkSize: 500)

        // Old path: materialize every row, reduce in Swift.
        let canonicalRows = try await dataStore.fetchAllUsage()
        let inMemory = BillingRefreshCoordinator.credentialCostTotals(from: canonicalRows)

        // New path: one SQL GROUP BY.
        let sql = try await dataStore.driftCredentialCostTotals()

        XCTAssertEqual(Set(sql.keys), Set(inMemory.keys))
        XCTAssertGreaterThan(sql.count, 1, "Fixture must span multiple credentials")
        for (key, value) in inMemory {
            XCTAssertEqual(sql[key] ?? .nan, value, accuracy: 1e-9, "Credential \(key) cost must match")
        }
    }

    func test_reconcile_reportsUsageRowsChanged_fromDeleteCount() async {
        // No API service configured: reconcile early-returns after the
        // cleanup step, and usageRowsChanged must reflect the delete count.
        let changed = await BillingRefreshCoordinator.reconcile(
            usageAPIService: nil,
            allParsedUsages: [],
            fetchReconciliationBaseline: { _ in XCTFail("baseline must not be fetched"); return [] },
            fetchCredentialCostTotals: { XCTFail("totals must not be fetched"); return [:] },
            persistSupplemental: { _ in XCTFail("nothing to persist") },
            deleteReconciled: { _ in 3 }
        )
        XCTAssertTrue(changed.usageRowsChanged)

        let unchanged = await BillingRefreshCoordinator.reconcile(
            usageAPIService: nil,
            allParsedUsages: [],
            fetchReconciliationBaseline: { _ in [] },
            fetchCredentialCostTotals: { [:] },
            persistSupplemental: { _ in },
            deleteReconciled: { _ in 0 }
        )
        XCTAssertFalse(unchanged.usageRowsChanged)
    }
}

// MARK: - Usage table write marker

@MainActor
final class UsageTableWriteMarkerTests: XCTestCase {

    private func makeStore() throws -> DataStoreCoordinator {
        try DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: true, refreshOnInit: false)
    }

    private func sampleUsage(
        sessionId: String = "session-1",
        provider: AgentProvider = .factory,
        cost: Double = 1.0,
        startTime: Date,
        usageSource: UsageSource = .unknown
    ) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: sessionId,
            projectName: "project",
            model: "model",
            inputTokens: 100,
            outputTokens: 200,
            costUSD: cost,
            startTime: startTime,
            endTime: startTime.addingTimeInterval(60),
            usageSource: usageSource
        )
    }

    func test_markerBumpsOnInsert_andIsStableOnIdenticalReUpsert() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = sampleUsage(startTime: start)

        let m0 = await store.usageTableWriteMarker()
        try await store.insert(usage)
        let m1 = await store.usageTableWriteMarker()
        XCTAssertGreaterThan(m1, m0, "A content-changing insert must advance the marker")

        // Re-upserting the same logical row with identical gated values is
        // exactly what an idle refresh tick does: the upsert's value-diff
        // WHERE gate suppresses the UPDATE and the marker must stay put.
        let identical = sampleUsage(startTime: start)
        try await store.insert(identical)
        let m2 = await store.usageTableWriteMarker()
        XCTAssertEqual(m2, m1, "An idle re-upsert (no value change) must NOT advance the marker")

        // A genuine correction advances it again.
        let corrected = sampleUsage(cost: 2.0, startTime: start)
        try await store.insert(corrected)
        let m3 = await store.usageTableWriteMarker()
        XCTAssertGreaterThan(m3, m2, "A value correction must advance the marker")
    }

    func test_markerBumpsOnReconcileDelete_andReportsDeletedCount() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insert(
            sampleUsage(sessionId: "api-reconcile-factory-1", startTime: start, usageSource: .billingAPI)
        )

        let m0 = await store.usageTableWriteMarker()
        let deleted = try await store.deleteUsage(sessionIDPrefix: "api-reconcile-")
        XCTAssertEqual(deleted, 1)
        let m1 = await store.usageTableWriteMarker()
        XCTAssertGreaterThan(m1, m0)

        // No-op delete: nothing left to remove, marker stays put.
        let deletedAgain = try await store.deleteUsage(sessionIDPrefix: "api-reconcile-")
        XCTAssertEqual(deletedAgain, 0)
        let m2 = await store.usageTableWriteMarker()
        XCTAssertEqual(m2, m1, "A no-op delete must NOT advance the marker")
    }

    func test_markerStableOnMarkSynced_bumpsOnDeleteAllAndRemoteInsert() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insert(sampleUsage(startTime: start))

        // markSynced only touches syncedAt, which is not part of the decoded
        // row content — no reload needed, marker stays put.
        let unsynced = try await store.fetchUnsynced()
        XCTAssertFalse(unsynced.isEmpty)
        let mBefore = await store.usageTableWriteMarker()
        try await store.markSynced(ids: unsynced.map(\.id))
        let mAfterSync = await store.usageTableWriteMarker()
        XCTAssertEqual(mAfterSync, mBefore, "markSynced must NOT advance the marker")

        let remote = TokenUsage(
            provider: .factory,
            sessionId: "remote-session",
            projectName: "project",
            model: "model",
            inputTokens: 100,
            outputTokens: 200,
            costUSD: 1.0,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            sourceDeviceId: "peer-device",
            isRemote: true
        )
        try await store.insertRemoteUsage(remote)
        let mAfterRemote = await store.usageTableWriteMarker()
        XCTAssertGreaterThan(mAfterRemote, mAfterSync, "Remote usage download must advance the marker")

        try await store.deleteAll()
        let mAfterDeleteAll = await store.usageTableWriteMarker()
        XCTAssertGreaterThan(mAfterDeleteAll, mAfterRemote)
    }
}

// MARK: - Marker-gated tick reload

@MainActor
final class ReloadUsagesIfChangedTests: XCTestCase {

    private func makeStore() throws -> DataStoreCoordinator {
        try DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: true, refreshOnInit: false)
    }

    /// A local noon, hours away from both adjacent midnights.
    private var noon: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
    }

    private func sampleUsage(seed: Int) -> TokenUsage {
        TokenUsage(
            provider: .factory,
            sessionId: "session-\(seed)",
            projectName: "project",
            model: "model",
            inputTokens: 100,
            outputTokens: 200,
            costUSD: Double(seed),
            startTime: noon.addingTimeInterval(TimeInterval(-seed * 60)),
            endTime: noon.addingTimeInterval(TimeInterval(-seed * 60) + 30)
        )
    }

    func test_firstTickAlwaysReloads() async throws {
        let store = try makeStore()
        store.nowProvider = { [noon] in noon }
        try await store.insert([sampleUsage(seed: 1), sampleUsage(seed: 2)])

        XCTAssertNil(store.debugLastReloadedUsageWriteMarkerForTesting)
        let v0 = store.usagesVersion
        await store.reloadUsagesIfChanged()

        XCTAssertEqual(store.usages.count, 2)
        XCTAssertEqual(store.usagesVersion, v0 &+ 1)
        XCTAssertNotNil(store.debugLastReloadedUsageWriteMarkerForTesting)
    }

    func test_idleTickSkipsReload_butKeepsLastRefreshFresh() async throws {
        let store = try makeStore()
        let t0 = noon
        store.nowProvider = { t0 }
        try await store.insert([sampleUsage(seed: 1)])
        await store.reloadUsagesIfChanged()
        let v1 = store.usagesVersion
        let marker1 = store.debugLastReloadedUsageWriteMarkerForTesting

        // Idle tick: no writes since the last reload, still before midnight.
        store.nowProvider = { t0.addingTimeInterval(60) }
        await store.reloadUsagesIfChanged()

        XCTAssertEqual(store.usagesVersion, v1, "An idle tick must not touch the aggregate caches")
        XCTAssertEqual(store.debugLastReloadedUsageWriteMarkerForTesting, marker1)
        XCTAssertEqual(store.lastRefresh, t0.addingTimeInterval(60), "A skipped tick still refreshes lastRefresh")
        XCTAssertEqual(store.usages.count, 1, "Skipping must not drop applied state")
    }

    func test_tickReloadsWhenMarkerAdvances() async throws {
        let store = try makeStore()
        store.nowProvider = { [noon] in noon }
        try await store.insert([sampleUsage(seed: 1)])
        await store.reloadUsagesIfChanged()
        let v1 = store.usagesVersion

        try await store.insert([sampleUsage(seed: 2)])
        await store.reloadUsagesIfChanged()

        XCTAssertEqual(store.usagesVersion, v1 &+ 1, "New content must reload and re-aggregate")
        XCTAssertEqual(store.usages.count, 2)
    }

    func test_tickReloadsAtWindowBoundary_evenWithUnchangedMarker() async throws {
        let store = try makeStore()
        let t0 = noon
        store.nowProvider = { t0 }
        try await store.insert([sampleUsage(seed: 1)])
        await store.reloadUsagesIfChanged()
        let v1 = store.usagesVersion

        // Cross the next local midnight without any content change: "Today"
        // must reset, so the boundary forces a reload + apply.
        store.nowProvider = { t0.addingTimeInterval(24 * 3_600) }
        await store.reloadUsagesIfChanged()

        XCTAssertEqual(store.usagesVersion, v1 &+ 1, "Crossing a window boundary must force the apply")
    }

    /// The load-bearing equality: the marker-gated tick path must surface the
    /// same aggregates as the dashboard snapshot init path (SQL window totals
    /// + hydration-limit covering rows). It must not `SELECT *` the ledger.
    func test_tickPathAggregatesEqualDashboardSnapshot() async throws {
        let store = try makeStore()
        store.nowProvider = { [noon] in noon }
        try await store.insertChunked(makeRealisticUsageHistory(), chunkSize: 500)

        await store.reloadUsagesIfChanged()

        let snapshot = try await store.fetchDashboardUsageSnapshot(loadedUsageLimit: 5_000)
        let expected = DashboardUsageViewModel()
        expected.replaceUsageSnapshot(snapshot)

        XCTAssertEqual(store.usages.count, snapshot.loadedUsages.count)
        let vm = store.usageViewModel
        XCTAssertEqual(vm.totalCostAllTime, expected.totalCostAllTime, accuracy: 1e-9)
        XCTAssertEqual(vm.totalCostToday, expected.totalCostToday, accuracy: 1e-9)
        XCTAssertEqual(vm.totalCostThisWeek, expected.totalCostThisWeek, accuracy: 1e-9)
        XCTAssertEqual(vm.totalCostThisMonth, expected.totalCostThisMonth, accuracy: 1e-9)
        XCTAssertEqual(vm.totalTokensAllTime, expected.totalTokensAllTime)
        XCTAssertEqual(vm.totalTokensThisWeek, expected.totalTokensThisWeek)
        XCTAssertEqual(vm.rollingDailyAverage, expected.rollingDailyAverage, accuracy: 1e-9)
        XCTAssertEqual(vm.last7DayCosts.count, expected.last7DayCosts.count)
        for (lhs, rhs) in zip(vm.last7DayCosts, expected.last7DayCosts) {
            XCTAssertEqual(lhs, rhs, accuracy: 1e-9)
        }
        XCTAssertEqual(
            vm.providerSummaries.map { "\($0.provider.rawValue):\($0.sessionCount):\($0.totalTokens)" },
            expected.providerSummaries.map { "\($0.provider.rawValue):\($0.sessionCount):\($0.totalTokens)" }
        )
        XCTAssertEqual(
            vm.modelSummaries.map { "\($0.modelName):\($0.sessionCount):\($0.totalTokens)" },
            expected.modelSummaries.map { "\($0.modelName):\($0.sessionCount):\($0.totalTokens)" }
        )
    }
}

// MARK: - Idle persist skip

@MainActor
final class UsagePersistSkipTests: XCTestCase {
    func test_persistContentFingerprint_ignoresIdentityAndCreatedAt() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let a = TokenUsage(
            id: UUID(),
            provider: .factory,
            sessionId: "session-1",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 5,
            costUSD: 1.25,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            createdAt: start
        )
        let b = TokenUsage(
            id: UUID(),
            provider: .factory,
            sessionId: "session-1",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 5,
            costUSD: 1.25,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            createdAt: start.addingTimeInterval(9)
        )
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(
            UsageStore.persistContentFingerprint([a]),
            UsageStore.persistContentFingerprint([b])
        )
        XCTAssertEqual(
            UsageStore.persistContentFingerprint([a, b]),
            UsageStore.persistContentFingerprint([b, a])
        )
    }

    func test_persistContentFingerprint_includesUpsertVisibleMetadata() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func usage(
            executionSourceName: String = "Old CLI",
            executionSourceKind: UsageExecutionSourceKind = .cli,
            executionSourceConfidence: UsageProvenanceConfidence = .lowConfidenceEstimate,
            providerAccountLabel: String = "Old account",
            providerAccountSource: ProviderAccountStorageScope = .localOnly
        ) -> TokenUsage {
            TokenUsage(
                provider: .factory,
                sessionId: "session-1",
                projectName: "p",
                model: "m",
                inputTokens: 10,
                outputTokens: 5,
                costUSD: 1.25,
                startTime: start,
                endTime: start.addingTimeInterval(60),
                executionSourceID: "factory-cli",
                executionSourceName: executionSourceName,
                executionSourceKind: executionSourceKind,
                executionSourceConfidence: executionSourceConfidence,
                providerAccountID: "account-1",
                providerAccountLabel: providerAccountLabel,
                providerAccountSource: providerAccountSource
            )
        }

        let fingerprint = UsageStore.persistContentFingerprint([usage()])
        XCTAssertNotEqual(
            fingerprint,
            UsageStore.persistContentFingerprint([usage(executionSourceName: "Current CLI")])
        )
        XCTAssertNotEqual(
            fingerprint,
            UsageStore.persistContentFingerprint([usage(executionSourceKind: .desktopApp)])
        )
        XCTAssertNotEqual(
            fingerprint,
            UsageStore.persistContentFingerprint([usage(executionSourceConfidence: .exact)])
        )
        XCTAssertNotEqual(
            fingerprint,
            UsageStore.persistContentFingerprint([usage(providerAccountLabel: "Current account")])
        )
        XCTAssertNotEqual(
            fingerprint,
            UsageStore.persistContentFingerprint([usage(providerAccountSource: .deviceKeychain)])
        )
    }

    func test_insertChunked_persistsNameAndLabelOnlyCorrection() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func usage(
            executionSourceName: String,
            providerAccountLabel: String
        ) -> TokenUsage {
            TokenUsage(
                provider: .factory,
                sessionId: "metadata-correction",
                projectName: "p",
                model: "m",
                inputTokens: 10,
                outputTokens: 5,
                costUSD: 1.25,
                startTime: start,
                endTime: start.addingTimeInterval(60),
                executionSourceID: "factory-cli",
                executionSourceName: executionSourceName,
                executionSourceKind: .cli,
                executionSourceConfidence: .lowConfidenceEstimate,
                providerAccountID: "account-1",
                providerAccountLabel: providerAccountLabel,
                providerAccountSource: .localOnly
            )
        }
        let original = usage(
            executionSourceName: "Old CLI",
            providerAccountLabel: "Old account"
        )
        let corrected = usage(
            executionSourceName: "Current desktop",
            providerAccountLabel: "Current account"
        )

        try await usageStore.insertChunked([original])
        XCTAssertFalse(usageStore.shouldSkipUnchangedPersist([corrected]))
        try await usageStore.insertChunked([corrected])

        let persisted = try await queue.read { db in
            try XCTUnwrap(UsageStore.fetchUsageRows(db: db, dateRange: nil, limit: 1).first)
        }
        XCTAssertEqual(persisted.executionSourceName, "Current desktop")
        XCTAssertEqual(persisted.executionSourceKind, original.executionSourceKind)
        XCTAssertEqual(persisted.executionSourceConfidence, original.executionSourceConfidence)
        XCTAssertEqual(persisted.providerAccountLabel, "Current account")
        XCTAssertEqual(persisted.providerAccountSource, original.providerAccountSource)
        XCTAssertEqual(persisted.executionSourceID, original.executionSourceID)
        XCTAssertEqual(persisted.totalTokens, original.totalTokens)
        XCTAssertEqual(persisted.costUSD, original.costUSD, accuracy: 0.000_000_001)
        XCTAssertEqual(persisted.startTime, original.startTime)
        XCTAssertEqual(persisted.endTime, original.endTime)
    }

    func test_insertChunked_skipsUnchangedIdleBatch() async throws {
        let queue = try DatabaseQueue(configuration: .withQueryTracing())
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let tracer = OpenBurnBarQueryTracer.shared
        let rows = makeRealisticUsageHistory()

        try await usageStore.insertChunked(rows, chunkSize: 50)
        XCTAssertTrue(usageStore.shouldSkipUnchangedPersist(rows))

        tracer.resetLog()
        try await usageStore.insertChunked(rows, chunkSize: 50)
        let inserts = tracer.queryLog.filter {
            $0.sql.uppercased().contains("INSERT INTO TOKEN_USAGE")
        }
        XCTAssertEqual(inserts.count, 0, "Idle tick must not re-issue upserts when content is unchanged")
    }

    func test_insertChunked_writesAgainWhenContentChanges() async throws {
        let queue = try DatabaseQueue(configuration: .withQueryTracing())
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let tracer = OpenBurnBarQueryTracer.shared
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = TokenUsage(
            provider: .factory,
            sessionId: "session-1",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 5,
            costUSD: 1.0,
            startTime: start,
            endTime: start.addingTimeInterval(60)
        )
        try await usageStore.insertChunked([original], chunkSize: 50)

        let corrected = TokenUsage(
            provider: .factory,
            sessionId: "session-1",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 5,
            costUSD: 2.0,
            startTime: start,
            endTime: start.addingTimeInterval(60)
        )
        XCTAssertFalse(usageStore.shouldSkipUnchangedPersist([corrected]))

        tracer.resetLog()
        try await usageStore.insertChunked([corrected], chunkSize: 50)
        let inserts = tracer.queryLog.filter {
            $0.sql.uppercased().contains("INSERT INTO TOKEN_USAGE")
        }
        XCTAssertGreaterThan(inserts.count, 0)
    }
}
