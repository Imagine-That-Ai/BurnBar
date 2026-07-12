import XCTest
@testable import OpenBurnBar

final class JunieParserTests: XCTestCase {

    // MARK: - Helpers

    /// Builds `<root>/sessions/<sessionId>/…` mirroring Junie's documented
    /// on-disk layout (`~/.junie/sessions/index.jsonl` +
    /// `<sessionId>/events.jsonl` + `<sessionId>/state.json`).
    private func makeTempRoots() throws -> (tempRoot: URL, sessionsRoot: URL, supportRoot: URL) {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-junie-parser-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = tempRoot.appendingPathComponent("sessions", isDirectory: true)
        let supportRoot = tempRoot.appendingPathComponent("support", isDirectory: true)
        try fileManager.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        return (tempRoot, sessionsRoot, supportRoot)
    }

    private func writeSession(
        sessionsRoot: URL,
        sessionId: String,
        events: String,
        state: String? = nil
    ) throws {
        let sessionDir = sessionsRoot.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try events.write(
            to: sessionDir.appendingPathComponent("events.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        if let state {
            try state.write(
                to: sessionDir.appendingPathComponent("state.json"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    // MARK: - Basics

    func testParseEmptyDirectory() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func testParseMissingDirectoryReturnsEmpty() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-junie-missing-\(UUID().uuidString)", isDirectory: true)
        let parser = JunieParser(sessionsDirectoryOverride: missing)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func testProviderReturnsCorrectValue() {
        let parser = JunieParser()
        XCTAssertEqual(parser.provider, .junie)
    }

    // MARK: - Explicit usage extraction

    func testExplicitUsageBucketsAndIndexProjectMapping() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260701-191559-1tv1"
        // Session index carries the projectPath field (Junie associates
        // sessions with projects by field, not directory nesting).
        try """
        {"sessionId":"\(sessionId)","projectPath":"/Users/alberto/Projects/demo","createdAt":1782951360319}
        """.write(
            to: sessionsRoot.appendingPathComponent("index.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"message","timestamp":"2026-07-01T19:16:02.000Z","message":{"role":"user","content":"Fix the failing test"}}
            {"type":"message","timestamp":"2026-07-01T19:16:20.000Z","message":{"role":"assistant","content":"Done — the test passes now.","usage":{"input_tokens":1000,"output_tokens":100,"cache_creation_input_tokens":50,"cache_read_input_tokens":2000}},"model":"claude-sonnet-4-5"}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .junie)
        XCTAssertEqual(usage.sessionId, sessionId)
        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 100)
        XCTAssertEqual(usage.cacheCreationTokens, 50)
        XCTAssertEqual(usage.cacheReadTokens, 2000)
        XCTAssertEqual(usage.model, "claude-sonnet-4-5")
        XCTAssertEqual(usage.provenanceConfidence, .exact)
        // Vendor-model pricing resolves through the global catalog even
        // though there is no "junie" provider block.
        XCTAssertGreaterThan(usage.costUSD, 0)
        // Project path from the index, abbreviated for display.
        XCTAssertTrue(usage.projectName.contains("Projects/demo"), "got \(usage.projectName)")
    }

    func testStateJSONUsageTotalsWin() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260701-201000-ab12"
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"message","message":{"role":"user","content":"hello"}}
            """,
            state: """
            {"model":"gpt-5.5","projectPath":"/Users/alberto/Projects/other","usage":{"inputTokens":500,"outputTokens":250}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 500)
        XCTAssertEqual(usage.outputTokens, 250)
        XCTAssertEqual(usage.model, "gpt-5.5")
        XCTAssertEqual(usage.provenanceConfidence, .exact)
        XCTAssertTrue(usage.projectName.contains("Projects/other"), "got \(usage.projectName)")
    }

    func testStateJSONTotalsSkipEventUsageBuckets() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260701-201500-ab13"
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"message","message":{"role":"assistant","content":"reply","usage":{"input_tokens":25,"output_tokens":75}}}
            """,
            state: """
            {"model":"gpt-5.5","usage":{"inputTokens":500,"outputTokens":250}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 500)
        XCTAssertEqual(usage.outputTokens, 250)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
    }

