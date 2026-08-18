import Foundation
import XCTest
@testable import OpenBurnBarLogParsers
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

final class AdditionalLocalUsageParsersTests: XCTestCase {
    func testAiderAnalyticsGroupsExactMessageUsage() async throws {
        let root = try makeDirectory("aider")
        defer { remove(root) }
        try write(
            """
            {"event":"launched","time":100,"properties":{"main_model":"claude-3-7-sonnet"}}
            {"event":"message_send","time":110,"properties":{"prompt_tokens":120,"completion_tokens":30,"cost":0.12}}
            {"event":"exit","time":120}
            """,
            to: root.appendingPathComponent("analytics.jsonl")
        )

        let result = try await AiderParser(rootOverride: root).parse()
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.usages.first?.inputTokens, 120)
        XCTAssertEqual(result.usages.first?.outputTokens, 30)
        XCTAssertEqual(result.usages.first?.provenanceConfidence, .exact)
    }

    func testPiAgentAndOpenClawPreserveExplicitUsageAndTranscript() async throws {
        let piRoot = try makeDirectory("pi")
        let clawRoot = try makeDirectory("claw")
        defer { remove(piRoot); remove(clawRoot) }
        try write(
            """
            {"timestamp":"2026-07-01T00:00:00Z","model":"gpt-4o","role":"user","content":"hello"}
            {"timestamp":"2026-07-01T00:00:01Z","model":"gpt-4o","role":"assistant","content":"world","usage":{"input_tokens":11,"output_tokens":7}}
            """,
            to: piRoot.appendingPathComponent("pi-session.jsonl")
        )
        try write(
            """
            {"timestamp":"2026-07-01T00:00:00Z","model":"claude-3-7-sonnet","role":"user","content":"hello","usage":{"input_tokens":13,"output_tokens":5}}
            {"timestamp":"2026-07-01T00:00:01Z","role":"assistant","content":"world"}
            """,
            to: clawRoot.appendingPathComponent("claw-session.jsonl")
        )

        let pi = try await PiAgentParser(sessionsOverride: piRoot).parse()
        let claw = try await OpenClawParser(sessionsOverride: clawRoot).parse()
        XCTAssertEqual(pi.usages.first?.inputTokens, 11)
        XCTAssertEqual(pi.usages.first?.outputTokens, 7)
        XCTAssertEqual(pi.conversations.count, 1)
        XCTAssertEqual(claw.usages.first?.inputTokens, 13)
        XCTAssertEqual(claw.usages.first?.outputTokens, 5)
        XCTAssertEqual(claw.conversations.count, 1)
    }

    func testOMPReadsPiCompatibleNestedMessagesAndPreservesProviderIdentity() async throws {
        let root = try makeDirectory("omp")
        defer { remove(root) }
        try write(
            """
            {"type":"session","version":3,"id":"omp-session","timestamp":"2026-07-01T00:00:00Z","cwd":"/tmp/omp-demo"}
            {"type":"message","message":{"role":"user","content":[{"type":"text","text":"inspect"}],"timestamp":"2026-07-01T00:00:01Z"}}
            {"type":"message","message":{"role":"assistant","model":"claude-3-7-sonnet","content":[{"type":"text","text":"done"}],"usage":{"input":17,"output":4,"cacheRead":2,"cacheWrite":1},"timestamp":"2026-07-01T00:00:02Z"}}
            """,
            to: root.appendingPathComponent("omp-session.jsonl")
        )

        let result = try await OMPParser(sessionsOverride: root).parse()
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.usages.first?.provider, .omp)
        XCTAssertEqual(result.usages.first?.inputTokens, 17)
        XCTAssertEqual(result.usages.first?.outputTokens, 4)
        XCTAssertEqual(result.usages.first?.cacheReadTokens, 2)
        XCTAssertEqual(result.usages.first?.cacheCreationTokens, 1)
        XCTAssertEqual(result.usages.first?.projectName, "omp-demo")
        XCTAssertEqual(result.conversations.first?.provider, .omp)
        XCTAssertEqual(result.conversations.first?.lastAssistantMessage, "done")
    }

    func testOMPUsageOnlyStreamsLargeMalformedCorpusWithoutExtractingTranscriptBodies() async throws {
        let root = try makeDirectory("omp-large-stream")
        defer { remove(root) }
        let file = root.appendingPathComponent("large-session.jsonl")
        let payload = String(repeating: "x", count: 1_024)
        var data = Data()
        for index in 0..<4_096 {
            if index.isMultiple(of: 257) {
                data.append(Data("not-json-\(index)\n".utf8))
            } else {
                data.append(
                    Data(
                        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"\#(payload)"}]},"timestamp":"2026-07-01T00:00:00Z"}\#n"#
                            .utf8
                    )
                )
            }
        }
        data.append(
            Data(
                #"{"type":"message","message":{"role":"assistant","model":"gpt-5","content":[{"type":"text","text":"done"}],"usage":{"input":123,"output":45},"timestamp":"2026-07-01T00:00:01Z"}}\#n"#
                    .utf8
            )
        )
        try data.write(to: file, options: .atomic)

        let parser = OMPParser(sessionsOverride: root)
        let result = try await parser.parse(
            options: LogParseOptions(includeConversationBodies: false)
        )

        XCTAssertEqual(result.usages.first?.inputTokens, 123)
        XCTAssertEqual(result.usages.first?.outputTokens, 45)
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertEqual(
            parser.lastContentExtractionLineCount,
            0,
            "usage-only explicit accounting must never flatten multi-megabyte transcript bodies"
        )
    }

    func testPiUsageOnlyFallbackMatchesConversationPassAndCachesMalformedInput() async throws {
        let root = try makeDirectory("pi-fallback-parity")
        defer { remove(root) }
        try write(
            """
            {"timestamp":"2026-07-01T00:00:00Z","model":"gpt-4o","role":"user","content":"Please inspect the parser."}
            malformed-json
            {"timestamp":"2026-07-01T00:00:01Z","model":"gpt-4o","role":"assistant","content":"The parser is sound."}
            """,
            to: root.appendingPathComponent("pi-session.jsonl")
        )

        let parser = PiAgentParser(sessionsOverride: root)
        let usageOnly = try await parser.parse(
            options: LogParseOptions(includeConversationBodies: false)
        )
        let usageOnlyRecord = try XCTUnwrap(usageOnly.usages.first)
        XCTAssertEqual(parser.lastContentExtractionLineCount, 2)
        XCTAssertTrue(usageOnly.conversations.isEmpty)
        XCTAssertEqual(usageOnlyRecord.provenanceConfidence, .lowConfidenceEstimate)

        let indexed = try await parser.parse(
            options: LogParseOptions(includeConversationBodies: true)
        )
        let indexedRecord = try XCTUnwrap(indexed.usages.first)
        XCTAssertEqual(indexedRecord.inputTokens, usageOnlyRecord.inputTokens)
        XCTAssertEqual(indexedRecord.outputTokens, usageOnlyRecord.outputTokens)
        XCTAssertEqual(indexedRecord.costUSD, usageOnlyRecord.costUSD)
        XCTAssertEqual(indexed.conversations.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(indexed.conversations.first?.fullText)
                .contains("Please inspect the parser.")
        )

        let cached = try await parser.parse(
            options: LogParseOptions(includeConversationBodies: false)
        )
        XCTAssertEqual(cached.usages.first?.inputTokens, usageOnlyRecord.inputTokens)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(parser.lastContentExtractionLineCount, 0)
    }

    func testOMPCancellationStopsLargeLineScan() async throws {
        let root = try makeDirectory("omp-cancellation")
        defer { remove(root) }
        let file = root.appendingPathComponent("cancel-session.jsonl")
        var data = Data()
        for index in 0..<8_192 {
            data.append(
                Data(
                    #"{"type":"message","message":{"role":"user","content":"line-\#(index)"},"timestamp":"2026-07-01T00:00:00Z"}\#n"#
                        .utf8
                )
            )
        }
        try data.write(to: file, options: .atomic)

        let parser = OMPParser(sessionsOverride: root)
        let task = Task {
            try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled OMP scan to stop at a line checkpoint")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testPiMalformedLinesCheckpointBothUsagePassesBeforeEOF() async throws {
        let root = try makeDirectory("pi-malformed-checkpoints")
        defer { remove(root) }
        let file = root.appendingPathComponent("malformed-session.jsonl")
        var data = Data()
        for index in 0..<70_000 {
            data.append(Data("not-json-\(index)\n".utf8))
        }
        data.append(
            Data(
                #"{"role":"user","content":"fallback usage","timestamp":"2026-07-01T00:00:00Z"}\#n"#
                    .utf8
            )
        )
        try data.write(to: file, options: .atomic)

        let footprintCalls = Locked(0)
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: 500),
            footprintProvider: {
                footprintCalls.withLock { calls in
                    calls += 1
                    return calls <= 3 ? 100 : 1_000
                }
            }
        )

        do {
            _ = try await PiAgentParser(sessionsOverride: root).parse(
                options: LogParseOptions(
                    includeConversationBodies: false,
                    resourceGovernor: governor
                )
            )
            XCTFail("Expected malformed physical lines to trigger the fallback-pass resource checkpoint")
        } catch let error as ParserResourceExceeded {
            XCTAssertEqual(
                error,
                .memoryCeiling(footprintBytes: 1_000, ceilingBytes: 500)
            )
        }
        XCTAssertEqual(
            footprintCalls.read(),
            4,
            "the fourth sampled checkpoint is reachable only when both passes count malformed physical lines"
        )
    }

    func testOMPCacheCheckpointSurvivesMidCorpusResourceAbort() async throws {
        let root = try makeDirectory("omp-checkpoint")
        defer { remove(root) }
        for index in 0..<40 {
            try write(
                #"{"type":"message","message":{"role":"assistant","model":"gpt-5","usage":{"input":1,"output":1},"timestamp":"2026-07-01T00:00:00Z"}}"#,
                to: root.appendingPathComponent(
                    String(format: "session-%03d.jsonl", index)
                )
            )
        }

        let footprintCalls = Locked(0)
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: 500),
            footprintProvider: {
                footprintCalls.withLock { calls in
                    calls += 1
                    return calls <= 2 ? 100 : 1_000
                }
            }
        )
        let interrupted = OMPParser(sessionsOverride: root)
        do {
            _ = try await interrupted.parse(
                options: LogParseOptions(
                    includeConversationBodies: false,
                    resourceGovernor: governor
                )
            )
            XCTFail("Expected the synthetic footprint ceiling to abort the scan")
        } catch let error as ParserResourceExceeded {
            XCTAssertEqual(
                error,
                .memoryCeiling(footprintBytes: 1_000, ceilingBytes: 500)
            )
        }

        let resumed = OMPParser(sessionsOverride: root)
        let result = try await resumed.parse(
            options: LogParseOptions(includeConversationBodies: false)
        )
        XCTAssertEqual(result.usages.count, 40)
        XCTAssertEqual(
            resumed.lastSessionCacheHitCount,
            32,
            "two 16-file checkpoints must survive an abort on file 33"
        )
        XCTAssertEqual(resumed.lastSessionScanCount, 8)
    }

    func testOpenClaudeReadsClaudeCompatibleProjectTranscriptAndPreservesProviderIdentity() async throws {
        let root = try makeDirectory("openclaude")
        defer { remove(root) }
        let assistantLine = #"{"type":"assistant","timestamp":"2026-07-01T00:00:01Z","sessionId":"openclaude-session","cwd":"/tmp/openclaude-demo","#
            + #""message":{"role":"assistant","model":"claude-3-7-sonnet","content":[{"type":"text","text":"done"}],"#
            + #""usage":{"input_tokens":19,"output_tokens":5,"cache_read_input_tokens":2,"cache_creation_input_tokens":1}}}"#
        try write(
            """
            {"type":"user","timestamp":"2026-07-01T00:00:00Z","sessionId":"openclaude-session","cwd":"/tmp/openclaude-demo","message":{"role":"user","content":[{"type":"text","text":"inspect"}]}}
            \(assistantLine)
            """,
            to: root.appendingPathComponent("-Users-test-Project/openclaude-session.jsonl")
        )

        let parser = ClaudeCodeParser(projectsDirectoryOverride: root, provider: .openClaude)
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(usage.provider, .openClaude)
        XCTAssertEqual(usage.inputTokens, 19)
        XCTAssertEqual(usage.outputTokens, 5)
        XCTAssertEqual(usage.cacheReadTokens, 2)
        XCTAssertEqual(usage.cacheCreationTokens, 1)
        XCTAssertEqual(usage.projectName, "~/Project")
        XCTAssertEqual(conversation.provider, .openClaude)
        XCTAssertEqual(conversation.lastAssistantMessage, "done")
    }

    func testOllamaReadsOnlyExplicitServerCounters() async throws {
        let root = try makeDirectory("ollama")
        defer { remove(root) }
        try write(
            #"{"time":"2026-07-01T00:00:00Z","model":"llama3.2","prompt_eval_count":44,"eval_count":9}"#,
            to: root.appendingPathComponent("server.log")
        )
        let result = try await OllamaParser(logsOverride: root).parse()
        XCTAssertEqual(result.usages.first?.inputTokens, 44)
        XCTAssertEqual(result.usages.first?.outputTokens, 9)
        XCTAssertEqual(result.usages.first?.provenanceConfidence, .exact)
    }

    func testCursorSQLiteAggregatesCodeHashesWithExplicitLowConfidenceMarker() async throws {
        let root = try makeDirectory("cursor")
        defer { remove(root) }
        let path = root.appendingPathComponent("ai-code-tracking.db")
        let db = try SQLiteConnection.openForWriting(creatingAt: path.path)
        defer { db.close() }
        try db.execute("CREATE TABLE ai_code_hashes (conversationId TEXT, model TEXT, createdAt INTEGER)")
        try db.execute("INSERT INTO ai_code_hashes VALUES (?, ?, ?)", arguments: [.text("conversation-1"), .text("gpt-4o"), .int(1_750_000_000)])
        try db.execute("INSERT INTO ai_code_hashes VALUES (?, ?, ?)", arguments: [.text("conversation-1"), .text("gpt-4o"), .int(1_750_000_001)])
        let result = try await CursorParser(databaseOverride: path).parse()
        XCTAssertEqual(result.usages.first?.sessionId, "conversation-1")
        XCTAssertEqual(result.usages.first?.inputTokens, 1_000)
        XCTAssertEqual(result.usages.first?.outputTokens, 300)
        XCTAssertEqual(result.usages.first?.provenanceConfidence, .lowConfidenceEstimate)
    }

    func testOpenCodeSQLiteJoinsMessagePartsAndUsage() async throws {
        let root = try makeDirectory("opencode")
        defer { remove(root) }
        let path = root.appendingPathComponent("opencode.db")
        let db = try SQLiteConnection.openForWriting(creatingAt: path.path)
        defer { db.close() }
        try db.execute("CREATE TABLE session (id TEXT, data TEXT, time_created INTEGER, time_updated INTEGER)")
        try db.execute("CREATE TABLE message (id TEXT, sessionID TEXT, data TEXT, time_created INTEGER)")
        try db.execute("CREATE TABLE part (messageID TEXT, data TEXT)")
        try db.execute("INSERT INTO session VALUES (?, ?, ?, ?)", arguments: [.text("session-1"), .text(#"{"title":"Demo","directory":"/tmp/demo","time":{"created":1750000000,"updated":1750000002}}"#), .int(1_750_000_000), .int(1_750_000_002)])
        try db.execute("INSERT INTO message VALUES (?, ?, ?, ?)", arguments: [.text("message-1"), .text("session-1"), .text(#"{"role":"assistant","model":"gpt-4o","tokens":{"input":21,"output":9},"cost":0.02,"time":{"created":1750000001}}"#), .int(1_750_000_001)])
        try db.execute("INSERT INTO part VALUES (?, ?)", arguments: [.text("message-1"), .text(#"{"type":"text","text":"done"}"#)])
        let result = try await OpenCodeParser(databaseOverride: path).parse()
        XCTAssertEqual(result.usages.first?.inputTokens, 21)
        XCTAssertEqual(result.usages.first?.outputTokens, 9)
        XCTAssertEqual(try XCTUnwrap(result.usages.first?.costUSD), 0.02, accuracy: 0.000_001)
        XCTAssertEqual(result.conversations.first?.lastAssistantMessage, "done")
    }

    func testJunieReadsIndexProjectAndUsageEnvelope() async throws {
        let root = try makeDirectory("junie")
        defer { remove(root) }
        let session = root.appendingPathComponent("session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try write(#"{"sessionId":"session-1","projectPath":"/tmp/demo"}"#, to: root.appendingPathComponent("index.jsonl"))
        try write(
            """
            {"payload":{"role":"user","content":"inspect","usage":{"input_tokens":17,"output_tokens":4},"model":"gemini-2.5-pro"},"timestamp":"2026-07-01T00:00:00Z"}
            {"payload":{"role":"assistant","content":"done"},"timestamp":"2026-07-01T00:00:01Z"}
            """,
            to: session.appendingPathComponent("events.jsonl")
        )
        let result = try await JunieParser(sessionsOverride: root).parse()
        XCTAssertEqual(result.usages.first?.inputTokens, 17)
        XCTAssertEqual(result.usages.first?.outputTokens, 4)
        XCTAssertEqual(result.usages.first?.projectName, "/tmp/demo")
    }

    func testModelFilterKeepsProviderSpecificFactorySessions() async throws {
        let root = try makeDirectory("factory")
        defer { remove(root) }
        try write(
            #"{"timestamp":"2026-07-01T00:00:00Z","model":"zai-glm-5","message":{"role":"assistant","content":"done","usage":{"input_tokens":8,"output_tokens":3}}}"#,
            to: root.appendingPathComponent("project/session.jsonl")
        )
        let result = try await ModelFilterParser(modelPattern: "zai", provider: .zai, sessionsOverride: root).parse()
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.usages.first?.provider, .zai)
        XCTAssertEqual(result.usages.first?.inputTokens, 8)
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("obb-additional-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
