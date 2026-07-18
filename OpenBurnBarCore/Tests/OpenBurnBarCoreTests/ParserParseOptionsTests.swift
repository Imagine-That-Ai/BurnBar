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

    func testAntigravityRegistryInjectedUnlimitedGovernorUsesConfiguredFallbackModel() async throws {
        let root = try makeTemporaryDirectory("antigravity-registry-fallback")
        defer { try? fileManager.removeItem(at: root) }

        try write(
            #"{"model":"Configured Registry Fallback Model"}"#,
            to: root.appendingPathComponent("settings.json")
        )
        let transcript = root
            .appendingPathComponent("brain/session-1/.system_generated/logs", isDirectory: true)
            .appendingPathComponent("transcript_full.jsonl")
        try write(
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-05-27T06:00:00Z","content":"Use the configured model."}
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-27T06:00:01Z","content":"Done."}
            """,
            to: transcript
        )

        let parser = AntigravityParser(logDirectoryOverride: root.path)
        let result = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: true,
            resourceGovernor: ParserResourceGovernor(limits: .unlimited)
        ))

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(usage.model, "Configured Registry Fallback Model")
    }

    func testAntigravityBoundedGovernorDoesNotReadConfiguredFallbackModel() async throws {
        let root = try makeTemporaryDirectory("antigravity-bounded-fallback")
        defer { try? fileManager.removeItem(at: root) }

        try write(
            #"{"model":"Configured Model Must Stay Unread"}"#,
            to: root.appendingPathComponent("settings.json")
        )
        let transcript = root
            .appendingPathComponent("brain/session-1/.system_generated/logs", isDirectory: true)
            .appendingPathComponent("transcript_full.jsonl")
        try write(
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-05-27T06:00:00Z","content":"Respect the bounded pass."}
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-27T06:00:01Z","content":"Done."}
            """,
            to: transcript
        )

        let metrics = ParserPassMetrics()
        let parser = AntigravityParser(logDirectoryOverride: root.path)
        let result = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: true,
            resourceGovernor: ParserResourceGovernor(
                limits: ParserResourceLimits(fileByteBudget: 1_000_000)
            ),
            metrics: metrics
        ))

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(usage.model, "Claude Opus 4.6 (Thinking)")
        XCTAssertEqual(metrics.snapshot().contentReadCount, 1,
                       "A bounded pass should admit only the transcript, not settings.json")
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

    func testClaudeCodeMetricsStatUnchangedFilesAndChargeChangedContentExactlyOnce() async throws {
        let root = try makeTemporaryDirectory("claude-metrics")
        defer { try? fileManager.removeItem(at: root) }
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let project = projectsRoot.appendingPathComponent("-Users-test-Project", isDirectory: true)
        let transcript = project.appendingPathComponent("metrics.jsonl")
        try write(claudeSession(user: "Initial", input: 100, output: 20), to: transcript)
        let parser = ClaudeCodeParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)
            ),
            projectsDirectoryOverride: projectsRoot
        )

        let firstGovernor = ParserResourceGovernor(limits: .unlimited)
        let firstMetrics = ParserPassMetrics()
        let first = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            resourceGovernor: firstGovernor,
            metrics: firstMetrics
        ))
        let firstSize = Int64(try Data(contentsOf: transcript).count)
        XCTAssertEqual(first.usages.first?.inputTokens, 100)
        XCTAssertEqual(firstMetrics.snapshot().contentReadCount, 1)
        XCTAssertEqual(firstMetrics.snapshot().contentReadBytes, firstSize)
        XCTAssertEqual(firstGovernor.consumedBytes, firstSize)

        let unchangedGovernor = ParserResourceGovernor(limits: .unlimited)
        let unchangedMetrics = ParserPassMetrics()
        let unchanged = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            resourceGovernor: unchangedGovernor,
            metrics: unchangedMetrics
        ))
        let unchangedSnapshot = unchangedMetrics.snapshot()
        XCTAssertEqual(unchanged.usages.first?.inputTokens, 100)
        XCTAssertEqual(unchangedSnapshot.candidateCount, 1)
        XCTAssertEqual(unchangedSnapshot.metadataStatCount, 1)
        XCTAssertEqual(unchangedSnapshot.contentReadCount, 0, "the unchanged file must be statted but never opened")
        XCTAssertEqual(unchangedSnapshot.contentReadBytes, 0)
        XCTAssertEqual(unchangedGovernor.consumedBytes, 0)

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + claudeSession(user: "Changed", input: 7, output: 2)).utf8))
        try handle.close()
        let changedSize = Int64(try Data(contentsOf: transcript).count)
        let changedGovernor = ParserResourceGovernor(limits: .unlimited)
        let changedMetrics = ParserPassMetrics()
        let changed = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            resourceGovernor: changedGovernor,
            metrics: changedMetrics
        ))
        let changedSnapshot = changedMetrics.snapshot()

        XCTAssertEqual(changed.usages.first?.inputTokens, 107)
        XCTAssertEqual(changedSnapshot.candidateCount, 1)
        XCTAssertEqual(changedSnapshot.metadataStatCount, 1)
        XCTAssertEqual(changedSnapshot.contentReadCount, 1)
        XCTAssertEqual(changedSnapshot.contentReadBytes, changedSize)
        XCTAssertEqual(changedGovernor.consumedBytes, changedSize, "one changed file must be charged exactly once")
    }

    func testClaudeCodeMetricsDistinguishMissingMetadataFromContentReadFailure() async throws {
        let root = try makeTemporaryDirectory("claude-deferred-reasons")
        defer { try? fileManager.removeItem(at: root) }
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let project = projectsRoot.appendingPathComponent("-Users-test-Project", isDirectory: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        let dangling = project.appendingPathComponent("missing-metadata.jsonl")
        try fileManager.createSymbolicLink(
            at: dangling,
            withDestinationURL: project.appendingPathComponent("absent.jsonl")
        )
        let metadataParser = ClaudeCodeParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("metadata-support", isDirectory: true)
            ),
            projectsDirectoryOverride: projectsRoot
        )
        let metadataGovernor = ParserResourceGovernor(limits: .unlimited)
        let metadataMetrics = ParserPassMetrics()

        _ = try await metadataParser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            minimumFileModificationDate: .distantPast,
            resourceGovernor: metadataGovernor,
            metrics: metadataMetrics
        ))

        XCTAssertEqual(metadataGovernor.deferredFileCount, 1)
        XCTAssertEqual(metadataMetrics.snapshot().metadataUnavailableDeferredCount, 1)
        XCTAssertEqual(metadataMetrics.snapshot().contentReadCount, 0)

        try fileManager.removeItem(at: dangling)
        let unreadable = project.appendingPathComponent("unreadable.jsonl")
        try write(claudeSession(user: "Unreadable", input: 20, output: 4), to: unreadable)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let readFailureParser = ClaudeCodeParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("read-failure-support", isDirectory: true)
            ),
            projectsDirectoryOverride: projectsRoot
        )
        let readFailureGovernor = ParserResourceGovernor(limits: .unlimited)
        let readFailureMetrics = ParserPassMetrics()

        let readFailure = try await readFailureParser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            resourceGovernor: readFailureGovernor,
            metrics: readFailureMetrics
        ))

        XCTAssertTrue(readFailure.usages.isEmpty)
        XCTAssertEqual(readFailureGovernor.deferredFileCount, 1)
        XCTAssertEqual(readFailureMetrics.snapshot().contentReadFailedDeferredCount, 1)
        XCTAssertEqual(readFailureMetrics.snapshot().contentReadCount, 1, "failed content reads remain charged after admission")
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
