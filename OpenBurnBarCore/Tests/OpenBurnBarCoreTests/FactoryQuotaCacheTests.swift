import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OpenBurnBarKernel
@testable import OpenBurnBarLogParsers
@testable import OpenBurnBarQuota

final class FactoryQuotaCacheTests: XCTestCase {
    func test_fetch_skipsUnchangedSettingsJSONOnSecondPass() async throws {
        let root = try makeTemporaryDirectory("factory-quota-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try writeSession(
            name: "recent",
            in: sessions,
            prompt: "conversation body must not be cached",
            inputTokens: 900_000,
            outputTokens: 100_000,
            hoursAgo: 1
        )
        try writeSession(
            name: "week",
            in: sessions,
            prompt: "second session body",
            inputTokens: 1_500_000,
            outputTokens: 500_000,
            hoursAgo: 72
        )

        let adapter = FactoryQuotaAdapter(
            sessionsDirectoryOverride: sessions,
            cacheURLOverride: root.appendingPathComponent("factory-cache.plist")
        )
        let context = makeContext(root: root)

        let first = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 2)
        XCTAssertEqual(try XCTUnwrap(fiveHourBucket(in: first)?.usedValue), 1_000_000, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(sevenDayBucket(in: first)?.usedValue), 3_000_000, accuracy: 0.5)

        let second = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(fiveHourBucket(in: second)?.usedValue),
            try XCTUnwrap(fiveHourBucket(in: first)?.usedValue),
            accuracy: 0.5
        )
        XCTAssertEqual(
            try XCTUnwrap(sevenDayBucket(in: second)?.usedValue),
            try XCTUnwrap(sevenDayBucket(in: first)?.usedValue),
            accuracy: 0.5
        )
        XCTAssertEqual(second.statusMessage, first.statusMessage)

        let cacheData = try Data(contentsOf: root.appendingPathComponent("factory-cache.plist"))
        let cacheText = String(decoding: cacheData, as: UTF8.self)
        XCTAssertFalse(cacheText.contains("conversation body must not be cached"))
        XCTAssertFalse(cacheText.contains("second session body"))
    }

    func test_fetch_rereadsOnlyChangedSettingsJSON() async throws {
        let root = try makeTemporaryDirectory("factory-quota-append")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try writeSession(
            name: "stable",
            in: sessions,
            prompt: "stable prompt",
            inputTokens: 100,
            outputTokens: 50,
            hoursAgo: 1
        )
        try writeSession(
            name: "changing",
            in: sessions,
            prompt: "will change",
            inputTokens: 10,
            outputTokens: 10,
            hoursAgo: 1
        )

        let adapter = FactoryQuotaAdapter(
            sessionsDirectoryOverride: sessions,
            cacheURLOverride: root.appendingPathComponent("factory-cache.plist")
        )
        let context = makeContext(root: root)
        _ = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 2)

        try writeSession(
            name: "changing",
            in: sessions,
            prompt: "changed prompt",
            inputTokens: 1_000,
            outputTokens: 500,
            hoursAgo: 1
        )

        let third = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 1)
        XCTAssertEqual(try XCTUnwrap(fiveHourBucket(in: third)?.usedValue), 1_660, accuracy: 0.5)
    }

    private func fiveHourBucket(in snapshot: ProviderQuotaSnapshot) -> ProviderQuotaBucket? {
        snapshot.buckets.first { $0.key == "factory-5h" }
    }

    private func sevenDayBucket(in snapshot: ProviderQuotaSnapshot) -> ProviderQuotaBucket? {
        snapshot.buckets.first { $0.key == "factory-7d" }
    }

    private func writeSession(
        name: String,
        in sessions: URL,
        prompt: String,
        inputTokens: Int,
        outputTokens: Int,
        hoursAgo: Double
    ) throws {
        let project = sessions.appendingPathComponent("test-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let timestamp = ThreadSafeISO8601DateFormatter.formatBasic(
            Date().addingTimeInterval(-hoursAgo * 3_600)
        )
        let json = """
        {
          "model": "claude-3-5-sonnet",
          "providerLock": "factory",
          "providerLockTimestamp": "\(timestamp)",
          "prompt": "\(prompt)",
          "tokenUsage": {
            "inputTokens": \(inputTokens),
            "outputTokens": \(outputTokens),
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
            "thinkingTokens": 0
          }
        }
        """
        try json.write(
            to: project.appendingPathComponent("\(name).settings.json"),
            atomically: true,
            encoding: .utf8
        )
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
