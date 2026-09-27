import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OpenBurnBarKernel
@testable import OpenBurnBarQuota

final class GeminiCLIQuotaAdapterTests: XCTestCase {
    func testMissingGeminiHomeIsUnavailableWithoutInventedRemaining() async throws {
        let root = try makeTemporaryDirectory("gemini-missing")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = try await GeminiCLIQuotaAdapter().fetch(context: makeContext(root: root))
        XCTAssertEqual(snapshot.provider, AgentProvider.geminiCLI.rawValue)
        XCTAssertEqual(snapshot.sourceKind, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        let message = try XCTUnwrap(snapshot.statusMessage)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("not"), "Expected an honest empty-state, got: \(message)")
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("remaining")
                || message.localizedCaseInsensitiveContains("quota"),
            "Empty-state must say remaining quota is unavailable, got: \(message)"
        )
        XCTAssertFalse(message.localizedCaseInsensitiveContains("firebase"))
    }

    func testRecentSessionTokensFillUsedOnlyWindows() async throws {
        let root = try makeTemporaryDirectory("gemini-used")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        try writeSession(
            at: root,
            sessionID: "session-recent",
            timestamp: now.addingTimeInterval(-30 * 60),
            inputTokens: 120,
            outputTokens: 45
        )

        let snapshot = try await GeminiCLIQuotaAdapter().fetch(context: makeContext(root: root))
        XCTAssertEqual(snapshot.sourceKind, .localSession)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertFalse(snapshot.buckets.isEmpty)

        let tokens24h = try XCTUnwrap(snapshot.buckets.first { $0.key == "tokens-24h" })
        XCTAssertEqual(tokens24h.usedValue, 165)
        XCTAssertNil(tokens24h.limitValue)
        XCTAssertNil(tokens24h.remainingValue)
        XCTAssertNil(tokens24h.usedPercent)
        XCTAssertEqual(tokens24h.unit, .tokens)
        XCTAssertFalse(tokens24h.isEstimated)
        XCTAssertEqual(tokens24h.meta?["limitKind"], "used-only")
        XCTAssertTrue(tokens24h.isDisplayableQuotaSignal)
        XCTAssertNil(tokens24h.displayRemainingFraction)

        let tokens7d = try XCTUnwrap(snapshot.buckets.first { $0.key == "tokens-7d" })
        XCTAssertEqual(tokens7d.usedValue, 165)
        XCTAssertEqual(tokens7d.meta?["limitKind"], "used-only")

        let message = try XCTUnwrap(snapshot.statusMessage)
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("remaining")
                || message.localizedCaseInsensitiveContains("not available"),
            "Used-token snapshot must still refuse remaining quota, got: \(message)"
        )
        XCTAssertFalse(message.localizedCaseInsensitiveContains("verizon") && message.localizedCaseInsensitiveContains("%"))
    }

    func testThreeDayOldSessionCountsInSevenDayWindowOnly() async throws {
        let root = try makeTemporaryDirectory("gemini-mid-window")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSession(
            at: root,
            sessionID: "session-three-day",
            timestamp: Date().addingTimeInterval(-3 * 24 * 60 * 60),
            inputTokens: 80,
            outputTokens: 20
        )
        try writeSession(
            at: root,
            sessionID: "session-today",
            timestamp: Date().addingTimeInterval(-20 * 60),
            inputTokens: 5,
            outputTokens: 5
        )

        let snapshot = try await GeminiCLIQuotaAdapter().fetch(context: makeContext(root: root))
        let tokens24h = try XCTUnwrap(snapshot.buckets.first { $0.key == "tokens-24h" })
        let tokens7d = try XCTUnwrap(snapshot.buckets.first { $0.key == "tokens-7d" })
        XCTAssertEqual(tokens24h.usedValue, 10)
        XCTAssertEqual(tokens7d.usedValue, 110)
    }

    func testSessionsOlderThanSevenDaysAreExcludedFromWindows() async throws {
        let root = try makeTemporaryDirectory("gemini-stale")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSession(
            at: root,
            sessionID: "session-old",
            timestamp: Date().addingTimeInterval(-10 * 24 * 60 * 60),
            inputTokens: 900,
            outputTokens: 100
        )
        try writeSession(
            at: root,
            sessionID: "session-new",
            timestamp: Date().addingTimeInterval(-2 * 60 * 60),
            inputTokens: 10,
            outputTokens: 5
        )

        let snapshot = try await GeminiCLIQuotaAdapter().fetch(context: makeContext(root: root))
        let tokens24h = try XCTUnwrap(snapshot.buckets.first { $0.key == "tokens-24h" })
        let tokens7d = try XCTUnwrap(snapshot.buckets.first { $0.key == "tokens-7d" })
        XCTAssertEqual(tokens24h.usedValue, 15)
        XCTAssertEqual(tokens7d.usedValue, 15)
    }

    func testConsumerOAuthSettingsRefuseVerizonRemaining() async throws {
        let root = try makeTemporaryDirectory("gemini-consumer")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".gemini", isDirectory: true),
            withIntermediateDirectories: true
        )
        try #"""
        {"selectedAuthType":"oauth-personal","security":{"auth":{"selectedType":"oauth-personal"}}}
        """#.write(
            to: root.appendingPathComponent(".gemini/settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try await GeminiCLIQuotaAdapter().fetch(context: makeContext(root: root))
        let message = try XCTUnwrap(snapshot.statusMessage)
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("gemini app")
                || message.localizedCaseInsensitiveContains("verizon")
                || message.localizedCaseInsensitiveContains("antigravity"),
            "Consumer login must name the unsupported remaining-quota surface, got: \(message)"
        )
        XCTAssertFalse(snapshot.buckets.contains { $0.displayRemainingFraction != nil })
    }

    func testUsedOnlyBucketDoesNotFabricateRemainingPercent() {
        let bucket = ProviderQuotaBucket(
            key: "tokens-24h",
            label: "Tokens used in the last 24 hours",
            windowKind: .rollingHours,
            usedValue: 165,
            limitValue: nil,
            remainingValue: nil,
            usedPercent: nil,
            resetsAt: nil,
            unit: .tokens,
            isEstimated: false,
            limitKind: "used-only"
        )
        XCTAssertTrue(bucket.isUsedOnlyMeter)
        XCTAssertTrue(bucket.isDisplayableQuotaSignal)
        XCTAssertNil(bucket.displayRemainingFraction)
        XCTAssertTrue(bucket.usageText.localizedCaseInsensitiveContains("165"))
        XCTAssertFalse(bucket.usageText.contains("/"))
        XCTAssertEqual(bucket.remainingText, "Unavailable")
    }

    private func writeSession(
        at root: URL,
        sessionID: String,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int
    ) throws {
        let chats = root
            .appendingPathComponent(".gemini/tmp/project-hash-1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let stamp = iso.string(from: timestamp)
        let jsonl = """
        {"role":"user","content":"hello","timestamp":"\(stamp)"}
        {"role":"model","content":"done","timestamp":"\(stamp)","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}
        """
        try jsonl.write(
            to: chats.appendingPathComponent("\(sessionID).jsonl"),
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
        ProviderQuotaAdapterContext(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: root),
            fileManager: .default,
            session: URLSession(configuration: .ephemeral),
            environment: [:],
            homeDirectoryURL: root,
            snapshotStore: GeminiQuotaTestSnapshotStore(),
            bridgeManager: GeminiQuotaTestClaudeBridge(),
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

private struct GeminiQuotaTestSnapshotStore: ProviderQuotaSnapshotPersisting {
    func loadScratchString(forKey key: String) -> String? { nil }
    func saveScratchString(_ value: String, forKey key: String) {}
    func readJSONObject(from url: URL) throws -> [String: Any]? { nil }
}

private struct GeminiQuotaTestClaudeBridge: ClaudeQuotaBridgeManaging {
    func installClaudeQuotaBridge() throws {}
    func refreshClaudeBridgeStatus() -> ClaudeQuotaBridgeStatus {
        ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "", lastPayloadAt: nil)
    }
}
