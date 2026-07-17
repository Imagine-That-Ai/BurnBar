import Foundation
import OpenBurnBarKernel
import XCTest
@testable import OpenBurnBarLogParsers

final class ParserParseOptionsTests: XCTestCase {
    private let fileManager = FileManager.default

    func testAntigravityOptionsPreserveUsageAndGateConversationBodiesAndHistory() async throws {
        let root = try makeTemporaryDirectory("antigravity")
        defer { try? fileManager.removeItem(at: root) }

        let transcript = root
            .appendingPathComponent("brain/session-1/.system_generated/logs", isDirectory: true)
            .appendingPathComponent("transcript_full.jsonl")
        try write(
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-05-27T06:00:00Z","content":"Please inspect this project."}
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-27T06:00:01Z","content":"Inspection complete."}
            """,
            to: transcript
        )

        let parser = AntigravityParser(logDirectoryOverride: root.path)
        let indexed = try await parser.parse()
        XCTAssertEqual(indexed.usages.count, 1)
        XCTAssertEqual(indexed.conversations.count, 1)

        let usageOnly = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(usageOnly.usages.count, 1)
        XCTAssertTrue(usageOnly.conversations.isEmpty)

        let deferred = try await parser.parse(options: futureUsageOnlyOptions)
        XCTAssertTrue(deferred.usages.isEmpty)
        XCTAssertTrue(deferred.conversations.isEmpty)
    }

    func testClaudeCodeOptionsUseCachedHistoricalRowsWithoutParsingUncachedHistory() async throws {
        let root = try makeTemporaryDirectory("claude")
        defer { try? fileManager.removeItem(at: root) }

        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let project = projectsRoot.appendingPathComponent("-Users-test-Project", isDirectory: true)
        let primary = project.appendingPathComponent("session-1.jsonl")
        let subagent = project
            .appendingPathComponent("session-1/subagents", isDirectory: true)
            .appendingPathComponent("agent-research.jsonl")
        try write(claudeSession(user: "Primary request", input: 100, output: 20), to: primary)
        try write(claudeSession(user: "Subagent request", input: 40, output: 10), to: subagent)
        try setModificationDate(.distantPast, for: [primary, subagent])

        let appPaths = OpenBurnBarAppPaths(
            applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)
        )
        let parser = ClaudeCodeParser(
            fileManager: fileManager,
            appPaths: appPaths,
            projectsDirectoryOverride: projectsRoot
        )

        let initial = try await parser.parse()
        XCTAssertEqual(initial.usages.count, 2)
        XCTAssertEqual(initial.conversations.count, 1)

        let cacheHydrated = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(cacheHydrated.usages.count, 2)
        XCTAssertEqual(cacheHydrated.conversations.count, 1)

        let uncached = project.appendingPathComponent("uncached-old.jsonl")
        try write(claudeSession(user: "Do not parse", input: 900, output: 90), to: uncached)
        try setModificationDate(.distantPast, for: [uncached])

        let historical = try await parser.parse(
            options: LogParseOptions(
                includeConversationBodies: true,
                minimumFileModificationDate: .distantFuture
            )
        )
        XCTAssertEqual(historical.usages.count, 2)
        XCTAssertTrue(historical.conversations.isEmpty)
        XCTAssertFalse(historical.usages.contains { $0.sessionId == "uncached-old" })

        let usageOnly = try await parser.parse(options: futureUsageOnlyOptions)
        XCTAssertEqual(usageOnly.usages.count, 2)
        XCTAssertTrue(usageOnly.conversations.isEmpty)
    }

    func testCodexOptionsReturnEmptyWhenTheStateDatabaseIsUnavailable() async throws {
        let root = try makeTemporaryDirectory("codex")
        defer { try? fileManager.removeItem(at: root) }

        let parser = CodexParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)
            ),
            homeDirectoryURL: root
        )

        let defaultResult = try await parser.parse()
        XCTAssertTrue(defaultResult.usages.isEmpty)
        XCTAssertTrue(defaultResult.conversations.isEmpty)

        let usageOnly = try await parser.parse(options: futureUsageOnlyOptions)
        XCTAssertTrue(usageOnly.usages.isEmpty)
        XCTAssertTrue(usageOnly.conversations.isEmpty)
    }

    func testFactoryOptionsPreserveUsageAndGateConversationBodiesAndHistory() async throws {
        let root = try makeTemporaryDirectory("factory")
        defer { try? fileManager.removeItem(at: root) }

        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let project = sessionsRoot.appendingPathComponent("-Users-test-Project", isDirectory: true)
        let transcript = project.appendingPathComponent("factory-1.jsonl")
        let settings = project.appendingPathComponent("factory-1.settings.json")
        try write(
            """
            {"type":"user","timestamp":"2026-05-04T08:00:00Z","message":{"role":"user","content":"Factory request"}}
            {"type":"assistant","timestamp":"2026-05-04T08:00:01Z","message":{"role":"assistant","content":"Done","model":"glm-4","usage":{"input_tokens":80,"output_tokens":20}}}
            """,
            to: transcript
        )
        try write(
            """
            {"model":"glm-4","tokenUsage":{"input_tokens":80,"output_tokens":20,"total_tokens":100}}
            """,
            to: settings
        )

        let parser = FactoryDroidParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)
            ),
            sessionsDirectoryOverride: sessionsRoot
        )

        let indexed = try await parser.parse()
        XCTAssertEqual(indexed.usages.count, 1)
        XCTAssertEqual(indexed.conversations.count, 1)

        let cacheHydrated = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(cacheHydrated.usages.count, 1)
        XCTAssertEqual(cacheHydrated.conversations.count, 1)

        let usageOnly = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(usageOnly.usages.count, 1)
        XCTAssertTrue(usageOnly.conversations.isEmpty)

        let deferred = try await parser.parse(options: futureUsageOnlyOptions)
        XCTAssertTrue(deferred.usages.isEmpty)
        XCTAssertTrue(deferred.conversations.isEmpty)
    }

    func testGeminiOptionsCoverJSONAndJSONLWithoutBuildingConversationBodies() async throws {
        let root = try makeTemporaryDirectory("gemini")
        defer { try? fileManager.removeItem(at: root) }

        let chats = root.appendingPathComponent("project-1/chats", isDirectory: true)
        try write(
            """
            {"role":"user","content":"Refactor this","timestamp":"2026-05-04T08:00:00Z"}
            {"role":"model","content":"Done","timestamp":"2026-05-04T08:01:00Z","usage":{"input_tokens":120,"output_tokens":45}}
            """,
            to: chats.appendingPathComponent("session-jsonl.jsonl")
        )
        try write(
            """
            {"messages":[
              {"role":"user","content":"Review this","createTime":"2026-05-05T10:00:00Z"},
              {"role":"model","content":"Reviewed","createTime":"2026-05-05T10:00:05Z","usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":7}}
            ]}
            """,
            to: chats.appendingPathComponent("session-json.json")
        )

        let parser = GeminiCLIParser(logDirectoryOverride: root.path)
        let indexed = try await parser.parse()
        XCTAssertEqual(indexed.usages.count, 2)
        XCTAssertEqual(indexed.conversations.count, 2)

        let usageOnly = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(usageOnly.usages.count, 2)
        XCTAssertTrue(usageOnly.conversations.isEmpty)

        let deferred = try await parser.parse(options: futureUsageOnlyOptions)
        XCTAssertTrue(deferred.usages.isEmpty)
        XCTAssertTrue(deferred.conversations.isEmpty)
    }

    func testHermesOptionsCoverGatewaySnapshotAndLegacyTranscripts() async throws {
        let root = try makeTemporaryDirectory("hermes")
        defer { try? fileManager.removeItem(at: root) }

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try write(
            """
            {"gateway":{"session_id":"gateway-1","created_at":"2026-05-06T10:00:00Z","updated_at":"2026-05-06T10:01:00Z","model":"hermes-model","platform":"gateway","input_tokens":50,"output_tokens":12}}
            """,
            to: sessions.appendingPathComponent("sessions.json")
        )
        try write(
            hermesTranscript(user: "Gateway request", assistant: "Gateway response"),
            to: sessions.appendingPathComponent("gateway-1.jsonl")
        )
        try write(
            """
            {
              "session_id":"snapshot-1",
              "model":"hermes-model",
              "platform":"cron",
              "session_start":"2026-05-06T11:00:00Z",
              "last_updated":"2026-05-06T11:01:00Z",
              "messages":[
                {"role":"user","content":"Snapshot request","timestamp":"2026-05-06T11:00:00Z"},
                {"role":"assistant","content":"Snapshot response","timestamp":"2026-05-06T11:01:00Z"}
              ]
            }
            """,
            to: sessions.appendingPathComponent("session_snapshot-1.json")
        )
        try write(
            hermesTranscript(user: "Legacy request", assistant: "Legacy response"),
            to: sessions.appendingPathComponent("legacy-1.jsonl")
        )

        let parser = HermesParser(fileManager: fileManager, hermesRootURL: root)
        let indexed = try await parser.parse()
        XCTAssertEqual(indexed.usages.count, 3)
        XCTAssertEqual(indexed.conversations.count, 3)

        let usageOnly = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(usageOnly.usages.count, 3)
        XCTAssertTrue(usageOnly.conversations.isEmpty)

        let deferred = try await parser.parse(options: futureUsageOnlyOptions)
        XCTAssertTrue(deferred.usages.isEmpty)
        XCTAssertTrue(deferred.conversations.isEmpty)
    }

    func testKimiOptionsPreserveWireUsageWithoutConversationBodies() async throws {
        let root = try makeTemporaryDirectory("kimi")
        defer { try? fileManager.removeItem(at: root) }

        let session = root.appendingPathComponent("workspace/session-1", isDirectory: true)
        try write(
            """
            {"role":"user","content":"Test","created_at":"2026-05-04T08:00:00Z"}
            {"role":"assistant","content":"Done","created_at":"2026-05-04T08:00:01Z"}
            """,
            to: session.appendingPathComponent("context.jsonl")
        )
        try write(
            """
            {"message":{"type":"StatusUpdate","payload":{"message_id":"msg-1","token_usage":{"input_other":100,"output":25,"input_cache_read":10,"input_cache_creation":5}}}}
            """,
            to: session.appendingPathComponent("wire.jsonl")
        )

        let parser = KimiParser(logDirectoryOverride: root.path)
        let indexed = try await parser.parse()
        XCTAssertEqual(indexed.usages.count, 1)
        XCTAssertEqual(indexed.conversations.count, 1)

        let usageOnly = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(usageOnly.usages.count, 1)
        XCTAssertEqual(usageOnly.usages.first?.inputTokens, 100)
        XCTAssertTrue(usageOnly.conversations.isEmpty)

        let deferred = try await parser.parse(options: futureUsageOnlyOptions)
        XCTAssertTrue(deferred.usages.isEmpty)
        XCTAssertTrue(deferred.conversations.isEmpty)
    }

    func testWindsurfOptionsPreserveEstimatedUsageWithoutConversationBodies() async throws {
        let root = try makeTemporaryDirectory("windsurf")
        defer { try? fileManager.removeItem(at: root) }

        let cascade = root.appendingPathComponent("cascade", isDirectory: true)
        let globalStorage = root.appendingPathComponent("globalStorage", isDirectory: true)
        let protobuf = cascade.appendingPathComponent("session-1.pb")
        try write(String(repeating: "x", count: 512), to: protobuf)

        let parser = WindsurfParser(
            cascadeDirectoryOverride: cascade.path,
            globalStorageOverride: globalStorage.path
        )
        let indexed = try await parser.parse()
        XCTAssertEqual(indexed.usages.count, 1)
        XCTAssertEqual(indexed.conversations.count, 1)

        let usageOnly = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(usageOnly.usages.count, 1)
        XCTAssertTrue(usageOnly.conversations.isEmpty)

        let deferred = try await parser.parse(options: futureUsageOnlyOptions)
        XCTAssertTrue(deferred.usages.isEmpty)
        XCTAssertTrue(deferred.conversations.isEmpty)
    }

    func testClaudeCodeBoundedSteadyStatePerformsNoContentReadsAcrossTwoPasses() async throws {
        let root = try makeTemporaryDirectory("claude-steady-state")
        defer { try? fileManager.removeItem(at: root) }

        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let project = projectsRoot.appendingPathComponent("-Users-test-Project", isDirectory: true)
        let transcript = project.appendingPathComponent("steady-state.jsonl")
        try write(claudeSession(user: "Read exactly once", input: 100, output: 20), to: transcript)
        let attributes = try fileManager.attributesOfItem(atPath: transcript.path)
        let transcriptByteCount = try XCTUnwrap((attributes[.size] as? NSNumber)?.int64Value)

        let parser = ClaudeCodeParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)
            ),
            projectsDirectoryOverride: projectsRoot
        )
        let initialGovernor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: .max)
        )
        let initial = try await parser.parse(
            options: LogParseOptions(
                includeConversationBodies: true,
                resourceGovernor: initialGovernor
            )
        )
        XCTAssertEqual(initial.usages.count, 1)
        XCTAssertEqual(initial.conversations.count, 1)
        XCTAssertEqual(
            initialGovernor.consumedBytes,
            transcriptByteCount,
            "the admission counter must observe the transcript immediately before its content read"
        )

        for pass in 1...2 {
            let steadyStateGovernor = ParserResourceGovernor(
                limits: ParserResourceLimits(fileByteBudget: .max)
            )
            let steadyState = try await parser.parse(
                options: LogParseOptions(
                    includeConversationBodies: true,
                    minimumFileModificationDate: .distantFuture,
                    resourceGovernor: steadyStateGovernor
                )
            )

            XCTAssertEqual(steadyState.usages.count, 1, "pass \(pass) must retain cached usage")
            XCTAssertTrue(steadyState.conversations.isEmpty, "pass \(pass) must not reconstruct historical bodies")
            XCTAssertEqual(steadyStateGovernor.consumedBytes, 0, "pass \(pass) must not admit or read unchanged content")
            XCTAssertEqual(steadyStateGovernor.deferredFileCount, 0)
        }
    }

    func testLegacyConformerRejectsBoundedOptionsBeforeContentRead() async throws {
        let readProbe = ParserContentReadProbe()
        let parser: any LogParser = LegacyContentReadingParser(readProbe: readProbe)
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: 1)
        )

        do {
            _ = try await parser.parse(
                options: LogParseOptions(
                    includeConversationBodies: false,
                    minimumFileModificationDate: .distantFuture,
                    resourceGovernor: governor
                )
            )
            XCTFail("A legacy conformer must reject bounded parsing instead of entering parse()")
        } catch let error as ParserOptionsUnsupported {
            XCTAssertEqual(error.provider, .copilot)
        } catch {
            XCTFail("Expected ParserOptionsUnsupported, got \(error)")
        }

        let contentReadCount = await readProbe.count()
        XCTAssertEqual(contentReadCount, 0, "the bounded-options guard must run before legacy content reads")
        XCTAssertEqual(governor.consumedBytes, 0)
        XCTAssertEqual(governor.deferredFileCount, 1, "rejection must freeze the provider watermark for retry")
    }

    private var futureUsageOnlyOptions: LogParseOptions {
        LogParseOptions(
            includeConversationBodies: false,
            minimumFileModificationDate: .distantFuture
        )
    }

    private func makeTemporaryDirectory(_ label: String) throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-\(label)-options-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func setModificationDate(_ date: Date, for urls: [URL]) throws {
        for url in urls {
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    private func claudeSession(user: String, input: Int, output: Int) -> String {
        """
        {"type":"user","timestamp":"2026-05-04T08:00:00Z","message":{"role":"user","content":[{"type":"text","text":"\(user)"}]}}
        {"type":"assistant","timestamp":"2026-05-04T08:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"Done"}],"usage":{"input_tokens":\(input),"output_tokens":\(output)},"model":"claude-sonnet-4"}}
        """
    }

    private func hermesTranscript(user: String, assistant: String) -> String {
        """
        {"role":"user","content":"\(user)","timestamp":"2026-05-06T10:00:00Z"}
        {"role":"assistant","content":"\(assistant)","timestamp":"2026-05-06T10:01:00Z","model":"hermes-model","usage":{"input_tokens":20,"output_tokens":5}}
        """
    }
}

private actor ParserContentReadProbe {
    private var contentReadCount = 0

    func recordContentRead() {
        contentReadCount += 1
    }

    func count() -> Int {
        contentReadCount
    }
}

private struct LegacyContentReadingParser: LogParser {
    let provider: AgentProvider = .copilot
    let readProbe: ParserContentReadProbe

    func parse() async throws -> ParseResult {
        await readProbe.recordContentRead()
        return ParseResult(usages: [], conversations: [])
    }
}
