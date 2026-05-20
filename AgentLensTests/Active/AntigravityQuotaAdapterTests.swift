import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class AntigravityQuotaAdapterTests: XCTestCase {
    var tempDirectoryURL: URL!
    var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectoryURL)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeContext() throws -> ProviderQuotaAdapterContext {
        let appPaths = OpenBurnBarAppPaths.live()
        let store = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        let dbQueue = try DatabaseQueue()
        let dataStoreActor = try DataStoreActor(databaseQueue: dbQueue)

        return ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: URLSession.shared,
            environment: [:],
            homeDirectoryURL: tempDirectoryURL,
            dataStoreActor: dataStoreActor,
            snapshotStore: store,
            bridgeManager: ClaudeQuotaBridgeManager(appPaths: appPaths, homeDirectoryURL: tempDirectoryURL, fileManager: fileManager, snapshotStore: store),
            miniMaxModeProvider: { .tokenPlan },
            factoryPlanProvider: { .unknown },
            claudeBridgeStatus: ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "Not installed", lastPayloadAt: nil),
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            refreshClaudeBridgeStatus: { ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "Not installed", lastPayloadAt: nil) },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: [:]
        )
    }

    private func writeHistory(lines: [String]) throws {
        let geminiCLIDir = tempDirectoryURL.appendingPathComponent(".gemini/antigravity-cli")
        try fileManager.createDirectory(at: geminiCLIDir, withIntermediateDirectories: true, attributes: nil)
        let historyURL = geminiCLIDir.appendingPathComponent("history.jsonl")
        let content = lines.joined(separator: "\n")
        try content.write(to: historyURL, atomically: true, encoding: .utf8)
    }

    private func writeSettings(model: String) throws {
        let geminiCLIDir = tempDirectoryURL.appendingPathComponent(".gemini/antigravity-cli")
        try fileManager.createDirectory(at: geminiCLIDir, withIntermediateDirectories: true, attributes: nil)
        let settingsURL = geminiCLIDir.appendingPathComponent("settings.json")
        let json = "{\"model\": \"\(model)\"}"
        try json.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Tests

    func testFetch_whenHistoryDoesNotExist_returnsUnavailableSnapshot() async throws {
        let adapter = AntigravityQuotaAdapter()
        let context = try makeContext()

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .antigravity)
        XCTAssertEqual(snapshot.providerID, .antigravity)
        XCTAssertEqual(snapshot.sourceKind, .unavailable)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertTrue(snapshot.statusMessage.contains("not found") == true)
    }

    func testFetch_whenHistoryExists_producesPerModelBuckets() async throws {
        let adapter = AntigravityQuotaAdapter()

        let nowMs = Date().timeIntervalSince1970 * 1000.0
        let hourInMs = 60.0 * 60.0 * 1000.0

        // 2 events inside 24h, 1 outside, 1 invalid
        let mockLines = [
            "{\"display\":\"Request 1\",\"timestamp\":\(nowMs - (2.0 * hourInMs)),\"workspace\":\"/mock/ws\"}",
            "{\"display\":\"Request 2\",\"timestamp\":\(nowMs - (5.0 * hourInMs)),\"workspace\":\"/mock/ws\"}",
            "{\"display\":\"Request 3\",\"timestamp\":\(nowMs - (25.0 * hourInMs)),\"workspace\":\"/mock/ws\"}",
            "invalid json line string",
            ""
        ]

        try writeHistory(lines: mockLines)
        try writeSettings(model: "Claude Opus 4.6 (Thinking)")

        let context = try makeContext()
        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .antigravity)
        XCTAssertEqual(snapshot.providerID, .antigravity)
        XCTAssertEqual(snapshot.sourceKind, .localCLI)
        XCTAssertEqual(snapshot.confidence, .exact)

        // One bucket per model tier (7 total)
        XCTAssertEqual(snapshot.buckets.count, 7)

        // --- Active model bucket (Claude Opus 4.6) ---
        let activeBucket = snapshot.buckets.first(where: { $0.label.contains("(Active)") })
        XCTAssertNotNil(activeBucket, "Expected an active model bucket")
        if let active = activeBucket {
            XCTAssertTrue(active.label.contains("Claude Opus 4.6 (Thinking)"))
            XCTAssertEqual(active.usedValue, 2.0)
            XCTAssertEqual(active.limitValue, 100.0)
            XCTAssertEqual(active.remainingValue, 98.0)
            XCTAssertEqual(active.windowKind, .rollingHours)
            XCTAssertEqual(active.unit, .requests)
            XCTAssertNotNil(active.resetsAt)

            // resetsAt = earliest event in 24h (5h ago) + 24h ≈ 19h from now
            if let resetsAt = active.resetsAt {
                let expectedReset = Date(timeIntervalSince1970: (nowMs - (5.0 * hourInMs)) / 1000.0).addingTimeInterval(24 * 60 * 60)
                XCTAssertEqual(resetsAt.timeIntervalSince1970, expectedReset.timeIntervalSince1970, accuracy: 1.0)
            }
        }

        // --- Inactive model bucket (Gemini 3.5 Flash (High)) ---
        let flashBucket = snapshot.buckets.first(where: { $0.label == "Gemini 3.5 Flash (High)" })
        XCTAssertNotNil(flashBucket, "Expected a bucket for Gemini 3.5 Flash (High)")
        if let flash = flashBucket {
            XCTAssertEqual(flash.usedValue, 0)
            XCTAssertEqual(flash.limitValue, 1000.0)
            XCTAssertEqual(flash.remainingValue, 1000.0)
            XCTAssertNil(flash.resetsAt)
        }

        // --- Inactive model bucket (GPT-OSS 120B (Medium)) ---
        let gptBucket = snapshot.buckets.first(where: { $0.label == "GPT-OSS 120B (Medium)" })
        XCTAssertNotNil(gptBucket, "Expected a bucket for GPT-OSS 120B (Medium)")
        if let gpt = gptBucket {
            XCTAssertEqual(gpt.usedValue, 0)
            XCTAssertEqual(gpt.limitValue, 400.0)
            XCTAssertEqual(gpt.remainingValue, 400.0)
            XCTAssertNil(gpt.resetsAt)
        }

        // --- Status message mentions active model ---
        XCTAssertTrue(snapshot.statusMessage.contains("Claude Opus 4.6 (Thinking)"))
    }

    func testFetch_whenSettingsMissing_defaultsToClaudeOpus() async throws {
        let adapter = AntigravityQuotaAdapter()

        let nowMs = Date().timeIntervalSince1970 * 1000.0
        let hourInMs = 60.0 * 60.0 * 1000.0

        // One event inside 24h window
        let mockLines = [
            "{\"display\":\"Solo request\",\"timestamp\":\(nowMs - (1.0 * hourInMs)),\"workspace\":\"/mock/ws\"}"
        ]

        try writeHistory(lines: mockLines)
        // Deliberately do NOT write settings.json

        let context = try makeContext()
        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.sourceKind, .localCLI)
        XCTAssertEqual(snapshot.buckets.count, 7)

        // Active bucket should default to Claude Opus 4.6 (Thinking)
        let activeBucket = snapshot.buckets.first(where: { $0.label.contains("(Active)") })
        XCTAssertNotNil(activeBucket)
        if let active = activeBucket {
            XCTAssertTrue(active.label.contains("Claude Opus 4.6 (Thinking)"))
            XCTAssertEqual(active.usedValue, 1.0)
            XCTAssertEqual(active.limitValue, 100.0)
            XCTAssertEqual(active.remainingValue, 99.0)
        }

        // Verify a non-default model is inactive
        let sonnetBucket = snapshot.buckets.first(where: { $0.label == "Claude Sonnet 4.6 (Thinking)" })
        XCTAssertNotNil(sonnetBucket)
        if let sonnet = sonnetBucket {
            XCTAssertEqual(sonnet.usedValue, 0)
            XCTAssertEqual(sonnet.limitValue, 200.0)
            XCTAssertEqual(sonnet.remainingValue, 200.0)
            XCTAssertNil(sonnet.resetsAt)
        }

        XCTAssertTrue(snapshot.statusMessage.contains("Claude Opus 4.6 (Thinking)"))
    }

    func testFetch_whenDifferentModelSelected_thatModelIsActive() async throws {
        let adapter = AntigravityQuotaAdapter()

        let nowMs = Date().timeIntervalSince1970 * 1000.0
        let hourInMs = 60.0 * 60.0 * 1000.0

        let mockLines = [
            "{\"display\":\"R1\",\"timestamp\":\(nowMs - (3.0 * hourInMs)),\"workspace\":\"/mock/ws\"}",
            "{\"display\":\"R2\",\"timestamp\":\(nowMs - (4.0 * hourInMs)),\"workspace\":\"/mock/ws\"}",
            "{\"display\":\"R3\",\"timestamp\":\(nowMs - (6.0 * hourInMs)),\"workspace\":\"/mock/ws\"}"
        ]

        try writeHistory(lines: mockLines)
        try writeSettings(model: "Gemini 3.5 Flash (Medium)")

        let context = try makeContext()
        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.buckets.count, 7)

        let activeBucket = snapshot.buckets.first(where: { $0.label.contains("(Active)") })
        XCTAssertNotNil(activeBucket)
        if let active = activeBucket {
            XCTAssertTrue(active.label.contains("Gemini 3.5 Flash (Medium)"))
            XCTAssertEqual(active.usedValue, 3.0)
            XCTAssertEqual(active.limitValue, 1500.0)
            XCTAssertEqual(active.remainingValue, 1497.0)
        }

        // Claude Opus should now be inactive with 0 used
        let opusBucket = snapshot.buckets.first(where: { $0.label == "Claude Opus 4.6 (Thinking)" })
        XCTAssertNotNil(opusBucket)
        if let opus = opusBucket {
            XCTAssertEqual(opus.usedValue, 0)
            XCTAssertEqual(opus.limitValue, 100.0)
            XCTAssertEqual(opus.remainingValue, 100.0)
            XCTAssertNil(opus.resetsAt)
        }

        XCTAssertTrue(snapshot.statusMessage.contains("Gemini 3.5 Flash (Medium)"))
    }
}
