import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarLogParsers

// MARK: - FxParserTests
//
// Verifies fx session parsing at `~/.fx/sessions/<session-id>/`
// (schema-v3 `session.json` manifest, `usage-v2.json` rich sidecar,
// `events.jsonl` turn transcript, `display.json` title). Fixtures are
// pinned to the real fx v0.0.3 on-disk schema (vercel-labs/fx source:
// session_projection.zig, session_usage.zig, session_event.zig,
// session_display_metadata.zig).

final class FxParserTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-fx-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSession(
        dir: URL,
        sessionId: String = "1770000000000-1770000000000000000-a1b2c3d4e5f60718",
        manifest: [String: Any]? = nil,
        sidecar: [String: Any]? = nil,
        events: [String] = [],
        display: [String: Any]? = nil
    ) throws {
        let sessionDir = dir.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        if let manifest {
            try Self.json(manifest).write(to: sessionDir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        }
        if let sidecar {
            try Self.json(sidecar).write(to: sessionDir.appendingPathComponent("usage-v2.json"), atomically: true, encoding: .utf8)
        }
        if !events.isEmpty {
            try events.joined(separator: "\n").write(to: sessionDir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        }
        if let display {
            try Self.json(display).write(to: sessionDir.appendingPathComponent("display.json"), atomically: true, encoding: .utf8)
        }
    }

    private static func json(_ dict: [String: Any]) -> String {
        // A dictionary literal written in this file cannot fail to serialise. If one
        // ever does, an empty fixture makes the assertion that used it fail loudly,
        // which is a better failure than a crash that takes the whole suite with it.
        guard
            let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    private func manifest(
        sessionId: String = "1770000000000-1770000000000000000-a1b2c3d4e5f60718",
        workspace: String = "/Users/alice/project-x",
        input: Int = 0,
        output: Int = 0,
        model: String? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "schema_version": 3,
            "id": sessionId,
            "authority_id": "authority-1",
            "workspace_root": workspace,
            "created_at_ms": 1_770_000_000_000,
            "updated_at_ms": 1_770_000_600_000,
            "conversation_language": "en",
            "history_len": 2,
            "total_input_tokens": input,
            "total_output_tokens": output
        ]
        if let model {
            dict["preferences"] = ["model": model]
        }
        return dict
    }

    private func sidecar(
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0,
        cost: Double = 0.0425,
        billing: String = "complete",
        models: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "schema_version": 2,
            "billing": billing,
            "api_duration_complete": true,
            "wall_duration_complete": true,
            "code_complete": true,
            "next_sequence": 2,
            "settled_through_sequence": 2,
            "api_duration_ms": 1200,
            "wall_duration_ms": 1500,
            "total_cost": cost,
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_tokens": cacheRead,
            "cache_write_tokens": cacheWrite,
            "reasoning_tokens": reasoning,
            "request_count": 1,
            "billable_web_search_calls": 0,
            "lines_added": 12,
            "lines_removed": 3,
            "models": models,
            "pending": []
        ]
    }

    private func modelEntry(
        name: String,
        cost: Double,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0
    ) -> [String: Any] {
        [
            "model": name,
            "first_sequence": 1,
            "total_cost": cost,
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_tokens": cacheRead,
            "cache_write_tokens": cacheWrite,
            "reasoning_tokens": reasoning,
            "request_count": 1,
            "billable_web_search_calls": 0
        ]
    }

    private func turnEvent(
        seq: Int,
        timestampMs: Int64,
        userText: String,
        assistantText: String,
        tools: [String] = [],
        files: [String] = []
    ) -> String {
        var turn: [String: Any] = [
            "kind": "assistant",
            "user": ["text": userText],
            "assistant": assistantText
        ]
        if !tools.isEmpty || !files.isEmpty {
            var execution: [String: Any] = ["schema_version": 2]
            if !tools.isEmpty {
                execution["tool_steps"] = [
                    [
                        "assistant": "calling \(tools[0])",
                        "tool_calls": tools.map { ["name": $0, "arguments_json": "{}"] },
                        "tool_results": []
                    ]
                ]
            }
            if !files.isEmpty {
                execution["files"] = files.map { ["path": $0, "action": "read", "status": "success"] }
            }
            turn["execution"] = execution
        }
        let frame: [String: Any] = [
            "seq": seq,
            "timestamp_ms": timestampMs,
            "kind": "history_turn_committed",
            "payload": [
                "conversation_language": "en",
                "total_input_tokens": 1200,
                "total_output_tokens": 300,
                "turn": turn
            ]
        ]
        return Self.json(frame)
    }

    // MARK: - Identity

    func testProviderIsFx() {
        let parser = FxParser()
        XCTAssertEqual(parser.provider, .fx)
        XCTAssertEqual(parser.provider.rawValue, "fx")
    }

    // MARK: - Empty / missing

    func testMissingDirectoryYieldsNoUsages() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-fx-missing-\(UUID().uuidString)", isDirectory: true).path
        let result = try await FxParser(logDirectoryOverride: missing).parse()
        XCTAssertTrue(result.usages.isEmpty)
    }

    func testEmptyDirectoryYieldsNoUsages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await FxParser(logDirectoryOverride: dir.path).parse()
        XCTAssertTrue(result.usages.isEmpty)
    }

    func testRootLevelCacheFilesAreIgnored() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // fx writes list.json / summary.json at the sessions root; they are
        // files, not session dirs, and must not produce usage rows.
        try "{\"sessions\":[]}".write(to: dir.appendingPathComponent("list.json"), atomically: true, encoding: .utf8)
        try "{\"count\":0}".write(to: dir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let result = try await FxParser(logDirectoryOverride: dir.path).parse()
        XCTAssertTrue(result.usages.isEmpty)
    }

    // MARK: - Sidecar usage (exact)

    func testSidecarExtractsExactTokensAndCost() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSession(
            dir: dir,
            manifest: manifest(workspace: "/Users/alice/project-x", input: 1200, output: 300),
            sidecar: sidecar(
                input: 1200,
                output: 300,
                cacheRead: 200,
                cacheWrite: 50,
                reasoning: 25,
                cost: 0.0425,
                models: [modelEntry(name: "anthropic/claude-sonnet-4-6", cost: 0.0425, input: 1200, output: 300, cacheRead: 200, cacheWrite: 50, reasoning: 25)]
            )
        )
        let result = try await FxParser(logDirectoryOverride: dir.path).parse()
        XCTAssertEqual(result.usages.count, 1)
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 1200)
        XCTAssertEqual(usage.outputTokens, 300)
        XCTAssertEqual(usage.cacheReadTokens, 200)
        XCTAssertEqual(usage.cacheCreationTokens, 50)
        XCTAssertEqual(usage.reasoningTokens, 25)
        XCTAssertEqual(usage.costUSD, 0.0425, accuracy: 0.0001)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
        XCTAssertEqual(usage.provenanceMethod, .providerLog)
        XCTAssertEqual(usage.projectName, "project-x")
        XCTAssertEqual(usage.model, "claude-sonnet-4-6")
    }

    func testSidecarPreservesExactPerModelRows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSession(
            dir: dir,
            manifest: manifest(),
            sidecar: sidecar(
                input: 2000,
                output: 500,
                cost: 0.10,
                models: [
                    modelEntry(name: "openai/gpt-5.6-luna", cost: 0.02, input: 400, output: 100),
                    modelEntry(name: "anthropic/claude-opus-4-8", cost: 0.08, input: 1600, output: 400)
                ]
            )
        )
        let result = try await FxParser(logDirectoryOverride: dir.path).parse()
        XCTAssertEqual(result.usages.count, 2)
        let byModel = Dictionary(uniqueKeysWithValues: result.usages.map { ($0.model, $0) })

        let gpt = try XCTUnwrap(byModel["gpt-5.6-luna"])
        XCTAssertEqual(gpt.inputTokens, 400)
        XCTAssertEqual(gpt.outputTokens, 100)
        XCTAssertEqual(gpt.costUSD, 0.02, accuracy: 0.0001)

        let claude = try XCTUnwrap(byModel["claude-opus-4-8"])
        XCTAssertEqual(claude.inputTokens, 1600)
        XCTAssertEqual(claude.outputTokens, 400)
        XCTAssertEqual(claude.costUSD, 0.08, accuracy: 0.0001)

        XCTAssertEqual(result.usages.reduce(0) { $0 + $1.inputTokens }, 2000)
        XCTAssertEqual(result.usages.reduce(0) { $0 + $1.outputTokens }, 500)
        XCTAssertEqual(result.usages.reduce(0) { $0 + $1.costUSD }, 0.10, accuracy: 0.0001)
    }

    func testIncompleteBillingGradesAsHighConfidenceEstimate() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSession(
            dir: dir,
            manifest: manifest(),
            sidecar: sidecar(input: 100, output: 50, billing: "incomplete")
        )
        let result = try await FxParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provenanceConfidence, .highConfidenceEstimate)
    }

    // MARK: - Manifest fallback

    func testManifestTotalsFallbackWhenSidecarAbsent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSession(
            dir: dir,
            manifest: manifest(workspace: "/Users/alice/project-y", input: 800, output: 200, model: "anthropic/claude-sonnet-4-6")
        )
        let result = try await FxParser(logDirectoryOverride: dir.path).parse()
        XCTAssertEqual(result.usages.count, 1)
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 800)
        XCTAssertEqual(usage.outputTokens, 200)
        XCTAssertEqual(usage.provenanceConfidence, .lowConfidenceEstimate)
        XCTAssertEqual(usage.model, "claude-sonnet-4-6")
        XCTAssertEqual(usage.projectName, "project-y")
    }

    func testUnknownSidecarSchemaFallsBackToManifestTotals() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var futureSidecar = sidecar(input: 9999, output: 9999, cost: 99.0)
        futureSidecar["schema_version"] = 3
        try writeSession(
            dir: dir,
            manifest: manifest(input: 700, output: 100),
            sidecar: futureSidecar
        )
        let result = try await FxParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 700, "future sidecar schema must not be misparsed")
        XCTAssertEqual(usage.provenanceConfidence, .lowConfidenceEstimate)
    }

    // MARK: - Conversation

    func testConversationFromEventLog() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSession(
            dir: dir,
            manifest: manifest(workspace: "/Users/alice/project-z"),
            sidecar: sidecar(input: 100, output: 50),
            events: [
                turnEvent(
                    seq: 1,
                    timestampMs: 1_770_000_000_000,
                    userText: "Read src/ and explain routing",
                    assistantText: "The router dispatches by path prefix.",
                    tools: ["read_file", "grep"],
                    files: ["src/router.ts"]
                )
            ],
            display: ["title": "Router walkthrough"]
        )
        let options = LogParseOptions(
            includeConversationBodies: true,
            minimumFileModificationDate: nil,
            fileDiscoveryTracker: nil,
            resourceGovernor: nil,
            metrics: nil
        )
        let result = try await FxParser(logDirectoryOverride: dir.path).parse(options: options)
        XCTAssertEqual(result.conversations.count, 1)
        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conversation.inferredTaskTitle, "Router walkthrough")
        XCTAssertEqual(conversation.keyTools, ["grep", "read_file"])
        XCTAssertEqual(conversation.keyFiles, ["src/router.ts"])
        XCTAssertEqual(conversation.workingDirectory, "/Users/alice/project-z")
        XCTAssertTrue(conversation.fullText.contains("Read src/ and explain routing"))
        XCTAssertTrue(conversation.fullText.contains("The router dispatches by path prefix."))
    }

    func testConversationTitleFallsBackToFirstUserText() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSession(
            dir: dir,
            manifest: manifest(),
            sidecar: sidecar(input: 10, output: 5),
            events: [
                turnEvent(seq: 1, timestampMs: 1_770_000_000_000, userText: "Add a test for the router", assistantText: "Done.")
            ]
        )
        let options = LogParseOptions(
            includeConversationBodies: true,
            minimumFileModificationDate: nil,
            fileDiscoveryTracker: nil,
            resourceGovernor: nil,
            metrics: nil
        )
        let result = try await FxParser(logDirectoryOverride: dir.path).parse(options: options)
        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conversation.inferredTaskTitle, "Add a test for the router")
    }

    func testTruncatedEventLineIsSkipped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSession(
            dir: dir,
            manifest: manifest(),
            sidecar: sidecar(input: 100, output: 50),
            events: [
                "{\"seq\":1,\"timestamp_ms\":1770000000000,\"kind\":\"history_turn_committed\",\"payload\":{\"turn\":{\"kind\":\"assistant\",\"user\":{\"text\":\"hi\"},\"assistant\":\"yo\"}}}",
                "{\"seq\":2,\"timestamp_ms\":1770000001000,\"kind\":\"history_turn_committed\",\"payload\":{\"turn\":{\"kind\":\"assistant\",\"user\":{\"text\":\"truncated"
            ]
        )
        let options = LogParseOptions(
            includeConversationBodies: true,
            minimumFileModificationDate: nil,
            fileDiscoveryTracker: nil,
            resourceGovernor: nil,
            metrics: nil
        )
        let result = try await FxParser(logDirectoryOverride: dir.path).parse(options: options)
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.conversations.count, 1)
        XCTAssertEqual(result.conversations.first?.fullText.contains("hi"), true)
    }

    // MARK: - Timestamps

    /// Usage-only ingestion never opens events.jsonl, so the manifest's
    /// created_at_ms/updated_at_ms must date the row. Falling back to the
    /// manifest file's mtime misallocates spend whenever a session file is
    /// rewritten, restored or copied.
    func testUsageRowsUseManifestTimestampsNotFileMtime() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionId = "1770000000000-1770000000000000000-a1b2c3d4e5f60718"
        try writeSession(
            dir: dir,
            sessionId: sessionId,
            manifest: manifest(input: 800, output: 200),
            sidecar: sidecar(input: 800, output: 200)
        )
        // Simulate a restored/copied session file: mtime years away from the
        // session's real activity window.
        let restoredAt = Date(timeIntervalSince1970: 1_600_000_000)
        let manifestPath = dir
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("session.json").path
        try FileManager.default.setAttributes([.modificationDate: restoredAt], ofItemAtPath: manifestPath)

        let result = try await FxParser(logDirectoryOverride: dir.path).parse(options: LogParseOptions(includeConversationBodies: false))
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.startTime.timeIntervalSince1970, 1_770_000_000, accuracy: 0.001)
        XCTAssertEqual(usage.endTime.timeIntervalSince1970, 1_770_000_600, accuracy: 0.001)
    }

    func testUsageRowsFallBackToFileMtimeWhenManifestHasNoTimestamps() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionId = "1770000000000-1770000000000000000-a1b2c3d4e5f60718"
        var legacyManifest = manifest(input: 800, output: 200)
        legacyManifest.removeValue(forKey: "created_at_ms")
        legacyManifest.removeValue(forKey: "updated_at_ms")
        legacyManifest["schema_version"] = 1
        try writeSession(dir: dir, sessionId: sessionId, manifest: legacyManifest)
        let mtime = Date(timeIntervalSince1970: 1_600_000_000)
        let manifestPath = dir
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("session.json").path
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: manifestPath)

        let result = try await FxParser(logDirectoryOverride: dir.path).parse(options: LogParseOptions(includeConversationBodies: false))
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.startTime.timeIntervalSince1970, 1_600_000_000, accuracy: 1)
        XCTAssertEqual(usage.endTime.timeIntervalSince1970, 1_600_000_000, accuracy: 1)
    }

    // MARK: - Transcript ordering

    /// The transcript must read U1, A1, U2, A2 — not every user message
    /// followed by every assistant message — or answers detach from prompts.
    func testTranscriptPreservesEventTurnOrder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSession(
            dir: dir,
            manifest: manifest(),
            sidecar: sidecar(input: 100, output: 50),
            events: [
                turnEvent(seq: 1, timestampMs: 1_770_000_000_000, userText: "USER-ONE", assistantText: "ASSISTANT-ONE"),
                turnEvent(seq: 2, timestampMs: 1_770_000_060_000, userText: "USER-TWO", assistantText: "ASSISTANT-TWO")
            ]
        )
        let options = LogParseOptions(
            includeConversationBodies: true,
            minimumFileModificationDate: nil,
            fileDiscoveryTracker: nil,
            resourceGovernor: nil,
            metrics: nil
        )
        let result = try await FxParser(logDirectoryOverride: dir.path).parse(options: options)
        let conversation = try XCTUnwrap(result.conversations.first)
        let text = conversation.fullText
        let offsets = try ["USER-ONE", "ASSISTANT-ONE", "USER-TWO", "ASSISTANT-TWO"].map { marker in
            try XCTUnwrap(text.range(of: marker), "\(marker) missing from transcript").lowerBound
        }
        XCTAssertEqual(offsets, offsets.sorted(), "turns must stay in event-log order (U1, A1, U2, A2)")
        XCTAssertEqual(conversation.messageCount, 4)
        XCTAssertEqual(conversation.lastAssistantMessage, "ASSISTANT-TWO")
    }

    // MARK: - Cache

    func testCacheHitSkipsRescan() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSession(
            dir: dir,
            manifest: manifest(),
            sidecar: sidecar(input: 100, output: 50)
        )
        let parser = FxParser(logDirectoryOverride: dir.path)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(first.usages.count, 1)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 0)
        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(second.usages.count, 1)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
    }

    func testCachePreservesMultipleModelRows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSession(
            dir: dir,
            manifest: manifest(),
            sidecar: sidecar(
                input: 30,
                output: 15,
                cost: 0.03,
                models: [
                    modelEntry(name: "openai/gpt-5.6-luna", cost: 0.01, input: 10, output: 5),
                    modelEntry(name: "anthropic/claude-opus-4-8", cost: 0.02, input: 20, output: 10)
                ]
            )
        )
        let parser = FxParser(logDirectoryOverride: dir.path)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let firstPass = try await parser.parse(options: usageOnly)
        XCTAssertEqual(firstPass.usages.count, 2)

        let cached = try await parser.parse(options: usageOnly)
        XCTAssertEqual(Set(cached.usages.map(\.model)), ["gpt-5.6-luna", "claude-opus-4-8"])
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
    }
}
