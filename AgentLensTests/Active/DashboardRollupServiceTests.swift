import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - DashboardRollupServiceTests (Wave 2.8)

/// The dashboard reload serves materialized per-window rollups from the
/// `dashboard_rollups` retrieval-health row when fresh (write marker match +
/// window boundary intact), and recomputes once + persists when stale.
///
/// These tests pin: (1) the materialized snapshot is identical to the live
/// GROUP BY snapshot for the same ledger state; (2) freshness flips exactly
/// on content change / boundary pass / corrupt payload; (3) the fresh path
/// skips the health rewrite; (4) the fresh path runs a constant number of
/// queries at any usage volume — including the 5GB-scale fixture (44,581
/// usage rows, matching the real August 2026 dataset's cardinality).
@MainActor
final class DashboardRollupServiceTests: XCTestCase {

    // MARK: - Materialize + equality

    func test_snapshot_materializesOnColdCacheAndPersistsHealth() async throws {
        let now = Date()
        let store = try makeRollupStore()
        try await store.insertChunked(makeRollupFixtureUsages(now: now), chunkSize: 500)
        let boundary = now.addingTimeInterval(3_600)

        let snapshot = try await DashboardRollupService(
            dataStore: store,
            nowProvider: { now }
        ).snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)

        let live = try await store.fetchDashboardUsageSnapshotWithParts(loadedUsageLimit: 100, now: now).snapshot
        assertSnapshotsEqual(snapshot, live)

