import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class AntigravityQuotaAdapterTests: XCTestCase {
    /// Fixed reference clock so history window math does not depend on wall time.
    private static let referenceEpochMs: Double = 1_750_000_000_000

    private var tempDirectoryURL: URL!
    private var fileManager: FileManager!

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
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: tempDirectoryURL)
        let store = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        let dbQueue = try DatabaseQueue()
        let dataStoreActor = try DataStoreActor(databaseQueue: dbQueue)
        let session = URLSession(configuration: .ephemeral)

        return ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: [
                AntigravityQuotaAdapter.referenceDateEnvironmentKey: String(format: "%.0f", Self.referenceEpochMs)
            ],
            homeDirectoryURL: tempDirectoryURL,
            dataStoreActor: dataStoreActor,
            snapshotStore: store,
            bridgeManager: ClaudeQuotaBridgeManager(appPaths: appPaths, homeDirectoryURL: tempDirectoryURL, fileManager: fileManager, snapshotStore: store),
            miniMaxModeProvider: { .tokenPlan },
            factoryPlanProvider: { .unknown },
            xaiPlanProvider: { .unknown },
            mimoTokenPlanRegionProvider: { .sgp },
            mimoTokenPlanTierProvider: { nil },
            mimoTokenPlanBillingCycleProvider: { .monthly },
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

    /// Integer millisecond timestamps avoid JSON float/scientific-notation decode flakes in CI.
    private func historyLine(display: String, hoursAgo: Double, anchorMs: Double = referenceEpochMs) -> String {
        let timestampMs = Int64(anchorMs - (hoursAgo * 60.0 * 60.0 * 1000.0))
        return "{\"display\":\"\(display)\",\"timestamp\":\(timestampMs),\"workspace\":\"/mock/ws\"}"
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
        XCTAssertTrue(snapshot.statusMessage.contains("not found"))
    }

    func testFetch_whenHistoryExists_producesPerModelBuckets() async throws {
        let adapter = AntigravityQuotaAdapter()

        let nowMs = Self.referenceEpochMs
        let hourInMs = 60.0 * 60.0 * 1000.0

        // 2 events inside 5h window, 1 outside, 1 invalid
        let mockLines = [
            "{\"display\":\"Request 1\",\"timestamp\":\(nowMs - (2.0 * hourInMs)),\"workspace\":\"/mock/ws\"}",
            "{\"display\":\"Request 2\",\"timestamp\":\(nowMs - (3.0 * hourInMs)),\"workspace\":\"/mock/ws\"}",
            "{\"display\":\"Request 3\",\"timestamp\":\(nowMs - (6.0 * hourInMs)),\"workspace\":\"/mock/ws\"}",
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
        XCTAssertEqual(snapshot.confidence, .estimated)

        // One bucket per model tier (7 total)
        XCTAssertEqual(snapshot.buckets.count, 7)

        // --- Active model bucket (Claude Opus 4.6) ---
        let activeBucket = snapshot.buckets.first(where: { $0.label.contains("(Active)") })
        XCTAssertNotNil(activeBucket, "Expected an active model bucket")
        if let active = activeBucket {
            XCTAssertTrue(active.label.contains("Claude Opus 4.6 (Thinking)"))
            XCTAssertEqual(active.usedValue, 2.0)
            XCTAssertEqual(active.limitValue, 60.0)
            XCTAssertEqual(active.remainingValue, 58.0)
            XCTAssertEqual(active.windowKind, .rollingHours)
            XCTAssertEqual(active.unit, .requests)
            XCTAssertNotNil(active.resetsAt)

            // resetsAt = earliest event in 5h window (3h ago) + 5h = 2h from now
            if let resetsAt = active.resetsAt {
                let expectedReset = Date(timeIntervalSince1970: (nowMs - (3.0 * hourInMs)) / 1000.0).addingTimeInterval(5 * 60 * 60)
                XCTAssertEqual(resetsAt.timeIntervalSince1970, expectedReset.timeIntervalSince1970, accuracy: 1.0)
            }
        }

        // --- Inactive model bucket (Gemini 3.5 Flash (High)) ---
        let flashBucket = snapshot.buckets.first(where: { $0.label == "Gemini 3.5 Flash (High)" })
        XCTAssertNotNil(flashBucket, "Expected a bucket for Gemini 3.5 Flash (High)")
        if let flash = flashBucket {
            XCTAssertEqual(flash.usedValue, 0)
            XCTAssertEqual(flash.limitValue, 600.0)
            XCTAssertEqual(flash.remainingValue, 600.0)
            XCTAssertNil(flash.resetsAt)
        }

        // --- Inactive model bucket (GPT-OSS 120B (Medium)) ---
        let gptBucket = snapshot.buckets.first(where: { $0.label == "GPT-OSS 120B (Medium)" })
        XCTAssertNotNil(gptBucket, "Expected a bucket for GPT-OSS 120B (Medium)")
        if let gpt = gptBucket {
            XCTAssertEqual(gpt.usedValue, 0)
            XCTAssertEqual(gpt.limitValue, 240.0)
            XCTAssertEqual(gpt.remainingValue, 240.0)
            XCTAssertNil(gpt.resetsAt)
        }

        // --- Status message mentions active model ---
        XCTAssertTrue(snapshot.statusMessage.contains("Claude Opus 4.6 (Thinking)"))
    }

    func testFetch_whenSettingsMissing_defaultsToClaudeOpus() async throws {
        let adapter = AntigravityQuotaAdapter()

        let nowMs = Self.referenceEpochMs
        let hourInMs = 60.0 * 60.0 * 1000.0

        // One event inside 5h window
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
            XCTAssertEqual(active.limitValue, 60.0)
            XCTAssertEqual(active.remainingValue, 59.0)
        }

        // Verify a non-default model is inactive
        let sonnetBucket = snapshot.buckets.first(where: { $0.label == "Claude Sonnet 4.6 (Thinking)" })
        XCTAssertNotNil(sonnetBucket)
        if let sonnet = sonnetBucket {
            XCTAssertEqual(sonnet.usedValue, 0)
            XCTAssertEqual(sonnet.limitValue, 120.0)
            XCTAssertEqual(sonnet.remainingValue, 120.0)
            XCTAssertNil(sonnet.resetsAt)
        }

        XCTAssertTrue(snapshot.statusMessage.contains("Claude Opus 4.6 (Thinking)"))
    }

    func testFetch_whenDifferentModelSelected_thatModelIsActive() async throws {
        let adapter = AntigravityQuotaAdapter()

        let nowMs = Self.referenceEpochMs
        let hourInMs = 60.0 * 60.0 * 1000.0

        let mockLines = [
            historyLine(display: "R1", hoursAgo: 1.0, anchorMs: nowMs),
            historyLine(display: "R2", hoursAgo: 2.0, anchorMs: nowMs),
            historyLine(display: "R3", hoursAgo: 3.0, anchorMs: nowMs)
        ]

        try writeHistory(lines: mockLines)
        try writeSettings(model: "Gemini 3.5 Flash (Medium)")

        let context = try makeContext()
        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.sourceKind, .localCLI, snapshot.statusMessage)
        XCTAssertEqual(snapshot.buckets.count, 7)

        let activeBucket = snapshot.buckets.first(where: { $0.label.contains("(Active)") })
        XCTAssertNotNil(activeBucket, "Expected active bucket; buckets=\(snapshot.buckets.map(\.label))")
        if let active = activeBucket {
            XCTAssertTrue(active.label.contains("Gemini 3.5 Flash (Medium)"), active.label)
            XCTAssertEqual(active.usedValue, 3.0, "used=\(active.usedValue)")
            XCTAssertEqual(active.limitValue, 900.0, "limit=\(active.limitValue)")
            XCTAssertEqual(active.remainingValue, 897.0, "remaining=\(active.remainingValue)")
        }

        // Claude Opus should now be inactive with 0 used
        let opusBucket = snapshot.buckets.first(where: { $0.label == "Claude Opus 4.6 (Thinking)" })
        XCTAssertNotNil(opusBucket)
        if let opus = opusBucket {
            XCTAssertEqual(opus.usedValue, 0)
            XCTAssertEqual(opus.limitValue, 60.0)
            XCTAssertEqual(opus.remainingValue, 60.0)
            XCTAssertNil(opus.resetsAt)
        }

        XCTAssertTrue(snapshot.statusMessage.contains("Gemini 3.5 Flash (Medium)"))
    }
}
