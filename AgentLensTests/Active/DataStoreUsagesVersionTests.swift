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

    func testUsagesVersion_bumpsOnEachReplaceUsagesCall_evenWithIdenticalData() throws {
        let store = try makeStore()
        let usages = [sampleUsage(seed: 1)]
        let v0 = store.usagesVersion
        store.replaceUsages(usages)
        let v1 = store.usagesVersion
        store.replaceUsages(usages)
        let v2 = store.usagesVersion

        XCTAssertEqual(v1, v0 &+ 1)
        XCTAssertEqual(v2, v0 &+ 2)
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
