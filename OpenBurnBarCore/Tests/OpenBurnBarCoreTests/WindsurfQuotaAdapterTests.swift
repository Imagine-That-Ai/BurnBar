import Foundation
import XCTest
@testable import OpenBurnBarKernel
@testable import OpenBurnBarQuota
@testable import OpenBurnBarSQLiteReader

final class WindsurfQuotaAdapterTests: XCTestCase {
    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeContext(root: URL) -> ProviderQuotaAdapterContext {
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: root)
        return ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: .default,
            session: URLSession(configuration: .ephemeral),
            environment: [:],
            homeDirectoryURL: root,
            snapshotStore: StubQuotaSnapshotStore(),
            bridgeManager: StubClaudeBridge(),
            miniMaxMode: .tokenPlan,
            factoryPlan: .pro,
            xaiPlan: .unknown,
            mimoTokenPlanRegion: .sgp,
            mimoTokenPlanTier: nil,
            mimoTokenPlanBillingCycle: .monthly,
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: [:]
        )
    }

    private func createVscdb(at path: String, payloadJSON: String) throws {
        let reader = try SQLiteConnection.openForWriting(creatingAt: path)
        defer { reader.close() }

        try reader.execute("""
            CREATE TABLE ItemTable (
                key TEXT PRIMARY KEY,
                value TEXT
            );
        """)

        try reader.execute(
            "INSERT INTO ItemTable (key, value) VALUES ('windsurf.settings.cachedPlanInfo', ?);",
            arguments: [.text(payloadJSON)]
        )
    }

    func test_fetch_parsesFullPlanInfoWithAllBuckets() async throws {
        let dir = try makeTemporaryDirectory("windsurf-full")
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("state.vscdb").path
        let jsonPayload = """
        {
            "planName": "Windsurf Pro",
            "quotaUsage": {
                "dailyRemainingPercent": 75.0,
                "dailyResetAtUnix": 1780000000,
                "weeklyRemainingPercent": 40.0,
                "weeklyResetAtUnix": 1780500000
            },
            "usage": {
                "flexCredits": 100.0,
                "usedFlexCredits": 25.0,
                "remainingFlexCredits": 75.0,
                "flowActions": 500.0,
                "usedFlowActions": 100.0,
                "remainingFlowActions": 400.0
            }
        }
        """
        try createVscdb(at: dbPath, payloadJSON: jsonPayload)

        let adapter = WindsurfQuotaAdapter(vscdbPathOverride: dbPath)
        let context = makeContext(root: dir)

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, "Windsurf")
        XCTAssertEqual(snapshot.sourceKind, .localSession)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(snapshot.buckets.count, 4)

        // Daily bucket
        let daily = try XCTUnwrap(snapshot.buckets.first { $0.key == "windsurf-daily" })
        XCTAssertEqual(daily.usedPercent, 25.0)
        XCTAssertEqual(daily.remainingValue, 75.0)
        XCTAssertEqual(daily.resetsAt, Date(timeIntervalSince1970: 1780000000))
        XCTAssertEqual(daily.unit, .percent)

        // Weekly bucket
        let weekly = try XCTUnwrap(snapshot.buckets.first { $0.key == "windsurf-weekly" })
        XCTAssertEqual(weekly.usedPercent, 60.0)
        XCTAssertEqual(weekly.remainingValue, 40.0)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1780500000))
        XCTAssertEqual(weekly.unit, .percent)

        // Flex credits
        let flex = try XCTUnwrap(snapshot.buckets.first { $0.key == "windsurf-flex-credits" })
        XCTAssertEqual(flex.limitValue, 100.0)
        XCTAssertEqual(flex.usedValue, 25.0)
        XCTAssertEqual(flex.remainingValue, 75.0)
        XCTAssertEqual(flex.usedPercent, 25.0)
        XCTAssertEqual(flex.unit, .credits)

        // Flow actions
        let flow = try XCTUnwrap(snapshot.buckets.first { $0.key == "windsurf-flow-actions" })
        XCTAssertEqual(flow.limitValue, 500.0)
        XCTAssertEqual(flow.usedValue, 100.0)
        XCTAssertEqual(flow.remainingValue, 400.0)
        XCTAssertEqual(flow.usedPercent, 20.0)
        XCTAssertEqual(flow.unit, .requests)
    }

    func test_fetch_handlesMissingOrEmptyDatabaseGracefully() async throws {
        let dir = try makeTemporaryDirectory("windsurf-empty")
        defer { try? FileManager.default.removeItem(at: dir) }

        let adapter = WindsurfQuotaAdapter(vscdbPathOverride: "/nonexistent/path/to/state.vscdb")
        let context = makeContext(root: dir)

        let snapshot = try await adapter.fetch(context: context)
        XCTAssertEqual(snapshot.provider, "Windsurf")
        XCTAssertEqual(snapshot.sourceKind, .unavailable)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
    }

    func test_fetch_handlesCorruptedJSONGracefully() async throws {
        let dir = try makeTemporaryDirectory("windsurf-corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("state.vscdb").path
        try createVscdb(at: dbPath, payloadJSON: "NOT_VALID_JSON{;;;}")

        let adapter = WindsurfQuotaAdapter(vscdbPathOverride: dbPath)
        let context = makeContext(root: dir)

        let snapshot = try await adapter.fetch(context: context)
        XCTAssertEqual(snapshot.sourceKind, .unavailable)
    }
}

private struct StubQuotaSnapshotStore: ProviderQuotaSnapshotPersisting {
    func loadScratchString(forKey key: String) -> String? { nil }
    func saveScratchString(_ value: String, forKey key: String) {}
    func readJSONObject(from url: URL) throws -> [String: Any]? { nil }
}

private struct StubClaudeBridge: ClaudeQuotaBridgeManaging {
    func installClaudeQuotaBridge() throws {}
    func refreshClaudeBridgeStatus() -> ClaudeQuotaBridgeStatus {
        ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "", lastPayloadAt: nil)
    }
}
