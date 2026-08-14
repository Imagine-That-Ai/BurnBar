import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OpenBurnBarKernel
@testable import OpenBurnBarLogParsers
@testable import OpenBurnBarQuota

final class AiderQuotaCacheTests: XCTestCase {
    func test_fetch_skipsUnchangedAnalyticsJSONLOnSecondPass() async throws {
        let root = try makeTemporaryDirectory("aider-quota-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let analytics = root.appendingPathComponent(".aider", isDirectory: true)
        let now = Date()
        try writeAnalytics(
            in: analytics,
            events: [
                launched(at: now.addingTimeInterval(-120)),
                messageSend(
                    at: now.addingTimeInterval(-60),
                    promptTokens: 10,
                    completionTokens: 4,
                    cost: 0.0123,
                    prompt: "conversation body must not be cached"
                ),
                exit(at: now.addingTimeInterval(-30))
            ]
        )

        let adapter = AiderQuotaAdapter(
            analyticsDirectoryOverride: analytics,
            cacheURLOverride: root.appendingPathComponent("aider-cache.plist")
        )
        let context = makeContext(root: root)

        let first = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 1)
        XCTAssertEqual(try XCTUnwrap(dailyBucket(in: first)?.usedValue), 14.0, accuracy: 0.0001)
        XCTAssertTrue(try XCTUnwrap(first.statusMessage).contains("1 session"))

        let second = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(dailyBucket(in: second)?.usedValue),
            try XCTUnwrap(dailyBucket(in: first)?.usedValue),
            accuracy: 0.0001
        )
        XCTAssertEqual(second.statusMessage, first.statusMessage)

        let cacheData = try Data(contentsOf: root.appendingPathComponent("aider-cache.plist"))
        let cacheText = String(decoding: cacheData, as: UTF8.self)
        XCTAssertFalse(cacheText.contains("conversation body must not be cached"))
        XCTAssertFalse(cacheText.contains("prompt_tokens"))
    }

    func test_aiderStaysOffQuotaSignalProvidersByDesign() {
        XCTAssertFalse(AgentProvider.quotaSignalProviders.contains(.aider))
        XCTAssertFalse(AgentProvider.aider.isQuotaSignalProvider)
        XCTAssertNil(ProviderQuotaAdapterRegistry.standard.entry(for: .aider))
        XCTAssertFalse(AgentProviderIngestionCatalog.entry(for: .aider).quotaSignal)
    }

    func test_fetch_resumesAppendOnlyGrowthWithoutRereadingHead() async throws {
        let root = try makeTemporaryDirectory("aider-quota-append")
        defer { try? FileManager.default.removeItem(at: root) }
        let analytics = root.appendingPathComponent(".aider", isDirectory: true)
        let now = Date()
        try writeAnalytics(
            in: analytics,
            events: [
                launched(at: now.addingTimeInterval(-180)),
                messageSend(
                    at: now.addingTimeInterval(-120),
                    promptTokens: 8,
                    completionTokens: 2,
                    cost: 0.01,
                    prompt: "stable"
                ),
                exit(at: now.addingTimeInterval(-90))
            ]
        )

        let adapter = AiderQuotaAdapter(
            analyticsDirectoryOverride: analytics,
            cacheURLOverride: root.appendingPathComponent("aider-cache.plist")
        )
        let context = makeContext(root: root)
        _ = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 1)

        try appendAnalytics(
            in: analytics,
            events: [
                launched(at: now.addingTimeInterval(-60)),
                messageSend(
                    at: now.addingTimeInterval(-30),
                    promptTokens: 9,
                    completionTokens: 3,
                    cost: 0.02,
                    prompt: "changed body"
                ),
                exit(at: now)
            ]
        )

        let third = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 1)
        XCTAssertEqual(try XCTUnwrap(dailyBucket(in: third)?.usedValue), 22.0, accuracy: 0.0001)
        XCTAssertTrue(try XCTUnwrap(third.statusMessage).contains("2 session"))
    }

    func test_fetch_rereadsWhenHeadRewritten() async throws {
        let root = try makeTemporaryDirectory("aider-quota-rewrite")
        defer { try? FileManager.default.removeItem(at: root) }
        let analytics = root.appendingPathComponent(".aider", isDirectory: true)
        let now = Date()
        try writeAnalytics(
            in: analytics,
            events: [
                messageSend(
                    at: now.addingTimeInterval(-60),
                    promptTokens: 5,
                    completionTokens: 5,
                    cost: 0.01,
                    prompt: "first"
                ),
                exit(at: now.addingTimeInterval(-50))
            ]
        )

        let adapter = AiderQuotaAdapter(
            analyticsDirectoryOverride: analytics,
            cacheURLOverride: root.appendingPathComponent("aider-cache.plist")
        )
        let context = makeContext(root: root)
        _ = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 1)

        try writeAnalytics(
            in: analytics,
            events: [
                messageSend(
                    at: now.addingTimeInterval(-20),
                    promptTokens: 1,
                    completionTokens: 1,
                    cost: 0.002,
                    prompt: "rewritten"
                ),
                exit(at: now)
            ]
        )

        let rewritten = try await adapter.fetch(context: context)
        XCTAssertEqual(adapter.lastContentReadCount, 1)
        XCTAssertEqual(try XCTUnwrap(dailyBucket(in: rewritten)?.usedValue), 2.0, accuracy: 0.0001)
    }

    private func dailyBucket(in snapshot: ProviderQuotaSnapshot) -> ProviderQuotaBucket? {
        snapshot.buckets.first { $0.key == "aider-daily-tokens" }
    }

    private func launched(at date: Date) -> String {
        eventJSON(event: "launched", time: date, properties: [:])
    }

    private func exit(at date: Date) -> String {
        eventJSON(event: "exit", time: date, properties: [:])
    }

    private func messageSend(
        at date: Date,
        promptTokens: Int,
        completionTokens: Int,
        cost: Double,
        prompt: String
    ) -> String {
        eventJSON(
            event: "message_send",
            time: date,
            properties: [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens,
                "cost": cost,
                "prompt": prompt
            ]
        )
    }

    private func eventJSON(event: String, time: Date, properties: [String: Any]) -> String {
        var props: [String] = []
        for (key, value) in properties {
            switch value {
            case let number as Int:
                props.append("\"\(key)\":\(number)")
            case let number as Double:
                props.append("\"\(key)\":\(number)")
            case let text as String:
                let escaped = text
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                props.append("\"\(key)\":\"\(escaped)\"")
            default:
                continue
            }
        }
        return "{\"event\":\"\(event)\",\"time\":\(time.timeIntervalSince1970),\"properties\":{\(props.joined(separator: ","))}}"
    }

    private func writeAnalytics(in directory: URL, events: [String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = events.joined(separator: "\n") + "\n"
        try body.write(
            to: directory.appendingPathComponent("analytics.jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func appendAnalytics(in directory: URL, events: [String]) throws {
        let url = directory.appendingPathComponent("analytics.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let body = events.joined(separator: "\n") + "\n"
        try handle.write(contentsOf: Data(body.utf8))
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
