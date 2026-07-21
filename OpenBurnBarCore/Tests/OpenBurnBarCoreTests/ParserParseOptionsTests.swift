import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader
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

    func testAntigravityBoundedGovernorReadsConfiguredFallbackModel() async throws {
        let root = try makeTemporaryDirectory("antigravity-bounded-fallback")
        defer { try? fileManager.removeItem(at: root) }

        try write(
            #"{"model":"Configured Bounded Model"}"#,
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
        XCTAssertEqual(usage.model, "Configured Bounded Model")
        XCTAssertEqual(
            metrics.snapshot().contentReadCount,
            2,
            "the bounded pass must account for both settings.json and the transcript"
        )
    }

    func testAntigravityOversizedSettingsAreRejectedBeforeContentAllocation() async throws {
        let root = try makeTemporaryDirectory("antigravity-oversized-settings")
        defer { try? fileManager.removeItem(at: root) }

        let settings = root.appendingPathComponent("settings.json")
        let oversizedSettings = #"{"model":""#
            + String(repeating: "x", count: AntigravityParser.maximumSettingsFileBytes)
            + #""}"#
        try write(oversizedSettings, to: settings)
        let transcript = root
            .appendingPathComponent("brain/session-oversized/.system_generated/logs", isDirectory: true)
            .appendingPathComponent("transcript_full.jsonl")
        let transcriptFixture = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-05-27T06:00:00Z","content":"Use the safe fallback."}
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-27T06:00:01Z","content":"Done."}
        """
        try write(transcriptFixture, to: transcript)

        let tracker = ParserFileDiscoveryTracker()
        let governor = ParserResourceGovernor(limits: .unlimited)
        let metrics = ParserPassMetrics()
        let result = try await AntigravityParser(logDirectoryOverride: root.path).parse(
            options: LogParseOptions(
                includeConversationBodies: false,
                fileDiscoveryTracker: tracker,
                resourceGovernor: governor,
                metrics: metrics
            )
        )

        XCTAssertEqual(result.usages.first?.model, "Claude Opus 4.6 (Thinking)")
        XCTAssertEqual(governor.deferredFileCount, 1)
        XCTAssertEqual(metrics.snapshot().byteBudgetDeferredCount, 1)
        XCTAssertEqual(metrics.snapshot().contentReadCount, 1, "oversized metadata must not be content-read")
        XCTAssertEqual(
            metrics.snapshot().contentReadBytes,
            Int64(transcriptFixture.utf8.count)
        )
        XCTAssertEqual(
            tracker.partialCheckpointFiles.map(\.path),
            [transcript.standardizedFileURL.path],
            "the oversized settings identity remains retryable while the transcript advances"
        )
    }

    func testAntigravityPartialCheckpointRetryReusesConfiguredFallbackModel() async throws {
        let root = try makeTemporaryDirectory("antigravity-partial-checkpoint-fallback")
        defer { try? fileManager.removeItem(at: root) }

        let configuredModel = "Configured Partial Retry Model"
        let settings = root.appendingPathComponent("settings.json")
        try write(
            #"{"model":"Configured Partial Retry Model"}"#,
            to: settings
        )
        let transcript = root
            .appendingPathComponent("brain/session-retry/.system_generated/logs", isDirectory: true)
            .appendingPathComponent("transcript_full.jsonl")
        try write(
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-05-27T06:00:00Z","content":"Retry this bounded Antigravity transcript."}
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-27T06:00:01Z","content":"Retried."}
            """,
            to: transcript
        )

        let parser = AntigravityParser(logDirectoryOverride: root.path)
        let firstTracker = ParserFileDiscoveryTracker(knownFiles: [])
        let firstMetrics = ParserPassMetrics()
        let settingsSize = Int64(try Data(contentsOf: settings).count)
        let first = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: true,
            fileDiscoveryTracker: firstTracker,
            resourceGovernor: ParserResourceGovernor(
                limits: ParserResourceLimits(fileByteBudget: settingsSize)
            ),
            metrics: firstMetrics
        ))

        XCTAssertTrue(first.usages.isEmpty, "the transcript must remain deferred after settings consume the pass budget")
        XCTAssertEqual(firstMetrics.snapshot().contentReadCount, 1, "only settings.json is admitted on the bounded pass")
        XCTAssertEqual(firstMetrics.snapshot().byteBudgetDeferredCount, 1)
        XCTAssertEqual(
            firstTracker.partialCheckpointFiles.map(\.path),
            [settings.standardizedFileURL.path],
            "the partial manifest must checkpoint admitted settings without checkpointing the deferred transcript"
        )

        let retryTracker = ParserFileDiscoveryTracker(knownFiles: firstTracker.partialCheckpointFiles)
        let retry = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: true,
            fileDiscoveryTracker: retryTracker,
            resourceGovernor: ParserResourceGovernor(limits: .unlimited)
        ))

        let usage = try XCTUnwrap(retry.usages.first)
        XCTAssertEqual(retry.usages.count, 1)
        XCTAssertEqual(usage.model, configuredModel, "retrying only the transcript must preserve the admitted settings model")
        XCTAssertEqual(
            retryTracker.partialCheckpointFiles.map(\.path),
            [transcript, settings].map { $0.standardizedFileURL.path }.sorted()
        )
    }

    func testAntigravitySettingsDecodeFailureCheckpointsAndChangedIdentityRetries() async throws {
        let root = try makeTemporaryDirectory("antigravity-settings-decode-retry")
        defer { try? fileManager.removeItem(at: root) }

        let settings = root.appendingPathComponent("settings.json")
        try write(#"{"model":"#, to: settings)
        let transcript = root
            .appendingPathComponent("brain/session-decode-retry/.system_generated/logs", isDirectory: true)
            .appendingPathComponent("transcript_full.jsonl")
        try write(
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-05-27T06:00:00Z","content":"Parse despite malformed settings."}
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-27T06:00:01Z","content":"Parsed."}
            """,
            to: transcript
        )

        let parser = AntigravityParser(logDirectoryOverride: root.path)
        let failedTracker = ParserFileDiscoveryTracker(knownFiles: [])
        _ = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            fileDiscoveryTracker: failedTracker,
            resourceGovernor: ParserResourceGovernor(limits: .unlimited)
        ))

        XCTAssertEqual(
            failedTracker.partialCheckpointFiles.map(\.path),
            [settings, transcript].map { $0.standardizedFileURL.path }.sorted(),
            "readable malformed settings and their successfully parsed transcript must not freeze checkpoint progress"
        )

        let recoveredModel = "Recovered Settings Model"
        try write(#"{"model":"Recovered Settings Model"}"#, to: settings)
        try write(
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-05-27T06:00:00Z","content":"Parse the repaired settings and changed transcript."}
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-27T06:00:01Z","content":"Recovered with the configured model."}
            """,
            to: transcript
        )

        let retryTracker = ParserFileDiscoveryTracker(knownFiles: failedTracker.partialCheckpointFiles)
        let retry = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            fileDiscoveryTracker: retryTracker,
            resourceGovernor: ParserResourceGovernor(limits: .unlimited)
        ))

        XCTAssertEqual(retry.usages.first?.model, recoveredModel)
        XCTAssertTrue(
            retryTracker.partialCheckpointFiles.contains { $0.path == settings.standardizedFileURL.path },
            "successfully decoded settings must become checkpointable after the retry"
        )
    }

    func testAntigravityContentReadFailureDefersOnlyFailedTranscriptAndRetriesIt() async throws {
        let root = try makeTemporaryDirectory("antigravity-content-read-failure")
        defer { try? fileManager.removeItem(at: root) }

        let failedTranscript = root
            .appendingPathComponent("brain/failed-session/.system_generated/logs", isDirectory: true)
            .appendingPathComponent("transcript_full.jsonl")
        try fileManager.createDirectory(at: failedTranscript, withIntermediateDirectories: true)

        let successfulTranscript = root
            .appendingPathComponent("brain/successful-session/.system_generated/logs", isDirectory: true)
            .appendingPathComponent("transcript_full.jsonl")
        try write(
            """
            {"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-05-27T06:00:00Z","content":"Keep parsing after the sibling transcript fails."}
            {"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-05-27T06:00:01Z","content":"The successful sibling was preserved."}
            """,
            to: successfulTranscript
        )

        let parser = AntigravityParser(logDirectoryOverride: root.path)
        let firstTracker = ParserFileDiscoveryTracker()
        let firstGovernor = ParserResourceGovernor(limits: .unlimited)
        let firstMetrics = ParserPassMetrics()
        let first = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            fileDiscoveryTracker: firstTracker,
            resourceGovernor: firstGovernor,
            metrics: firstMetrics
        ))

        XCTAssertEqual(first.usages.map(\.sessionId), ["successful-session"])
        XCTAssertEqual(firstGovernor.deferredFileCount, 1)
        XCTAssertEqual(firstMetrics.snapshot().contentReadFailedDeferredCount, 1)
        XCTAssertEqual(firstMetrics.snapshot().contentReadCount, 2, "both metadata-admitted transcripts must reach content reading")
        XCTAssertEqual(
            firstTracker.partialCheckpointFiles.map(\.path),
            [successfulTranscript.standardizedFileURL.path],
            "overall progress must not make the unreadable transcript checkpointable"
        )

        try fileManager.removeItem(at: failedTranscript)
        try write(
            """
            {"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-05-27T06:01:00Z","content":"Retry the transcript that could not be read."}
            {"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-05-27T06:01:01Z","content":"The deferred transcript was retried."}
            """,
            to: failedTranscript
        )

        let retryTracker = ParserFileDiscoveryTracker(knownFiles: firstTracker.partialCheckpointFiles)
        let retryMetrics = ParserPassMetrics()
        let retry = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            fileDiscoveryTracker: retryTracker,
            resourceGovernor: ParserResourceGovernor(limits: .unlimited),
            metrics: retryMetrics
        ))

        XCTAssertEqual(retry.usages.map(\.sessionId), ["failed-session"])
        XCTAssertEqual(retryMetrics.snapshot().contentReadFailedDeferredCount, 0)
        XCTAssertEqual(retryMetrics.snapshot().contentReadCount, 1, "the successful sibling must remain checkpointed while the failed transcript retries")
        XCTAssertEqual(
            retryTracker.partialCheckpointFiles.map(\.path),
            [failedTranscript, successfulTranscript].map { $0.standardizedFileURL.path }.sorted()
        )
    }

    func testGooseDatabaseOpenFailureDefersOnlyFailedDatabaseAndRetriesIt() async throws {
        let failedRoot = try makeTemporaryDirectory("goose-database-open-failure")
        defer { try? fileManager.removeItem(at: failedRoot) }
        let successfulRoot = try makeTemporaryDirectory("goose-database-open-success")
        defer { try? fileManager.removeItem(at: successfulRoot) }

        let failedDatabase = failedRoot.appendingPathComponent("sessions.db")
        try fileManager.createDirectory(at: failedDatabase, withIntermediateDirectories: true)
        let successfulDatabase = successfulRoot.appendingPathComponent("sessions.db")
        try createGooseSessionDatabase(
            at: successfulDatabase,
            sessionId: "successful-goose-session",
            inputTokens: 120,
            outputTokens: 30
        )

        let parser = GooseParser(sessionDirectoriesOverride: [failedRoot.path, successfulRoot.path])
        let firstTracker = ParserFileDiscoveryTracker()
        let firstGovernor = ParserResourceGovernor(limits: .unlimited)
        let firstMetrics = ParserPassMetrics()
        let first = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            fileDiscoveryTracker: firstTracker,
            resourceGovernor: firstGovernor,
            metrics: firstMetrics
        ))

        XCTAssertEqual(first.usages.map(\.sessionId), ["successful-goose-session"])
        XCTAssertEqual(firstGovernor.deferredFileCount, 1)
        XCTAssertEqual(firstMetrics.snapshot().contentReadFailedDeferredCount, 1)
        XCTAssertEqual(firstMetrics.snapshot().contentReadCount, 2, "both metadata-admitted databases must reach SQLite opening")
        XCTAssertEqual(
            firstTracker.partialCheckpointFiles.map(\.path),
            [successfulDatabase.standardizedFileURL.path],
            "a successful sibling database must not hide the failed database from the retry manifest"
        )

        try fileManager.removeItem(at: failedDatabase)
        try createGooseSessionDatabase(
            at: failedDatabase,
            sessionId: "retried-goose-session",
            inputTokens: 75,
            outputTokens: 15
        )

        let retryTracker = ParserFileDiscoveryTracker(knownFiles: firstTracker.partialCheckpointFiles)
        let retryMetrics = ParserPassMetrics()
        let retry = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            fileDiscoveryTracker: retryTracker,
            resourceGovernor: ParserResourceGovernor(limits: .unlimited),
            metrics: retryMetrics
        ))

        XCTAssertEqual(retry.usages.map(\.sessionId), ["retried-goose-session"])
        XCTAssertEqual(retryMetrics.snapshot().contentReadFailedDeferredCount, 0)
        XCTAssertEqual(retryMetrics.snapshot().contentReadCount, 1, "only the formerly failed database should be retried")
        XCTAssertEqual(
            retryTracker.partialCheckpointFiles.map(\.path),
            [failedDatabase, successfulDatabase].map { $0.standardizedFileURL.path }.sorted()
        )
    }

    func testGoosePricingFailurePropagatesInsteadOfMasqueradingAsDatabaseReadFailure() async throws {
        let root = try makeTemporaryDirectory("goose-pricing-failure")
        defer { try? fileManager.removeItem(at: root) }
        let database = root.appendingPathComponent("sessions.db")
        try createGooseSessionDatabase(
            at: database,
            sessionId: "pricing-failure-session",
            inputTokens: 120,
            outputTokens: 30
        )

        let governor = ParserResourceGovernor(limits: .unlimited)
        let metrics = ParserPassMetrics()
        let parser = GooseParser(
            sessionDirectoriesOverride: [root.path],
            pricingCost: { _, _, _, _, _ in
                throw ModelPricingError.domainCoreRejected
            }
        )

        do {
            _ = try await parser.parse(options: LogParseOptions(
                includeConversationBodies: false,
                resourceGovernor: governor,
                metrics: metrics
            ))
            XCTFail("semantic pricing failures must escape the parser")
        } catch ModelPricingError.domainCoreRejected {
            // Expected: only SQLite failures are classified as unreadable input.
        }

        XCTAssertEqual(governor.deferredFileCount, 0)
        XCTAssertEqual(metrics.snapshot().contentReadFailedDeferredCount, 0)
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

    func testClaudeCodeNewHistoricalIdentityParsesBeforeKnownIdentitySkips() async throws {
        let root = try makeTemporaryDirectory("claude-new-historical-identity")
        defer { try? fileManager.removeItem(at: root) }

        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let project = projectsRoot.appendingPathComponent("-Users-test-Project", isDirectory: true)
        let transcript = project.appendingPathComponent("restored-old.jsonl")
        try write(claudeSession(user: "Parse the restored transcript", input: 321, output: 45), to: transcript)
        let historicalDate = Date(timeIntervalSince1970: 1_600_000_000)
        try setModificationDate(historicalDate, for: [transcript])
        let attributes = try fileManager.attributesOfItem(atPath: transcript.path)
        let identity = ParserDiscoveredFile.capture(for: transcript, attributes: attributes)
        let boundary = historicalDate.addingTimeInterval(60)

        let parser = ClaudeCodeParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)
            ),
            projectsDirectoryOverride: projectsRoot
        )

        let newlyDiscovered = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: true,
            minimumFileModificationDate: boundary,
            fileDiscoveryTracker: ParserFileDiscoveryTracker(knownFiles: [])
        ))

        let parsedUsage = try XCTUnwrap(newlyDiscovered.usages.first)
        XCTAssertEqual(newlyDiscovered.usages.count, 1)
        XCTAssertEqual(parsedUsage.sessionId, "restored-old")
        XCTAssertEqual(parsedUsage.inputTokens, 321)
        XCTAssertEqual(parsedUsage.outputTokens, 45)
        let parsedConversation = try XCTUnwrap(newlyDiscovered.conversations.first)
        XCTAssertEqual(newlyDiscovered.conversations.count, 1)
        XCTAssertTrue(parsedConversation.fullText.contains("Parse the restored transcript"))

        let alreadyKnown = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: true,
            minimumFileModificationDate: boundary,
            fileDiscoveryTracker: ParserFileDiscoveryTracker(knownFiles: [identity])
        ))

        XCTAssertEqual(alreadyKnown.usages.map(\.sessionId), ["restored-old"])
        XCTAssertEqual(alreadyKnown.usages.first?.inputTokens, 321)
        XCTAssertTrue(alreadyKnown.conversations.isEmpty)
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

    func testCodexBodyBudgetDeferralRemovesAdmittedIdentityAndRetriesConversation() async throws {
        let root = try makeTemporaryDirectory("codex-body-budget-retry")
        defer { try? fileManager.removeItem(at: root) }

        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let rollout = codexRoot.appendingPathComponent("rollout-retry.jsonl")
        let rolloutFixture = """
        {"type":"turn_context","timestamp":"2026-07-18T12:00:00.000Z","payload":{"model":"openai/gpt-5.2-codex"}}
        {"type":"event_msg","timestamp":"2026-07-18T12:00:01.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":40,"output_tokens":16},"model":"openai/gpt-5.2-codex"}}}
        {"item":{"role":"user","content":"Retry the deferred Codex body."}}
        {"item":{"role":"assistant","content":"The deferred Codex body was retried."}}
        """
        try write(rolloutFixture, to: rollout)
        _ = try createCodexThreadDatabase(at: codexRoot, rolloutPath: rollout.path)
        let rolloutSize = Int64(try Data(contentsOf: rollout).count)

        let parser = CodexParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)
            ),
            homeDirectoryURL: root
        )
        let firstTracker = ParserFileDiscoveryTracker(knownFiles: [])
        let firstMetrics = ParserPassMetrics()
        let first = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: true,
            fileDiscoveryTracker: firstTracker,
            resourceGovernor: ParserResourceGovernor(
                limits: ParserResourceLimits(fileByteBudget: rolloutSize)
            ),
            metrics: firstMetrics
        ))

        let usage = try XCTUnwrap(first.usages.first)
        XCTAssertEqual(first.usages.count, 1)
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.cacheReadTokens, 40)
        XCTAssertEqual(usage.outputTokens, 16)
        XCTAssertTrue(first.conversations.isEmpty, "the body read must defer after usage consumes the pass budget")
        XCTAssertEqual(firstMetrics.snapshot().byteBudgetDeferredCount, 1)
        XCTAssertEqual(firstTracker.discoveredFiles.map(\.path), [rollout.standardizedFileURL.path])
        XCTAssertTrue(
            firstTracker.partialCheckpointFiles.isEmpty,
            "a body-deferred rollout identity must stay out of the partial checkpoint"
        )

        let retryTracker = ParserFileDiscoveryTracker(knownFiles: firstTracker.partialCheckpointFiles)
        let retry = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: true,
            fileDiscoveryTracker: retryTracker,
            resourceGovernor: ParserResourceGovernor(limits: .unlimited)
        ))

        XCTAssertEqual(retry.usages.first?.inputTokens, 120)
        XCTAssertEqual(retry.usages.first?.cacheReadTokens, 40)
        let conversation = try XCTUnwrap(retry.conversations.first)
        XCTAssertEqual(retry.conversations.count, 1)
        XCTAssertTrue(conversation.fullText.contains("Retry the deferred Codex body."))
        XCTAssertTrue(conversation.fullText.contains("The deferred Codex body was retried."))
    }

    func testCodexStateDatabaseDoesNotConsumeRolloutByteBudget() async throws {
        let root = try makeTemporaryDirectory("codex-enumeration-budget")
        defer { try? fileManager.removeItem(at: root) }

        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let rollout = codexRoot.appendingPathComponent("rollout-budget.jsonl")
        let rolloutFixture = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":101,"cached_input_tokens":1,"output_tokens":11},"model":"openai/gpt-5.2-codex"}}}
        """
        try write(rolloutFixture, to: rollout)
        let database = try createCodexThreadDatabase(at: codexRoot, rolloutPath: rollout.path)
        XCTAssertGreaterThan(
            Int64(try Data(contentsOf: database).count),
            1,
            "the enumeration index must exceed the deliberately tiny rollout budget"
        )

        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: 1)
        )
        let tracker = ParserFileDiscoveryTracker()
        let parser = CodexParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)
            ),
            homeDirectoryURL: root
        )
        let result = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            fileDiscoveryTracker: tracker,
            resourceGovernor: governor
        ))

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.cacheReadTokens, 1)
        XCTAssertEqual(usage.outputTokens, 11)
        XCTAssertEqual(
            governor.consumedBytes,
            Int64(rolloutFixture.utf8.count),
            "only rollout content belongs to the shared file-byte budget"
        )
        XCTAssertEqual(
            tracker.partialCheckpointFiles.map(\.path),
            [rollout.standardizedFileURL.path]
        )
    }

    func testCodexBudgetPrioritizesRecentlyUpdatedLongRunningParent() async throws {
        let root = try makeTemporaryDirectory("codex-updated-priority")
        defer { try? fileManager.removeItem(at: root) }

        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let activeRollout = codexRoot.appendingPathComponent("old-active.jsonl")
        let idleRollout = codexRoot.appendingPathComponent("new-idle.jsonl")
        try write(
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":100,"output_tokens":20}}}}"#,
            to: activeRollout
        )
        try write(
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90,"cached_input_tokens":10,"output_tokens":2}}}}"#,
            to: idleRollout
        )

        let database = try createCodexThreadDatabase(at: codexRoot, rolloutPath: activeRollout.path)
        let connection = try SQLiteConnection.openForWriting(creatingAt: database.path)
        try connection.execute(
            "UPDATE threads SET created_at = ?, updated_at = ? WHERE id = ?",
            arguments: [.int(100), .int(300), .text("codex-body-retry")]
        )
        try connection.execute(
            """
            INSERT INTO threads (
                id, title, model, model_provider, tokens_used,
                created_at, updated_at, cwd, rollout_path, thread_source, archived
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """,
            arguments: [
                .text("new-idle"),
                .text("Newer idle thread"),
                .text("gpt-5.6-sol"),
                .text("openai"),
                .int(102),
                .int(200),
                .int(201),
                .text("/tmp/BurnBar"),
                .text(idleRollout.path),
                .text("user")
            ]
        )
        connection.close()

        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: Int64(try Data(contentsOf: activeRollout).count))
        )
        let result = try await CodexParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)
            ),
            homeDirectoryURL: root
        ).parse(options: LogParseOptions(
            includeConversationBodies: false,
            resourceGovernor: governor
        ))

        XCTAssertEqual(result.usages.map(\.sessionId), ["codex-body-retry"])
        XCTAssertEqual(result.usages.first?.totalTokens, 920)
        XCTAssertEqual(governor.deferredFileCount, 1)
    }

    func testCodexParserExcludesSubagentMirrorsAndBucketsParentByDay() async throws {
        let root = try makeTemporaryDirectory("codex-subagent-accounting")
        defer { try? fileManager.removeItem(at: root) }

        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let rollout = codexRoot.appendingPathComponent("parent.jsonl")
        try write(
            """
            {"timestamp":"2026-07-20T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":40,"output_tokens":16}}}}
            """,
            to: rollout
        )
        let database = try createCodexThreadDatabase(at: codexRoot, rolloutPath: rollout.path)
        let connection = try SQLiteConnection.openForWriting(creatingAt: database.path)
        try connection.execute(
            """
            INSERT INTO threads (
                id, title, model, model_provider, tokens_used,
                created_at, updated_at, cwd, rollout_path, thread_source, archived
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """,
            arguments: [
                .text("codex-child"),
                .text("Codex child"),
                .text("gpt-5.6-sol"),
                .text("openai"),
                .int(176),
                .int(1_768_651_202),
                .int(1_768_651_203),
                .text("/tmp/BurnBar"),
                .text(rollout.path),
                .text("subagent")
            ]
        )
        connection.close()

        let parser = CodexParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)
            ),
            homeDirectoryURL: root
        )
        let result = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.usages.first?.totalTokens, 176)
        XCTAssertTrue(result.usages.first?.sessionId.hasPrefix("codex-body-retry#day-") == true)
        XCTAssertEqual(Set(result.usageSessionIDsToDelete), ["codex-body-retry", "codex-child"])
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

    func testHermesNewlyWatchedHistoricalDatabaseParsesRowsBeforeCutoff() async throws {
        let root = try makeTemporaryDirectory("hermes-new-historical-database")
        defer { try? fileManager.removeItem(at: root) }

        let database = root.appendingPathComponent("state.db")
        let connection = try SQLiteConnection.openForWriting(creatingAt: database.path)
        try connection.execute(
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                source TEXT,
                model TEXT,
                title TEXT,
                started_at REAL,
                ended_at REAL,
                input_tokens INTEGER,
                output_tokens INTEGER
            )
            """
        )
        let historicalDate = Date(timeIntervalSince1970: 1_600_000_000)
        try connection.execute(
            "INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                .text("restored-sqlite-session"),
                .text("hermes-cli"),
                .text("hermes-model"),
                .text("Recovered database session"),
                .double(historicalDate.timeIntervalSince1970),
                .double(historicalDate.addingTimeInterval(30).timeIntervalSince1970),
                .int(87),
                .int(13)
            ]
        )
        connection.close()
        try setModificationDate(historicalDate, for: [database])

        let result = try await HermesParser(fileManager: fileManager, hermesRootURL: root).parse(
            options: LogParseOptions(
                includeConversationBodies: false,
                minimumFileModificationDate: historicalDate.addingTimeInterval(60),
                fileDiscoveryTracker: ParserFileDiscoveryTracker(knownFiles: [])
            )
        )

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(usage.sessionId, "restored-sqlite-session")
        XCTAssertEqual(usage.model, "hermes-model")
        XCTAssertEqual(usage.inputTokens, 87)
        XCTAssertEqual(usage.outputTokens, 13)
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
        let readFailureParser = ClaudeCodeParser(
            fileManager: fileManager,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("read-failure-support", isDirectory: true)
            ),
            projectsDirectoryOverride: projectsRoot,
            openFileForReading: { url in
                guard url.standardizedFileURL != unreadable.standardizedFileURL else { return nil }
                return try? FileHandle(forReadingFrom: url)
            }
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

    private func createGooseSessionDatabase(
        at database: URL,
        sessionId: String,
        inputTokens: Int,
        outputTokens: Int
    ) throws {
        let connection = try SQLiteConnection.openForWriting(creatingAt: database.path)
        defer { connection.close() }
        try connection.execute(
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                working_dir TEXT,
                accumulated_input_tokens INTEGER,
                accumulated_output_tokens INTEGER,
                created_at TEXT,
                updated_at TEXT
            )
            """
        )
        try connection.execute(
            """
            INSERT INTO sessions (
                id, model, working_dir, accumulated_input_tokens,
                accumulated_output_tokens, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                .text(sessionId),
                .text("anthropic/claude-sonnet-4"),
                .text("/tmp/\(sessionId)"),
                .int(Int64(inputTokens)),
                .int(Int64(outputTokens)),
                .text("2026-07-19T10:00:00Z"),
                .text("2026-07-19T10:01:00Z")
            ]
        )
    }

    private func createCodexThreadDatabase(at codexRoot: URL, rolloutPath: String) throws -> URL {
        let database = codexRoot.appendingPathComponent("state_5.sqlite", isDirectory: false)
        let connection = try SQLiteConnection.openForWriting(creatingAt: database.path)
        defer { connection.close() }
        try connection.execute("""
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                title TEXT,
                model TEXT,
                model_provider TEXT,
                tokens_used INTEGER,
                created_at INTEGER,
                updated_at INTEGER,
                cwd TEXT,
                rollout_path TEXT,
                thread_source TEXT,
                archived INTEGER DEFAULT 0
            )
            """)
        try connection.execute(
            """
            INSERT INTO threads (
                id, title, model, model_provider, tokens_used,
                created_at, updated_at, cwd, rollout_path, archived
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """,
            arguments: [
                .text("codex-body-retry"),
                .text("Codex body retry"),
                .text("openai/gpt-5.2-codex"),
                .text("openai"),
                .int(176),
                .int(1_768_651_200),
                .int(1_768_651_201),
                .text("/tmp/BurnBar"),
                .text(rolloutPath)
            ]
        )
        return database
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
