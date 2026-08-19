import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// Round-trip coverage for the store readers whose columns are not TEXT.
///
/// GRDB's untyped subscript hands back the raw SQLite *storage* value: `Int64`
/// for INTEGER, `Double` for REAL, `String` for TEXT — never `Int`, never
/// `Bool`, never `Date`. So `row["x"] as? Int` quietly yields nil on an INTEGER
/// column and `row["x"] as? Date` can never succeed at all, which is a decode
/// failure that reads as a plausible default instead of an error.
///
/// Every case here failed before the readers moved to the typed subscript.
@MainActor
final class DatabaseRowDecodingTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        return queue
    }

    // MARK: - devices.isLocal (BOOLEAN column, stored as INTEGER)

    func test_deviceRecordKeepsIsLocal() async throws {
        let store = DeviceStore(dbQueue: try makeQueue())
        try await store.upsertDevice(
            DeviceRecord(
                deviceId: "device-local",
                deviceName: "This Mac",
                isLocal: true,
                lastSeenAt: Date(timeIntervalSince1970: 1_755_000_000),
                createdAt: Date(timeIntervalSince1970: 1_754_000_000),
                hardwareModel: "Mac16,11",
                customIcon: nil
            )
        )

        // Located by id: opening the store registers this Mac's own device row,
        // so the fetch returns more than the fixture.
        let devices = try await store.fetchDevices()
        let reloaded = try XCTUnwrap(devices.first { $0.deviceId == "device-local" })
        XCTAssertTrue(reloaded.isLocal, "a local device must not reload as remote")
        XCTAssertEqual(reloaded.lastSeenAt, Date(timeIntervalSince1970: 1_755_000_000))
    }

    /// `isLocal` here is a `CASE WHEN ... THEN 1 ELSE 0 END` projection, and
    /// `totalTokens` is `SUM()` over an INTEGER column — neither is TEXT and
    /// neither survived an untyped cast.
    func test_deviceUsageSummaryDecodesTheProjectedColumns() async throws {
        let queue = try makeQueue()
        let usageStore = UsageStore(dbQueue: queue)
        let deviceStore = DeviceStore(dbQueue: queue)
        try await usageStore.insert([makeUsage(sessionId: "session-local", tokens: 1_200, cost: 1.5)])

        let summaries = try await deviceStore.deviceUsageSummaries()
        let local = try XCTUnwrap(summaries.first)
        XCTAssertTrue(local.isLocal, "a row with no sourceDeviceId is the local Mac")
        XCTAssertEqual(local.totalTokens, 1_200, "SUM over an INTEGER column must not read as zero")
        XCTAssertEqual(local.sessionCount, 1)
        XCTAssertEqual(local.totalCost, 1.5, accuracy: 0.0001)
    }

    // MARK: - Org rollup (SUM over INTEGER read as Double)

    func test_orgRollupReportsTokens() async throws {
        let queue = try makeQueue()
        let usageStore = UsageStore(dbQueue: queue)
        try await usageStore.insert([
            makeUsage(sessionId: "session-a", tokens: 900, cost: 2),
            makeUsage(sessionId: "session-b", tokens: 100, cost: 1)
        ])

        // `.allTime` so the assertion pins the decode, not the window maths.
        let rollup = try await usageStore.fetchOrgRollup(groupBy: .provider, period: .allTime)
        let row = try XCTUnwrap(rollup.first)
        XCTAssertEqual(row.totalTokens, 1_000, accuracy: 0.0001, "rollups must not report zero tokens")
        XCTAssertEqual(row.totalCost, 3, accuracy: 0.0001)
        XCTAssertEqual(row.sessionCount, 2)
    }

    // MARK: - Session facets (DATETIME columns)

    func test_sessionFacetsKeepTheirTimestamps() async throws {
        let queue = try makeQueue()
        let usageStore = UsageStore(dbQueue: queue)
        let start = Date(timeIntervalSince1970: 1_755_000_000)
        try await usageStore.insert([
            makeUsage(sessionId: "session-timed", tokens: 10, cost: 0.5, start: start)
        ])

        let facets = try await usageStore.sessionFacetsMap()
        let entry = try XCTUnwrap(facets.values.first)
        XCTAssertEqual(entry.startTime, start, "a session must keep the time it started")
        XCTAssertNotNil(entry.endTime)
        XCTAssertEqual(entry.costUSD, 0.5, accuracy: 0.0001)
    }

    // MARK: - Budget rules (DATETIME columns)

    /// `pausedUntil` is the one field that turns enforcement off, so a nil
    /// decode means a rule the user paused keeps blocking spend.
    func test_budgetRuleKeepsItsDates() async throws {
        let store = BudgetRulesStore(dbQueue: try makeQueue())
        let created = Date(timeIntervalSince1970: 1_754_000_000)
        let paused = Date(timeIntervalSince1970: 1_756_000_000)
        try await store.upsertRule(
            BudgetRule(
                id: "rule-paused",
                scope: .global,
                amountUSD: 25,
                period: .month,
                pausedUntil: paused,
                createdAt: created,
                updatedAt: created,
                syncedAt: created
            )
        )

        let reloaded = try await store.fetchRule(id: "rule-paused")
        XCTAssertEqual(reloaded?.pausedUntil, paused, "a paused rule must reload as paused")
        XCTAssertEqual(reloaded?.createdAt, created, "createdAt must not fall back to now")
        XCTAssertEqual(reloaded?.syncedAt, created)
        XCTAssertEqual(reloaded?.amountUSD, 25)
        XCTAssertEqual(reloaded?.isEnabled, true)
    }

    // MARK: - Fixtures

    private func makeUsage(
        sessionId: String,
        tokens: Int,
        cost: Double,
        start: Date = Date(timeIntervalSince1970: 1_755_000_000)
    ) -> TokenUsage {
        TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "burnbar",
            model: "sonnet-4.6",
            inputTokens: tokens,
            outputTokens: 0,
            costUSD: cost,
            startTime: start,
            endTime: start.addingTimeInterval(60)
        )
    }
}
