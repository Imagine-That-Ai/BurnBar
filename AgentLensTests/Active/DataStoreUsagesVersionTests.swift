import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore

@MainActor
final class DataStoreUsagesVersionTests: XCTestCase {

    private func makeStore() throws -> DataStoreCoordinator {
        try DataStoreCoordinator(
            databaseQueue: DatabaseQueue(),
            runMigrations: true,
            refreshOnInit: false
        )
    }

    private func sampleUsage(seed: Int = 0) -> TokenUsage {
        TokenUsage(
            provider: .factory,
            sessionId: "session-\(seed)",
            projectName: "project",
            model: "model",
            inputTokens: 100,
            outputTokens: 200,
            costUSD: Double(seed),
            startTime: Date().addingTimeInterval(TimeInterval(seed)),
            endTime: Date().addingTimeInterval(TimeInterval(seed + 60))
        )
    }

    func testUsagesVersion_startsAtZero() throws {
        let store = try makeStore()
        XCTAssertEqual(store.usagesVersion, 0)
    }

    func testUsagesVersion_bumpsOnReplaceUsages() throws {
        let store = try makeStore()
        let before = store.usagesVersion
        store.replaceUsages([sampleUsage(seed: 1)])
        XCTAssertEqual(store.usagesVersion, before &+ 1)
    }

    /// A local noon, so boundary tests sit hours away from both the
    /// previous and the next midnight.
    private var noon: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
    }

    /// Deliberate inversion of the original always-bump contract
    /// (`testUsagesVersion_bumpsOnEachReplaceUsagesCall_evenWithIdenticalData`):
    /// a content-identical replacement before the next window boundary is a
    /// no-op for every rendered aggregate, so it must NOT invalidate the
    /// dashboard caches. See `UsageReplaceGate` and
    /// docs/architecture/macos-performance.md §14.
    func testUsagesVersion_skipsBumpOnContentIdenticalReplaceUsages() throws {
        let store = try makeStore()
        let usages = [sampleUsage(seed: 1)]
        let v0 = store.usagesVersion
        store.nowProvider = { [noon] in noon }
        store.replaceUsages(usages)
        let v1 = store.usagesVersion
        store.replaceUsages(usages)
        let v2 = store.usagesVersion

        XCTAssertEqual(v1, v0 &+ 1)
        XCTAssertEqual(v2, v1, "Identical content before a window boundary must not bump usagesVersion")
        XCTAssertEqual(store.usages, usages.sorted { $0.startTime > $1.startTime })
    }

    func testUsagesVersion_skipStillUpdatesLastRefresh() throws {
        let store = try makeStore()
        let usages = [sampleUsage(seed: 1)]
        let t0 = noon
        store.nowProvider = { t0 }
        store.replaceUsages(usages)
        XCTAssertEqual(store.lastRefresh, t0)

        store.nowProvider = { t0.addingTimeInterval(60) }
        store.replaceUsages(usages)
        XCTAssertEqual(store.lastRefresh, t0.addingTimeInterval(60))
    }

    func testUsagesVersion_bumpsWhenContentChanges_afterASkip() throws {
        let store = try makeStore()
        let usages = [sampleUsage(seed: 1)]
        store.nowProvider = { [noon] in noon }
        store.replaceUsages(usages)
        store.replaceUsages(usages) // skipped
        let beforeChange = store.usagesVersion

        store.replaceUsages(usages + [sampleUsage(seed: 2)])
        XCTAssertEqual(store.usagesVersion, beforeChange &+ 1)
    }

    func testUsagesVersion_orderInsensitiveContentEqualityStillSkips() throws {
        let store = try makeStore()
        let first = sampleUsage(seed: 1)
        let second = sampleUsage(seed: 2)
        store.nowProvider = { [noon] in noon }
        store.replaceUsages([first, second])
        let v1 = store.usagesVersion

        // The two replace paths deliver rows in different orderings; same
        // content in a different order is still a no-op.
        store.replaceUsages([second, first])
        XCTAssertEqual(store.usagesVersion, v1)
    }

    func testUsagesVersion_identicalContentAppliesAgainAcrossMidnightBoundary() throws {
        let store = try makeStore()
        let usages = [sampleUsage(seed: 1)]
        let t0 = noon
        store.nowProvider = { t0 }
        store.replaceUsages(usages)
        let v1 = store.usagesVersion

        // Same rows, but the clock has crossed the next local midnight —
        // the bump is load-bearing for the "Today" reset, so the apply must
        // go through.
        store.nowProvider = { t0.addingTimeInterval(2 * 86_400) }
        store.replaceUsages(usages)
        XCTAssertEqual(store.usagesVersion, v1 &+ 1)
    }

    func testUsagesVersion_identicalContentAppliesAgainWhenRowExitsRollingWindow() throws {
        let store = try makeStore()
        let t0 = noon
        // A row two hours from exiting the rolling 7-day window: its
        // (margin-adjusted) exit at t0+1h lands before the next midnight,
        // so the row's decay — not midnight — is the forcing boundary.
        let nearExit = TokenUsage(
            provider: .factory,
            sessionId: "session-old",
            projectName: "project",
            model: "model",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: 1,
            startTime: t0.addingTimeInterval(-7 * 86_400 + 2 * 3_600),
            endTime: t0.addingTimeInterval(-7 * 86_400 + 2 * 3_600 + 60)
        )
        store.nowProvider = { t0 }
        store.replaceUsages([nearExit])
        let v1 = store.usagesVersion

        // Within the boundary: skip.
        store.nowProvider = { t0.addingTimeInterval(60) }
        store.replaceUsages([nearExit])
        XCTAssertEqual(store.usagesVersion, v1)

        // Past the row's window exit: forced apply so the 7d totals decay.
        store.nowProvider = { t0.addingTimeInterval(3 * 3_600) }
        store.replaceUsages([nearExit])
        XCTAssertEqual(store.usagesVersion, v1 &+ 1)
    }

    func testUsagesVersion_bumpsOnReplaceUsageSnapshot() throws {
        let store = try makeStore()
        let before = store.usagesVersion

        let snapshot = DashboardUsageSnapshot(
            loadedUsages: [sampleUsage(seed: 1)],
            windowSummaries: [:],
            rollingDailyAverage: 0,
            distinctUsageDayCount: 0,
            last7DayCosts: Array(repeating: 0.0, count: 7),
            last7DayTokenTotals: Array(repeating: 0, count: 7),
            dailySummaries: [],
            topProviderToday: nil
        )
        store.replaceUsageSnapshot(snapshot)
        XCTAssertEqual(store.usagesVersion, before &+ 1)
    }

    func testUsagesVersion_monotonicAcrossManyReplaceCalls() throws {
        let store = try makeStore()
        let initial = store.usagesVersion
        for i in 1...50 {
            store.replaceUsages([sampleUsage(seed: i)])
        }
        XCTAssertEqual(store.usagesVersion, initial &+ 50)
    }
}
