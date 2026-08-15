import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OpenBurnBarKernel
@testable import OpenBurnBarLogParsers
@testable import OpenBurnBarQuota

final class KiloCodeQuotaCacheTests: XCTestCase {
    func test_fetch_skipsUnchangedTaskJSONOnSecondPass() async throws {
        let root = try makeTemporaryDirectory("kilo-quota-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let tasks = root.appendingPathComponent("tasks", isDirectory: true)
        try writeTask(
            id: "task-a",
            in: tasks,
            bodyText: "conversation body must not be cached",
            tokensIn: 10,
            tokensOut: 4,
            cacheWrites: 1,
            cacheReads: 2,
            cost: 0.0123
        )
        try writeTask(
            id: "task-b",
            in: tasks,
            bodyText: "second task body",
            tokensIn: 5,
            tokensOut: 1,
            cacheWrites: 0,
            cacheReads: 0,
            cost: 0.004
        )

        let adapter = KiloCodeQuotaAdapter(
            tasksDirectoryOverride: tasks,
            cacheURLOverride: root.appendingPathComponent("kilo-cache.plist")
        )
        let context = makeContext(root: root)

        let first = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 2)
        XCTAssertEqual(try XCTUnwrap(tokenBucket(in: first)?.usedValue), 23.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(taskBucket(in: first)?.usedValue), 2.0, accuracy: 0.0001)
        XCTAssertTrue(try XCTUnwrap(first.statusMessage).contains("2 tasks"))

        let second = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(tokenBucket(in: second)?.usedValue),
            try XCTUnwrap(tokenBucket(in: first)?.usedValue),
            accuracy: 0.0001
        )
        XCTAssertEqual(second.statusMessage, first.statusMessage)

        let cacheData = try Data(contentsOf: root.appendingPathComponent("kilo-cache.plist"))
        let cacheText = String(decoding: cacheData, as: UTF8.self)
        XCTAssertFalse(cacheText.contains("conversation body must not be cached"))
        XCTAssertFalse(cacheText.contains("second task body"))
    }

    func test_fetch_rereadsOnlyChangedTaskJSON() async throws {
        let root = try makeTemporaryDirectory("kilo-quota-append")
        defer { try? FileManager.default.removeItem(at: root) }
        let tasks = root.appendingPathComponent("tasks", isDirectory: true)
        try writeTask(
            id: "task-a",
            in: tasks,
            bodyText: "stable",
            tokensIn: 8,
            tokensOut: 2,
            cacheWrites: 0,
            cacheReads: 0,
            cost: 0.01
        )
        try writeTask(
            id: "task-b",
            in: tasks,
            bodyText: "will change",
            tokensIn: 1,
            tokensOut: 1,
            cacheWrites: 0,
            cacheReads: 0,
            cost: 0.001
        )

        let adapter = KiloCodeQuotaAdapter(
            tasksDirectoryOverride: tasks,
            cacheURLOverride: root.appendingPathComponent("kilo-cache.plist")
        )
        let context = makeContext(root: root)
        _ = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 2)

        try writeTask(
            id: "task-b",
            in: tasks,
            bodyText: "changed body",
            tokensIn: 9,
            tokensOut: 3,
            cacheWrites: 0,
            cacheReads: 0,
            cost: 0.02
        )

        let third = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 1)
        XCTAssertEqual(try XCTUnwrap(tokenBucket(in: third)?.usedValue), 22.0, accuracy: 0.0001)
    }

    private func tokenBucket(in snapshot: ProviderQuotaSnapshot) -> ProviderQuotaBucket? {
        snapshot.buckets.first { $0.key == "kilo-tokens" }
    }

    private func taskBucket(in snapshot: ProviderQuotaSnapshot) -> ProviderQuotaBucket? {
        snapshot.buckets.first { $0.key == "kilo-tasks" }
    }

    private func writeTask(
        id: String,
        in tasks: URL,
        bodyText: String,
        tokensIn: Int,
        tokensOut: Int,
        cacheWrites: Int,
        cacheReads: Int,
        cost: Double
    ) throws {
        let dir = tasks.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let apiReq = """
        {"tokensIn":\(tokensIn),"tokensOut":\(tokensOut),"cacheWrites":\(cacheWrites),"cacheReads":\(cacheReads),"cost":\(cost)}
        """
        let escaped = apiReq.replacingOccurrences(of: "\"", with: "\\\"")
        let json = """
        [
          {"type":"say","say":"text","text":"\(bodyText)"},
          {"type":"say","say":"api_req_started","text":"\(escaped)"}
        ]
        """
        try json.write(to: dir.appendingPathComponent("ui_messages.json"), atomically: true, encoding: .utf8)
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
            factoryPlan: .unknown,
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
