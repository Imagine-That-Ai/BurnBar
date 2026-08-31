import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore
// Core-decomposition: AntigravityQuotaAdapter (and its INTERNAL referenceDate(from:) +
// referenceDate{,OptIn}EnvironmentKey) moved from the Core monolith into OpenBurnBarQuota. The
// umbrella shim only re-exports Quota's public API, so reaching the internal statics needs a direct
// `@testable import OpenBurnBarQuota` — same AE-TESTABLE pattern as WarpQuotaAdapterMattersTests. The
// OpenBurnBar app target already links OpenBurnBarQuota (added for that fix), so no project.yml change.
@testable import OpenBurnBarQuota

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

    private func makeContext(
        referenceEpochMs: Double? = nil,
        enableReferenceDateOverride: Bool = true
    ) throws -> ProviderQuotaAdapterContext {
        let resolvedReferenceEpochMs = referenceEpochMs ?? Self.referenceEpochMs
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: tempDirectoryURL)
        let store = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        let session = URLSession(configuration: .ephemeral)
        var environment = [
            AntigravityQuotaAdapter.referenceDateEnvironmentKey: String(format: "%.0f", resolvedReferenceEpochMs)
        ]
        if enableReferenceDateOverride {
            environment[AntigravityQuotaAdapter.referenceDateOptInEnvironmentKey] = "1"
        }

        return ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: tempDirectoryURL,
            snapshotStore: store,
            bridgeManager: ClaudeQuotaBridgeManager(appPaths: appPaths, homeDirectoryURL: tempDirectoryURL, fileManager: fileManager, snapshotStore: store),
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
    private func historyLine(display: String, hoursAgo: Double, anchorMs: Double? = nil) -> String {
        let resolvedAnchorMs = anchorMs ?? Self.referenceEpochMs
        let timestampMs = Int64(resolvedAnchorMs - (hoursAgo * 60.0 * 60.0 * 1000.0))
        return "{\"display\":\"\(display)\",\"timestamp\":\(timestampMs),\"workspace\":\"/mock/ws\"}"
    }

    // MARK: - Tests

    func testReferenceDateOverride_requiresExplicitDebugOptIn() throws {
        let context = try makeContext(enableReferenceDateOverride: false)

        let before = Date()
        let resolved = AntigravityQuotaAdapter.referenceDate(from: context)
        let after = Date()

        XCTAssertGreaterThanOrEqual(resolved.timeIntervalSince1970, before.timeIntervalSince1970 - 1)
        XCTAssertLessThanOrEqual(resolved.timeIntervalSince1970, after.timeIntervalSince1970 + 1)
        XCTAssertNotEqual(
            Int(resolved.timeIntervalSince1970),
            Int(Self.referenceEpochMs / 1000.0),
            "The test clock env value must be inert unless the debug opt-in flag is present."
        )
    }

    func testReferenceDateOverride_rejectsNonFiniteAndOutOfBoundsValues() throws {
        let invalidContexts = try [
            makeContext(referenceEpochMs: .nan),
            makeContext(referenceEpochMs: -1),
            makeContext(referenceEpochMs: 4_102_444_800_001)
        ]

        for context in invalidContexts {
            let before = Date()
            let resolved = AntigravityQuotaAdapter.referenceDate(from: context)
            let after = Date()

            XCTAssertGreaterThanOrEqual(resolved.timeIntervalSince1970, before.timeIntervalSince1970 - 1)
            XCTAssertLessThanOrEqual(resolved.timeIntervalSince1970, after.timeIntervalSince1970 + 1)
        }
    }

    func testReferenceDateOverride_appliesWithDebugOptIn() throws {
        let context = try makeContext()

        let resolved = AntigravityQuotaAdapter.referenceDate(from: context)

        XCTAssertEqual(resolved.timeIntervalSince1970, Self.referenceEpochMs / 1000.0, accuracy: 0.001)
    }

    func testFetch_whenHistoryDoesNotExist_returnsUnavailableSnapshot() async throws {
        let adapter = AntigravityQuotaAdapter()
        let context = try makeContext()

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, AgentProvider.antigravity.rawValue)
        XCTAssertEqual(snapshot.providerID, .antigravity)
        XCTAssertEqual(snapshot.sourceKind, .unavailable)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertEqual(snapshot.statusMessage?.contains("not found"), true)
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

        XCTAssertEqual(snapshot.provider, AgentProvider.antigravity.rawValue)
        XCTAssertEqual(snapshot.providerID, .antigravity)
        XCTAssertEqual(snapshot.sourceKind, .localCLI)
        XCTAssertEqual(snapshot.confidence, .estimated)

        // One bucket per model tier
        XCTAssertEqual(snapshot.buckets.count, AntigravityQuotaAdapter.availableModels.count)

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
        XCTAssertEqual(snapshot.statusMessage?.contains("Claude Opus 4.6 (Thinking)"), true)
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
        XCTAssertEqual(snapshot.buckets.count, AntigravityQuotaAdapter.availableModels.count)

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

        XCTAssertEqual(snapshot.statusMessage?.contains("Claude Opus 4.6 (Thinking)"), true)
    }

    func testFetch_whenDifferentModelSelected_thatModelIsActive() async throws {
        let adapter = AntigravityQuotaAdapter()

        let nowMs = Self.referenceEpochMs

        let mockLines = [
            historyLine(display: "R1", hoursAgo: 1.0, anchorMs: nowMs),
            historyLine(display: "R2", hoursAgo: 2.0, anchorMs: nowMs),
            historyLine(display: "R3", hoursAgo: 3.0, anchorMs: nowMs)
        ]

        try writeHistory(lines: mockLines)
        try writeSettings(model: "Gemini 3.5 Flash (Medium)")

        let context = try makeContext()
        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.sourceKind, .localCLI, snapshot.statusMessage ?? "")
        XCTAssertEqual(snapshot.buckets.count, AntigravityQuotaAdapter.availableModels.count)

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

        XCTAssertEqual(snapshot.statusMessage?.contains("Gemini 3.5 Flash (Medium)"), true)
    }

    func testFetch_fromBrainTranscripts_whenHistoryMissing_computesQuotaAndModel() async throws {
        let adapter = AntigravityQuotaAdapter()
        let now = Date(timeIntervalSince1970: Self.referenceEpochMs / 1000.0)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Write brain transcripts to ~/.gemini/antigravity/brain/<session>/...
        let sessionDir = tempDirectoryURL.appendingPathComponent(".gemini/antigravity/brain/mock-session-1/.system_generated/logs")
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let transcriptURL = sessionDir.appendingPathComponent("transcript.jsonl")

        let t1 = formatter.string(from: now.addingTimeInterval(-2 * 3600))
        let t2 = formatter.string(from: now.addingTimeInterval(-1 * 3600))

        let lines = [
            "{\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"content\":\"<USER_SETTINGS_CHANGE>The user changed setting `Model Selection` from None to Gemini 3.7 Flash (High).</USER_SETTINGS_CHANGE>\"}",
            "{\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"created_at\":\"\(t1)\"}",
            "{\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"created_at\":\"\(t2)\"}"
        ]
        try lines.joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let context = try makeContext()
        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.sourceKind, .localCLI)
        XCTAssertEqual(snapshot.buckets.count, AntigravityQuotaAdapter.availableModels.count)

        let activeBucket = snapshot.buckets.first(where: { $0.label.contains("(Active)") })
        XCTAssertNotNil(activeBucket)
        if let active = activeBucket {
            XCTAssertTrue(active.label.contains("Gemini 3.7 Flash (High)"))
            XCTAssertEqual(active.usedValue, 2.0)
            XCTAssertEqual(active.limitValue, 600.0)
            XCTAssertEqual(active.remainingValue, 598.0)
            XCTAssertNotNil(active.resetsAt)
        }
    }
}