        let health = try await store.fetchRetrievalHealth().first(where: { $0.subsystem == .dashboardRollups })
        XCTAssertEqual(health?.status, .healthy)
        XCTAssertNil(health?.errorCode)
        let payload = try XCTUnwrap(decodePayload(from: health))
        XCTAssertEqual(payload.schemaVersion, MaterializedDashboardRollupPayload.currentSchemaVersion)
        let marker = await store.usageTableWriteMarker()
        XCTAssertEqual(payload.writeMarker, marker)
        XCTAssertEqual(payload.windowBoundary, boundary)
    }

    func test_snapshot_freshPathMatchesLiveSnapshot() async throws {
        let now = Date()
        let store = try makeRollupStore()
        try await store.insertChunked(makeRollupFixtureUsages(now: now), chunkSize: 500)
        let boundary = now.addingTimeInterval(3_600)
        let service = DashboardRollupService(dataStore: store, nowProvider: { now })

        _ = try await service.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)
        let fresh = try await service.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)
        let live = try await store.fetchDashboardUsageSnapshotWithParts(loadedUsageLimit: 100, now: now).snapshot

        assertSnapshotsEqual(fresh, live)
    }

    // MARK: - Freshness

    func test_snapshot_staleAfterContentChange() async throws {
        let now = Date()
        let store = try makeRollupStore()
        try await store.insertChunked(makeRollupFixtureUsages(now: now), chunkSize: 500)
        let boundary = now.addingTimeInterval(3_600)
        let service = DashboardRollupService(dataStore: store, nowProvider: { now })
        _ = try await service.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)

        try await store.insertChunked(
            [makeUsage(sessionId: "rollup-newcomer", costUSD: 7.5, startTime: now, provider: .cursor)],
            chunkSize: 500
        )

        await XCTAssertThrowsErrorAsync(
            {
                try await service.snapshotAsync(
                    loadedUsageLimit: 100,
                    windowBoundary: boundary,
                    refreshIfStale: false
                )
            },
            { error in
                XCTAssertEqual(error as? DashboardRollupServiceError, .staleRollupsRefreshDisabled)
            }
        )

        let refreshed = try await service.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)
        let live = try await store.fetchDashboardUsageSnapshotWithParts(loadedUsageLimit: 100, now: now).snapshot
        assertSnapshotsEqual(refreshed, live)
        let allTime = try XCTUnwrap(refreshed.windowSummaries[.allTime])
        XCTAssertEqual(allTime.totalCost, 0.9 + 0.5 + 7.5, accuracy: 1e-9)
    }

    func test_snapshot_staleAfterBoundaryPass() async throws {
        let t0 = Date()
        let store = try makeRollupStore()
        try await store.insertChunked(makeRollupFixtureUsages(now: t0), chunkSize: 500)
        let boundary = t0.addingTimeInterval(3_600)
        let materializer = DashboardRollupService(dataStore: store, nowProvider: { t0 })
        _ = try await materializer.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)

        // Same ledger, but the clock passed the window boundary: the rolling
        // windows decayed, so the payload must read stale even though the
        // marker is unchanged.
        let t1 = t0.addingTimeInterval(7_200)
        let reader = DashboardRollupService(dataStore: store, nowProvider: { t1 })
        await XCTAssertThrowsErrorAsync(
            {
                try await reader.snapshotAsync(
                    loadedUsageLimit: 100,
                    windowBoundary: boundary,
                    refreshIfStale: false
                )
            },
            { error in
                XCTAssertEqual(error as? DashboardRollupServiceError, .staleRollupsRefreshDisabled)
            }
        )

        let refreshed = try await reader.snapshotAsync(
            loadedUsageLimit: 100,
            windowBoundary: t1.addingTimeInterval(3_600)
        )
        let live = try await store.fetchDashboardUsageSnapshotWithParts(loadedUsageLimit: 100, now: t1).snapshot
        assertSnapshotsEqual(refreshed, live)
    }

    func test_snapshot_corruptPayloadReadsStale() async throws {
        let now = Date()
        let store = try makeRollupStore()
        try await store.insertChunked(makeRollupFixtureUsages(now: now), chunkSize: 500)
        let boundary = now.addingTimeInterval(3_600)
        let service = DashboardRollupService(dataStore: store, nowProvider: { now })
        _ = try await service.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)

        try await store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .dashboardRollups,
                status: .healthy,
                detailsJSON: "{not valid json",
                observedAt: now,
                updatedAt: now
            )
        )

        await XCTAssertThrowsErrorAsync(
            {
                try await service.snapshotAsync(
                    loadedUsageLimit: 100,
                    windowBoundary: boundary,
                    refreshIfStale: false
                )
            },
            { error in
                XCTAssertEqual(error as? DashboardRollupServiceError, .staleRollupsRefreshDisabled)
            }
        )

        // Refresh heals: recompute + persist a valid payload.
        _ = try await service.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)
        let health = try await store.fetchRetrievalHealth().first(where: { $0.subsystem == .dashboardRollups })
        XCTAssertEqual(health?.status, .healthy)
        XCTAssertNotNil(decodePayload(from: health))
    }

    func test_snapshot_skipsHealthWriteWhenFresh() async throws {
        let now = Date()
        let store = try makeRollupStore()
        try await store.insertChunked(makeRollupFixtureUsages(now: now), chunkSize: 500)
        let boundary = now.addingTimeInterval(3_600)
        let service = DashboardRollupService(dataStore: store, nowProvider: { now })
        _ = try await service.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)

        let firstHealth = try await store.fetchRetrievalHealth()
        let firstRow = try XCTUnwrap(firstHealth.first(where: { $0.subsystem == .dashboardRollups }))

        _ = try await service.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)

        let secondHealth = try await store.fetchRetrievalHealth()
        let secondRow = try XCTUnwrap(secondHealth.first(where: { $0.subsystem == .dashboardRollups }))
        XCTAssertEqual(
            secondRow.observedAt,
            firstRow.observedAt,
            "A fresh snapshot must not rewrite an unchanged health row"
        )
        XCTAssertEqual(secondRow.detailsJSON, firstRow.detailsJSON)
        XCTAssertEqual(secondRow.status, .healthy)
    }

    // MARK: - Constant query count (the live-function perf budget)

    func test_snapshotQueryCount_isIndependentOfUsageVolume() async throws {
        let now = Date()
        let tracer = OpenBurnBarQueryTracer.shared

        let smallStore = try makeTracedRollupStore()
        try await smallStore.insertChunked(makeRollupFixtureUsages(now: now), chunkSize: 500)
        let smallService = DashboardRollupService(dataStore: smallStore, nowProvider: { now })
        let boundary = now.addingTimeInterval(3_600)
        // Warm-up materialization absorbs GRDB's one-time schema introspection.
        _ = try await smallService.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)

        tracer.resetLog()
        _ = try await smallService.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)
        let baseline = tracer.queryCount
        XCTAssertGreaterThan(baseline, 0, "Query tracer recorded nothing — tracing is not installed")

        // 10x the usages in a second store: the fresh path reads one health
        // row + one bounded covering scan, so the statement count must not
        // grow with usage volume.
        let bigStore = try makeTracedRollupStore()
        var bigFixture = makeRollupFixtureUsages(now: now)
        bigFixture += makeVolumeUsages(count: 20, after: now.addingTimeInterval(-86_400))
        try await bigStore.insertChunked(bigFixture, chunkSize: 500)
        let bigService = DashboardRollupService(dataStore: bigStore, nowProvider: { now })
        _ = try await bigService.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)

        tracer.resetLog()
        _ = try await bigService.snapshotAsync(loadedUsageLimit: 100, windowBoundary: boundary)

        XCTAssertEqual(
            tracer.queryCount,
            baseline,
            "Fresh dashboard reload must run a constant number of queries — growth with usage volume is an N+1 regression"
        )
        tracer.assertMaxQueries(count: 16)
        XCTAssertLessThanOrEqual(tracer.queryCount, 16)
    }

    // MARK: - 5GB-scale fixture + reload p95

    /// Scale proof at the real dataset's cardinality: the August 2026
    /// protected DB was ~5.49 GB with 44,581 usage rows. A fresh reload over
    /// that many rows must run the same constant queries as the small
    /// fixture, and the reload p95 is printed for the perf-doc record.
    func test_reload_queryCountConstantAtScaleAndRecordP95() async throws {
        let now = Date()
        let tracer = OpenBurnBarQueryTracer.shared
        let store = try makeTracedRollupStore()

        var fixture: [TokenUsage] = []
        fixture.reserveCapacity(44_581)
        // ~120 days of history across providers/models, mirroring the real
        // dataset's shape (steady daily sessions + a long runner).
        for dayOffset in 1...120 {
            let start = now.addingTimeInterval(TimeInterval(-dayOffset) * 86_400)
            for slot in 0..<300 {
                fixture.append(
                    makeUsage(
                        sessionId: "scale-day-\(dayOffset)-\(slot)",
                        costUSD: 0.05 + Double((dayOffset + slot) % 50) * 0.01,
                        startTime: start.addingTimeInterval(TimeInterval(slot * 137)),
                        provider: (dayOffset + slot) % 3 == 0 ? .cursor : .factory,
                        model: "scale-model-\((dayOffset + slot) % 7)"
                    )
                )
            }
        }
        // Long runner spanning the windows (intersection edge case).
        fixture.append(
            TokenUsage(
                provider: .factory,
                sessionId: "scale-long-runner",
                projectName: "marathon",
                model: "scale-model-0",
                inputTokens: 50_000,
                outputTokens: 25_000,
                costUSD: 12.5,
                startTime: now.addingTimeInterval(-45 * 86_400),
                endTime: now.addingTimeInterval(-10 * 86_400)
            )
        )
        // Recent rows inside the bounded windows.
        for slot in 0..<8_580 {
            let start = now.addingTimeInterval(TimeInterval(-slot * 37))
            fixture.append(
                makeUsage(
                    sessionId: "scale-recent-\(slot)",
                    costUSD: 0.11,
                    startTime: start,
                    provider: slot % 2 == 0 ? .claudeCode : .codex
                )
            )
        }
        XCTAssertEqual(fixture.count, 44_581, "Fixture must match the real 5GB dataset's usage-row cardinality")

        try await store.insertChunked(fixture, chunkSize: 1_000)
        let boundary = now.addingTimeInterval(3_600)
        let service = DashboardRollupService(dataStore: store, nowProvider: { now })

        // Stale-path reload at scale (the full GROUP BY fan-out), timed for
        // the perf-doc contrast with the fresh path.
        let staleStart = CFAbsoluteTimeGetCurrent()
        let materialized = try await service.snapshotAsync(loadedUsageLimit: 5_000, windowBoundary: boundary)
        let staleMs = (CFAbsoluteTimeGetCurrent() - staleStart) * 1_000
        print("DASHBOARD_ROLLUP_STALE_RELOAD_MS=\(String(format: "%.1f", staleMs)) rows=\(fixture.count)")

        // Correctness at scale: fresh path matches the live snapshot.
        let live = try await store.fetchDashboardUsageSnapshotWithParts(loadedUsageLimit: 5_000, now: now).snapshot
        assertSnapshotsEqual(materialized, live)

        // Fresh-path reloads: constant queries + p95 latency record.
        var latenciesMs: [Double] = []
        latenciesMs.reserveCapacity(21)
        var queryCounts: Set<Int> = []
        for _ in 0..<21 {
            tracer.resetLog()
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await service.snapshotAsync(loadedUsageLimit: 5_000, windowBoundary: boundary)
            latenciesMs.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            queryCounts.insert(tracer.queryCount)
        }
        XCTAssertEqual(
            queryCounts.count,
            1,
            "Fresh reload query count must be identical across runs at scale (saw \(queryCounts.sorted()))"
        )
        let sorted = latenciesMs.sorted()
        let p95Index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))
        let p95 = sorted[p95Index]
        let p50 = sorted[sorted.count / 2]
        print(
            "DASHBOARD_ROLLUP_FRESH_RELOAD_MS p50=\(String(format: "%.1f", p50))" +
                " p95=\(String(format: "%.1f", p95)) queries=\(queryCounts.first ?? -1) rows=\(fixture.count)"
        )
        tracer.assertMaxQueries(count: 16)
    }

    // MARK: - Helpers

    private func makeRollupStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeTracedRollupStore() throws -> DataStore {
        let queue = try DatabaseQueue(configuration: .withQueryTracing())
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func decodePayload(from record: RetrievalHealthRecord?) -> MaterializedDashboardRollupPayload? {
        guard let json = record?.detailsJSON?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MaterializedDashboardRollupPayload.self, from: json) // try?-ok(test cache decode)
    }

    private func makeUsage(
        sessionId: String,
        costUSD: Double,
        startTime: Date,
        provider: AgentProvider = .factory,
        model: String = "test-model"
    ) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: sessionId,
            projectName: "rollup-fixture",
            model: model,
            inputTokens: 1_000,
            outputTokens: 500,
            costUSD: costUSD,
            startTime: startTime,
            endTime: startTime.addingTimeInterval(600)
        )
    }

    private func makeRollupFixtureUsages(now: Date) -> [TokenUsage] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        return [
            makeUsage(
                sessionId: "rollup-yesterday",
                costUSD: 0.9,
                startTime: yesterdayStart.addingTimeInterval(120)
            ),
            TokenUsage(
                provider: .claudeCode,
                sessionId: "rollup-today",
                projectName: "rollup-fixture",
                model: "claude-sonnet",
                inputTokens: 24,
                outputTokens: 16,
                costUSD: 0.5,
                startTime: todayStart.addingTimeInterval(120),
                endTime: todayStart.addingTimeInterval(180)
            )
        ]
    }

    /// Usages spread over the day before `date` (all inside the trailer
    /// windows, none advancing the fixture clock).
    private func makeVolumeUsages(count: Int, after date: Date) -> [TokenUsage] {
        (0..<count).map { index in
            makeUsage(
                sessionId: "rollup-volume-\(Int(date.timeIntervalSince1970))-\(index)",
                costUSD: 0.1,
                startTime: date.addingTimeInterval(Double(index * 60))
            )
        }
    }

    /// Total-equality between a served snapshot and the live GROUP BY
    /// snapshot: every window's totals, the day series, the rolling average,
    /// the daily summaries, the top provider, and the covering identity set.
    private func assertSnapshotsEqual(
        _ served: DashboardUsageSnapshot,
        _ live: DashboardUsageSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(served.loadedUsages.map(\.sessionId), live.loadedUsages.map(\.sessionId), file: file, line: line)
        for range in TimeRange.allCases {
            let servedSummary = served.windowSummaries[range]
            let liveSummary = live.windowSummaries[range]
            XCTAssertNotNil(servedSummary, "\(range.rawValue) missing from served snapshot", file: file, line: line)
            XCTAssertNotNil(liveSummary, "\(range.rawValue) missing from live snapshot", file: file, line: line)
            guard let servedSummary, let liveSummary else { continue }
            XCTAssertEqual(servedSummary.totalCost, liveSummary.totalCost, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(servedSummary.totalTokens, liveSummary.totalTokens, file: file, line: line)
            XCTAssertEqual(servedSummary.sessionCount, liveSummary.sessionCount, file: file, line: line)
            XCTAssertEqual(
                servedSummary.activeProviderCount,
                liveSummary.activeProviderCount,
                file: file,
                line: line
            )
            XCTAssertEqual(
                servedSummary.providerSummaries.map(\.provider),
                liveSummary.providerSummaries.map(\.provider),
                file: file,
                line: line
            )
            for (servedProvider, liveProvider) in zip(
                servedSummary.providerSummaries,
                liveSummary.providerSummaries
            ) {
                XCTAssertEqual(servedProvider.totalCost, liveProvider.totalCost, accuracy: 1e-9, file: file, line: line)
                XCTAssertEqual(
                    servedProvider.totalTokens,
                    liveProvider.totalTokens,
                    file: file,
                    line: line
                )
            }
            XCTAssertEqual(
                servedSummary.modelSummaries.map(\.modelName),
                liveSummary.modelSummaries.map(\.modelName),
                file: file,
                line: line
            )
        }
        XCTAssertEqual(served.rollingDailyAverage, live.rollingDailyAverage, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(served.distinctUsageDayCount, live.distinctUsageDayCount, file: file, line: line)
        XCTAssertEqual(served.last7DayCosts.count, live.last7DayCosts.count, file: file, line: line)
        for (servedCost, liveCost) in zip(served.last7DayCosts, live.last7DayCosts) {
            XCTAssertEqual(servedCost, liveCost, accuracy: 1e-9, file: file, line: line)
        }
        XCTAssertEqual(served.last7DayTokenTotals, live.last7DayTokenTotals, file: file, line: line)
        XCTAssertEqual(served.dailySummaries.count, live.dailySummaries.count, file: file, line: line)
        for (servedDay, liveDay) in zip(served.dailySummaries, live.dailySummaries) {
            XCTAssertEqual(servedDay.totalCost, liveDay.totalCost, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(servedDay.totalTokens, liveDay.totalTokens, file: file, line: line)
            XCTAssertEqual(servedDay.provider, liveDay.provider, file: file, line: line)
        }
        XCTAssertEqual(served.topProviderToday?.provider, live.topProviderToday?.provider, file: file, line: line)
        if let servedCost = served.topProviderToday?.cost, let liveCost = live.topProviderToday?.cost {
            XCTAssertEqual(servedCost, liveCost, accuracy: 1e-9, file: file, line: line)
        } else {
            XCTAssertNil(served.topProviderToday, file: file, line: line)
            XCTAssertNil(live.topProviderToday, file: file, line: line)
        }
    }
}

/// Async variant of `XCTAssertThrowsError` (XCTest has no async form).
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
