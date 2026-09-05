import XCTest
import OpenBurnBarCore
import OpenBurnBarLogParsers

// MARK: - MuseParserTests
//
// Verifies Muse session parsing at `~/.local/share/muse/sessions/`
// (envelope JSONL with microsecond timestamps, model_completed usage,
// tool_batch tool calls, and starter prompts). Documented findings
// are in `MuseParser.swift` — pricing sourced from
// `~/.local/share/muse/model-catalog/*.json` on the reference host.

final class MuseParserTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-muse-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSession(dir: URL, sessionId: String = "sess-001", content: String) throws -> URL {
        // Muse nests YYYY/MM/DD/<id>/session.jsonl — replicate with temp subdir
        let sessionDir = dir.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let file = sessionDir.appendingPathComponent("session.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func envelope(_ dict: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            XCTFail("Failed to encode Muse envelope JSON")
            return "{}"
        }
        return json
    }

    private func metadataEnvelope(sessionId: String = "sess-001", workspace: String = "/tmp/project-a", model: String = "muse-spark-1.2-contributor", provider: String = "meta") -> String {
        envelope([
            "schema_version": 1,
            "id": UUID().uuidString,
            "stream": ["kind": "session", "id": sessionId],
            "sequence": 1,
            "recorded_at": Int64(Date().timeIntervalSince1970 * 1_000_000),
            "record_type": "event",
            "durability": "durable",
            "payload_type": "runtime.session.metadata",
            "payload_schema_version": 1,
            "payload": [
                "kind": "metadata",
                "record": [
                    "workspace_root": workspace,
                    "provider_id": provider,
                    "model_id": model
                ]
            ]
        ])
    }

    private func modelCompletedEnvelope(sessionId: String = "sess-001", input: Int, output: Int, cached: Int = 0, cacheRead: Int? = nil, cacheWrite: Int = 0, reasoning: Int = 0, model: String = "muse-spark-1.2-contributor") -> String {
        let cr = cacheRead ?? cached
        return envelope([
            "schema_version": 1,
            "id": UUID().uuidString,
            "stream": ["kind": "session", "id": sessionId],
            "sequence": 10,
            "recorded_at": Int64(Date().timeIntervalSince1970 * 1_000_000),
            "record_type": "event",
            "durability": "durable",
            "payload_type": "runtime.session",
            "payload_schema_version": 1,
            "payload": [
                "kind": "run",
                "run_id": "run-1",
                "event": [
                    "kind": "model_completed",
                    "usage": [
                        "input_tokens": input,
                        "output_tokens": output,
                        "cached_tokens": cached,
                        "cache_write_tokens": cacheWrite,
                        "cache_read_tokens": cr,
                        "reasoning_tokens": reasoning
                    ],
                    "duration_ms": 1200,
                    "finish_reason": "tool_calls",
                    "model": model
                ]
            ]
        ])
    }

    private func startedEnvelope(sessionId: String = "sess-001", prompt: String) -> String {
        envelope([
            "schema_version": 1,
            "id": UUID().uuidString,
            "stream": ["kind": "session", "id": sessionId],
            "sequence": 2,
            "recorded_at": Int64(Date().timeIntervalSince1970 * 1_000_000),
            "record_type": "event",
            "durability": "durable",
            "payload_type": "runtime.session",
            "payload_schema_version": 1,
            "payload": [
                "kind": "run",
                "run_id": "run-1",
                "event": [
                    "kind": "started",
                    "prompt": prompt
                ]
            ]
        ])
    }

    private func toolBatchEnvelope(sessionId: String = "sess-001", tool: String) -> String {
        envelope([
            "schema_version": 1,
            "id": UUID().uuidString,
            "stream": ["kind": "session", "id": sessionId],
            "sequence": 5,
            "recorded_at": Int64(Date().timeIntervalSince1970 * 1_000_000),
            "record_type": "event",
            "durability": "durable",
            "payload_type": "tool_batch.effect.started",
            "payload_schema_version": 1,
            "payload": [
                "kind": "tool_batch_effect",
                "run_id": "run-1",
                "record": [
                    "kind": "started",
                    "effect_id": UUID().uuidString,
                    "tool_name": tool
                ]
            ]
        ])
    }

    private func assistantCommittedEnvelope(sessionId: String = "sess-001", text: String) -> String {
        envelope([
            "schema_version": 1,
            "id": UUID().uuidString,
            "stream": ["kind": "session", "id": sessionId],
            "sequence": 6,
            "recorded_at": Int64(Date().timeIntervalSince1970 * 1_000_000),
            "record_type": "event",
            "durability": "durable",
            "payload_type": "runtime.session",
            "payload_schema_version": 1,
            "payload": [
                "kind": "run",
                "run_id": "run-1",
                "event": [
                    "kind": "assistant_message_committed",
                    "text": text
                ]
            ]
        ])
    }

    // MARK: - Identity

    func testProviderIsMuse() {
        let parser = MuseParser()
        XCTAssertEqual(parser.provider, .muse)
        XCTAssertEqual(parser.provider.rawValue, "Muse")
    }

    // MARK: - Empty / missing

    func testEmptyDirectoryYieldsNoUsages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func testMissingDirectoryYieldsNoUsages() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-muse-missing-\(UUID().uuidString)", isDirectory: true).path
        let result = try await MuseParser(logDirectoryOverride: missing).parse()
        XCTAssertTrue(result.usages.isEmpty)
    }

    func testEmptyFileYieldsNoUsages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeSession(dir: dir, content: "")
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        XCTAssertTrue(result.usages.isEmpty)
    }

    func testTruncatedLogGracefullySkipped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // First line valid, second truncated, third valid
        let content = [
            metadataEnvelope(),
            "{\"schema_version\":1,\"id\":\"bad", // truncated
            modelCompletedEnvelope(input: 1000, output: 500, cached: 200, model: "muse-spark-1.2-contributor")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.usages.first?.inputTokens, 1000)
    }

    func testSessionWithNoUsageProducesNoUsageRow() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            metadataEnvelope(),
            startedEnvelope(prompt: "hello"),
            assistantCommittedEnvelope(text: "hi back")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        XCTAssertTrue(result.usages.isEmpty, "no model_completed → no usage row")
        // Conversation should still appear when includeConversationBodies true
        let withConv = try await MuseParser(logDirectoryOverride: dir.path).parse(options: LogParseOptions(includeConversationBodies: true, minimumFileModificationDate: nil, fileDiscoveryTracker: nil, resourceGovernor: nil, metrics: nil))
        XCTAssertEqual(withConv.conversations.count, 1)
    }

    // MARK: - Token extraction

    func testSingleModelCompletedExtractsExactTokensAndCost() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            metadataEnvelope(workspace: "/home/alice/project-x", model: "muse-spark-1.2-contributor"),
            startedEnvelope(prompt: "build a parser"),
            modelCompletedEnvelope(input: 27178, output: 395, cached: 27121, cacheWrite: 0, reasoning: 90, model: "muse-spark-1.2-contributor"),
            assistantCommittedEnvelope(text: "done")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .muse)
        XCTAssertEqual(usage.model, "muse-spark-1.2-contributor")
        XCTAssertEqual(usage.projectName, "project-x")
        XCTAssertEqual(usage.inputTokens, 27178)
        XCTAssertEqual(usage.outputTokens, 395)
        XCTAssertEqual(usage.cacheReadTokens, 27121)
        XCTAssertEqual(usage.reasoningTokens, 90)
        // Cost for contributor: 0.10/M input, 0.20/M output, 0.002/M cached
        // Expected = 27178/1e6*0.10 + 395/1e6*0.20 + 27121/1e6*0.002 ≈ 0.00285
        XCTAssertGreaterThan(usage.costUSD, 0)
        XCTAssertLessThan(usage.costUSD, 0.05)
        XCTAssertEqual(usage.provenanceMethod, .providerLog)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
    }

    func testStandardModelUsesHigherPricing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            metadataEnvelope(model: "muse-spark-1.2"),
            modelCompletedEnvelope(input: 10_000, output: 10_000, cached: 0, model: "muse-spark-1.2")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        // Standard: 1.25/4.25 → cost ≈ 0.0125+0.0425=0.055
        // Contributor at same counts would be 0.001+0.002=0.003 → verify standard is higher
        XCTAssertGreaterThan(usage.costUSD, 0.04)
    }

    func testAggregatesMultipleModelCompletedEvents() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            metadataEnvelope(),
            modelCompletedEnvelope(input: 1000, output: 100, cached: 200, model: "muse-spark-1.2-contributor"),
            modelCompletedEnvelope(input: 2000, output: 300, cached: 400, model: "muse-spark-1.2-contributor")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 3000)
        XCTAssertEqual(usage.outputTokens, 400)
        XCTAssertEqual(usage.cacheReadTokens, 600)
    }

    func testMultiModelSessionKeepsLastModel() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            metadataEnvelope(model: "muse-spark-1.2-contributor"),
            modelCompletedEnvelope(input: 100, output: 50, cached: 10, model: "muse-spark-1.2"),
            modelCompletedEnvelope(input: 200, output: 70, cached: 20, model: "muse-spark-1.2-contributor")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.model, "muse-spark-1.2-contributor", "last model wins")
        XCTAssertEqual(usage.inputTokens, 300)
    }

    func testToolCallsExtracted() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            metadataEnvelope(),
            startedEnvelope(prompt: "read files"),
            toolBatchEnvelope(tool: "read_file"),
            toolBatchEnvelope(tool: "search"),
            modelCompletedEnvelope(input: 500, output: 300, model: "muse-spark-1.2-contributor"),
            assistantCommittedEnvelope(text: "done")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        // Usage still present
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse(options: LogParseOptions(includeConversationBodies: true, minimumFileModificationDate: nil, fileDiscoveryTracker: nil, resourceGovernor: nil, metrics: nil))
        XCTAssertEqual(result.conversations.first?.keyTools.sorted(), ["read_file", "search"])
    }

    func testPromptAndCompletionGoIntoConversation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompt = "improve chichen-itza scale"
        let content = [
            metadataEnvelope(),
            startedEnvelope(prompt: prompt),
            modelCompletedEnvelope(input: 1000, output: 500, model: "muse-spark-1.2-contributor"),
            assistantCommittedEnvelope(text: "Scaled it.")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse(options: LogParseOptions(includeConversationBodies: true, minimumFileModificationDate: nil, fileDiscoveryTracker: nil, resourceGovernor: nil, metrics: nil))
        let conv = try XCTUnwrap(result.conversations.first)
        XCTAssertTrue(conv.fullText.contains(prompt))
        XCTAssertTrue(conv.fullText.contains("Scaled it."))
        XCTAssertEqual(conv.inferredTaskTitle, prompt)
    }

    // MARK: - Pricing fallback

    func testFallbackPricingWhenModelUnknown() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            metadataEnvelope(model: "unknown-model-xyz"),
            modelCompletedEnvelope(input: 1000, output: 1000, model: "unknown-model-xyz")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        // Falls back to ModelPricing.fallback (2.5/10/1.25)
        XCTAssertGreaterThan(usage.costUSD, 0)
    }

    // MARK: - Edge cases

    func testMalformedJsonLineIsSkippedIndependently() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // One malformed line among valid lines — should not abort whole file
        let content = [
            metadataEnvelope(),
            "{\"not\": \"json\"", // missing closing brace but valid truncated-ish
            "not even json at all",
            modelCompletedEnvelope(input: 1500, output: 800, cached: 100, model: "muse-spark-1.2-contributor")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.usages.first?.inputTokens, 1500)
    }

    func testMultipleFilesProduceMultipleUsages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeSession(dir: dir, sessionId: "sess-a", content: [
            metadataEnvelope(sessionId: "sess-a"),
            modelCompletedEnvelope(sessionId: "sess-a", input: 1000, output: 200, model: "muse-spark-1.2-contributor")
        ].joined(separator: "\n"))
        _ = try writeSession(dir: dir, sessionId: "sess-b", content: [
            metadataEnvelope(sessionId: "sess-b"),
            modelCompletedEnvelope(sessionId: "sess-b", input: 3000, output: 400, model: "muse-spark-1.2")
        ].joined(separator: "\n"))
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        XCTAssertEqual(result.usages.count, 2)
        let ids = Set(result.usages.map(\.sessionId))
        XCTAssertTrue(ids.contains("sess-a"))
        XCTAssertTrue(ids.contains("sess-b"))
    }

    func testNonJsonlFilesAreIgnored() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeSession(dir: dir, content: [
            metadataEnvelope(),
            modelCompletedEnvelope(input: 1000, output: 500, model: "muse-spark-1.2-contributor")
        ].joined(separator: "\n"))
        // Drop a non-jsonl file that should be ignored
        let txtFile = dir.appendingPathComponent("sess-ignored", isDirectory: true)
        try FileManager.default.createDirectory(at: txtFile, withIntermediateDirectories: true)
        let ignored = txtFile.appendingPathComponent("notes.txt")
        try "should be ignored".write(to: ignored, atomically: true, encoding: .utf8)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        XCTAssertEqual(result.usages.count, 1, "non-jsonl files are ignored")
    }

    func testCacheBucketsAreDistinct() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            metadataEnvelope(),
            modelCompletedEnvelope(input: 5000, output: 1000, cached: 2000, cacheRead: 2000, cacheWrite: 500, reasoning: 100, model: "muse-spark-1.2-contributor")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 5000)
        XCTAssertEqual(usage.cacheReadTokens, 2000)
        XCTAssertEqual(usage.cacheCreationTokens, 500)
        XCTAssertEqual(usage.reasoningTokens, 100)
    }

    // MARK: - Subagent sessions

    func testSubagentSessionIsSeparateRow() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // root session
        _ = try writeSession(dir: dir, sessionId: "root-123", content: [
            metadataEnvelope(sessionId: "root-123"),
            modelCompletedEnvelope(sessionId: "root-123", input: 1000, output: 500, model: "muse-spark-1.2-contributor")
        ].joined(separator: "\n"))
        // subagent file under root/subagent/<uuid>/session.jsonl — create manually
        let subRoot = dir.appendingPathComponent("root-123", isDirectory: true).appendingPathComponent("subagent", isDirectory: true).appendingPathComponent("sub-uuid-1", isDirectory: true)
        try FileManager.default.createDirectory(at: subRoot, withIntermediateDirectories: true)
        let subFile = subRoot.appendingPathComponent("session.jsonl")
        let subContent = [
            metadataEnvelope(sessionId: "sub-uuid-1"),
            modelCompletedEnvelope(sessionId: "sub-uuid-1", input: 2000, output: 700, model: "muse-spark-1.2-contributor")
        ].joined(separator: "\n")
        try subContent.write(to: subFile, atomically: true, encoding: .utf8)

        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        XCTAssertEqual(result.usages.count, 2, "root + subagent should be separate rows")
        let ids = Set(result.usages.map(\.sessionId))
        XCTAssertTrue(ids.contains("root-123"))
        XCTAssertTrue(ids.contains("sub-uuid-1"))
    }

    // MARK: - Spark 1.3 / Muse Code 1.0.2 envelopes

    func testSpark13ContributorExtractsTokensAndContributorPricing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            metadataEnvelope(model: "muse-spark-1.3-contributor"),
            modelCompletedEnvelope(input: 10_000, output: 2_000, cached: 1_000, model: "muse-spark-1.3-contributor")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.model, "muse-spark-1.3-contributor")
        XCTAssertEqual(usage.inputTokens, 10_000)
        XCTAssertEqual(usage.outputTokens, 2_000)
        XCTAssertEqual(usage.cacheReadTokens, 1_000)
        // Contributor: 0.10/M in + 0.20/M out + 0.002/M cache = 0.001 + 0.0004 + 0.000002
        XCTAssertEqual(usage.costUSD, 0.001402, accuracy: 0.000001)
    }

    func testSpark13StandardUsesHigherPricingThanContributor() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            metadataEnvelope(model: "muse-spark-1.3"),
            modelCompletedEnvelope(input: 10_000, output: 10_000, cached: 0, model: "muse-spark-1.3")
        ].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.model, "muse-spark-1.3")
        // Standard 1.25/4.25 → 0.0125 + 0.0425 = 0.055
        XCTAssertEqual(usage.costUSD, 0.055, accuracy: 0.0001)
    }

    func testRetainedFrameWrapperStillYieldsModelCompletedUsage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = modelCompletedEnvelope(input: 27778, output: 526, reasoning: 455, model: "muse-spark-1.3-contributor")
        let wrapped = envelope([
            "retained_frame": "session_permission_transaction",
            "frame_schema_version": 1,
            "outer_log_ordinal": 1,
            "transaction_id": UUID().uuidString,
            "children": [
                [
                    "child_index": 0,
                    "record_json": inner
                ]
            ]
        ])
        _ = try writeSession(dir: dir, content: wrapped)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.model, "muse-spark-1.3-contributor")
        XCTAssertEqual(usage.inputTokens, 27778)
        XCTAssertEqual(usage.outputTokens, 526)
        XCTAssertEqual(usage.reasoningTokens, 455)
    }

    func testRetainedFrameWithMetadataAndModelCompletedSiblingsYieldsTokens() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let metadata = metadataEnvelope(model: "muse-spark-1.3-contributor")
        let completed = modelCompletedEnvelope(input: 111, output: 22, reasoning: 3, model: "muse-spark-1.3-contributor")
        let wrapped = envelope([
            "retained_frame": "session_permission_transaction",
            "frame_schema_version": 1,
            "children": [
                ["child_index": 0, "record_json": metadata],
                ["child_index": 1, "record_json": completed]
            ]
        ])
        _ = try writeSession(dir: dir, content: wrapped)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.model, "muse-spark-1.3-contributor")
        XCTAssertEqual(usage.inputTokens, 111)
        XCTAssertEqual(usage.outputTokens, 22)
        XCTAssertEqual(usage.reasoningTokens, 3)
    }

    func testRunModelConfiguredSetsModelWhenCompletedOmitsIt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var completed = modelCompletedEnvelope(input: 100, output: 50, model: "muse-spark-1.3")
        // Drop the model field to force run.model.configured to win.
        completed = completed.replacingOccurrences(of: ",\"model\":\"muse-spark-1.3\"", with: "")
        let configured = envelope([
            "schema_version": 1,
            "id": UUID().uuidString,
            "stream": ["kind": "session", "id": "sess-001"],
            "sequence": 3,
            "recorded_at": Int64(Date().timeIntervalSince1970 * 1_000_000),
            "record_type": "event",
            "durability": "durable",
            "payload_type": "run.model.configured",
            "payload_schema_version": 1,
            "payload": [
                "kind": "run_model",
                "record": [
                    "provider_id": "meta",
                    "model_id": "muse-spark-1.3-contributor",
                    "source": "startup"
                ]
            ]
        ])
        let content = [configured, completed].joined(separator: "\n")
        _ = try writeSession(dir: dir, content: content)
        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.model, "muse-spark-1.3-contributor")
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 50)
    }

    func testRealMuseCodeSessionFixtureCountsExactTokens() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(forResource: "muse-code-real-session-usage", withExtension: "jsonl"),
            "real Muse Code usage fixture missing from test bundle"
        )
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionDir = dir.appendingPathComponent("01a05a23-e1be-7e43-bbe5-df89e49d2a57", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtureURL,
            to: sessionDir.appendingPathComponent("session.jsonl")
        )

        let result = try await MuseParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .muse)
        XCTAssertEqual(usage.sessionId, "01a05a23-e1be-7e43-bbe5-df89e49d2a57")
        XCTAssertEqual(usage.model, "muse-spark-1.2-contributor")
        XCTAssertEqual(usage.projectName, "burnbar-muse-fixture")
        XCTAssertEqual(usage.inputTokens, 27778)
        XCTAssertEqual(usage.outputTokens, 526)
        XCTAssertEqual(usage.reasoningTokens, 455)
        XCTAssertEqual(usage.cacheReadTokens, 0)
        // Contributor: 27778/1e6*0.10 + 526/1e6*0.20
        XCTAssertEqual(usage.costUSD, 0.002883, accuracy: 0.000001)
        XCTAssertEqual(usage.provenanceMethod, .providerLog)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
    }
}