    func testInlinePricedModelBeatsUnpricedStatePlaceholder() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260701-202000-ab14"
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"message","message":{"role":"assistant","content":"reply","usage":{"input_tokens":1000,"output_tokens":100}},"model":"claude-sonnet-4-5"}
            """,
            state: """
            {"model":"default"}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.model, "claude-sonnet-4-5")
        XCTAssertGreaterThan(usage.costUSD, 0)
    }

    func testEnvelopeWrappedEventsAreUnwrapped() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260701-203000-cd34"
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"event","event":{"message":{"role":"assistant","content":"wrapped reply"},"usage":{"input_tokens":300,"output_tokens":40},"model":"claude-haiku-4-5"}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 300)
        XCTAssertEqual(usage.outputTokens, 40)
        XCTAssertEqual(usage.model, "claude-haiku-4-5")
        XCTAssertEqual(usage.provenanceConfidence, .exact)
    }

    // MARK: - Fallback estimation

    func testNoExplicitUsageFallsBackToCharacterEstimate() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260701-210000-ef56"
        let longAnswer = String(repeating: "The build is green and the tests pass. ", count: 40)
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"message","message":{"role":"user","content":"Summarize the repo state for me please."}}
            {"type":"message","message":{"role":"assistant","content":"\(longAnswer)"}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertGreaterThan(usage.inputTokens, 0)
        XCTAssertGreaterThan(usage.outputTokens, 0)
        XCTAssertEqual(usage.provenanceConfidence, .lowConfidenceEstimate)
    }

    func testSessionWithNoContentProducesNoUsage() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: "session-260701-220000-gh78",
            events: """
            {"type":"lifecycle","phase":"onboarding"}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
    }

    // MARK: - Schema-variant contract tests (best-known real shape)
    //
    // TODO(junie-schema-pin): these inline fixtures pin the best-known
    // events.jsonl/state.json/index.jsonl shapes from PR #1136's live-install
    // inspection. JetBrains does not publicly document the on-disk schema, so
    // the one thing that still needs a REAL authenticated Junie session is
    // capturing a frozen session triple and promoting it into the
    // ParserContract corpus (pc-junie-*). See JunieParser.swift header.

    /// A full session triple (index.jsonl + events.jsonl + state.json) in the
    /// best-known real shape: lifecycle noise, roled messages, explicit usage
    /// on the assistant message, model + projectPath in state.json.
    func testBestKnownRealShapeSessionTriple() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260711-101500-zz99"
        try """
        {"sessionId":"\(sessionId)","projectPath":"/Users/alberto/Projects/triple","createdAt":1783764900000}
        """.write(
            to: sessionsRoot.appendingPathComponent("index.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"lifecycle","phase":"sessionStarted","timestamp":"2026-07-11T10:15:00.000Z"}
            {"type":"message","timestamp":"2026-07-11T10:15:02.000Z","message":{"role":"user","content":"Add a regression test"}}
            {"type":"message","timestamp":"2026-07-11T10:15:30.000Z","message":{"role":"assistant","content":"Added and passing.","usage":{"input_tokens":800,"output_tokens":120,"cache_read_input_tokens":300}}}
            {"type":"lifecycle","phase":"sessionEnded","timestamp":"2026-07-11T10:15:31.000Z"}
            """,
            state: """
            {"model":"claude-sonnet-4-5","projectPath":"/Users/alberto/Projects/triple","env":{"OPAQUE":"enc:v1:abc"}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.sessionId, sessionId)
        XCTAssertEqual(usage.inputTokens, 800)
        XCTAssertEqual(usage.outputTokens, 120)
        XCTAssertEqual(usage.cacheReadTokens, 300)
        XCTAssertEqual(usage.model, "claude-sonnet-4-5")
        XCTAssertEqual(usage.provenanceConfidence, .exact)
        XCTAssertTrue(usage.projectName.contains("Projects/triple"), "got \(usage.projectName)")
        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertTrue(conversation.inferredTaskTitle.contains("regression test"))
    }

    /// Reasoning/thinking tokens are a distinct bucket (VAL-TOKEN-006) and
    /// must survive into the TokenUsage record, not be dropped.
    func testReasoningTokensBucketIsPreserved() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: "session-260711-110000-rt01",
            events: """
            {"type":"message","message":{"role":"assistant","content":"done","usage":{"input_tokens":400,"output_tokens":90,"completion_tokens_details":{"reasoning_tokens":256}}}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 400)
        XCTAssertEqual(usage.outputTokens, 90)
        XCTAssertEqual(usage.reasoningTokens, 256)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
    }

    /// A session whose ONLY explicit bucket is reasoning tokens is still an
    /// exact measurement — it must not fall back to character estimation.
    func testReasoningOnlyUsageDoesNotFallBackToEstimate() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: "session-260711-111500-rt02",
            events: """
            {"type":"message","message":{"role":"user","content":"think hard about the flaky test"}}
            {"type":"message","message":{"role":"assistant","content":"thought about it","usage":{"reasoning_tokens":512}}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.reasoningTokens, 512)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
    }

    /// Junie builds vary between camelCase and snake_case index fields.
    func testSnakeCaseIndexFieldsMapProject() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260711-112000-sc03"
        try """
        {"session_id":"\(sessionId)","project_path":"/Users/alberto/Projects/snake"}
        """.write(
            to: sessionsRoot.appendingPathComponent("index.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"message","message":{"role":"assistant","content":"ok","usage":{"input_tokens":10,"output_tokens":5}}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertTrue(usage.projectName.contains("Projects/snake"), "got \(usage.projectName)")
    }

    /// The `data` envelope key variant unwraps like `event`/`payload`.
    func testDataEnvelopeKeyUnwraps() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: "session-260711-113000-de04",
            events: """
            {"type":"agentEvent","data":{"message":{"role":"assistant","content":"wrapped in data","usage":{"input_tokens":70,"output_tokens":20}},"model":"gpt-5.5"}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 70)
        XCTAssertEqual(usage.outputTokens, 20)
        XCTAssertEqual(usage.model, "gpt-5.5")
    }

    /// Malformed lines interleaved with valid ones must be skipped, not fatal.
    func testMalformedLinesAreSkipped() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: "session-260711-114500-ml05",
            events: """
            this is not json
            {"type":"message","message":{"role":"user","content":"still parses"}}
            {"truncated": "line
            {"type":"message","message":{"role":"assistant","content":"yes","usage":{"input_tokens":33,"output_tokens":11}}}
            []
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 33)
        XCTAssertEqual(usage.outputTokens, 11)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
    }

    /// A `total_tokens`-only usage record normalizes into input/output
    /// buckets (VAL-TOKEN-004) instead of being treated as absent.
    func testTotalTokensOnlyUsageNormalizes() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: "session-260711-115900-tt06",
            events: """
            {"type":"message","message":{"role":"user","content":"How many tokens did that take?"}}
            {"type":"message","message":{"role":"assistant","content":"A fair few.","usage":{"total_tokens":900}}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens + usage.outputTokens, 900)
        XCTAssertGreaterThan(usage.inputTokens, 0)
        XCTAssertGreaterThan(usage.outputTokens, 0)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
    }

    // MARK: - Conversations + caching

    func testConversationRecordAndDiskCacheRoundTrip() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260701-230000-ij90"
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"message","timestamp":"2026-07-01T23:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"Refactor the parser module"}]}}
            {"type":"message","timestamp":"2026-07-01T23:00:30.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Refactor complete."}],"usage":{"input_tokens":120,"output_tokens":30}}}
            """
        )

        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: supportRoot)
        let parser = JunieParser(
            appPaths: appPaths,
            sessionsDirectoryOverride: sessionsRoot
        )
        let first = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        let conversation = try XCTUnwrap(first.conversations.first)
        XCTAssertEqual(conversation.provider, .junie)
        XCTAssertEqual(conversation.sessionId, sessionId)
        XCTAssertTrue(conversation.inferredTaskTitle.contains("Refactor"))

        // Second parse must serve the identical usage from the disk cache.
        let second = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(second.usages.count, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 120)
        XCTAssertEqual(second.usages.first?.outputTokens, 30)
        XCTAssertEqual(second.conversations.count, 1)
    }
}
