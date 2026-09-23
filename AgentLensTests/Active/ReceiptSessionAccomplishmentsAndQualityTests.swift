import os
import XCTest
import GRDB
@testable import OpenBurnBarCore
@testable import OpenBurnBar
import OpenBurnBarData

// MARK: - Receipt Accomplishments & Quality Review Tests

final class ReceiptSessionAccomplishmentsAndQualityTests: XCTestCase {

    private func makeDatabaseQueue() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: dbQueue)
        try database.runMigrationsSafely()
        return dbQueue
    }

    @MainActor
    private func makeCloseMonitor(
        dataStore: DataStore,
        runtimeOpen: Bool = false,
        onReceiptPrinted: (@MainActor (ReceiptRecord) -> Void)? = nil
    ) -> CLISessionCloseMonitor {
        CLISessionCloseMonitor(
            dataStore: dataStore,
            settingsManager: .shared,
            runtimeProbe: FixedReceiptCLIRuntimeProbe(isOpen: runtimeOpen),
            onReceiptPrinted: onReceiptPrinted
        )
    }

    // MARK: - Accomplishment Synthesizer Tests

    func test_accomplishmentSynthesizer_derivesAchievements() {
        let synthesizer = ReceiptAccomplishmentSynthesizer()

        // 1. High speed, high cache, tests passing, commits
        let context1 = ReceiptAccomplishmentSynthesizer.SynthesisContext(
            projectName: "BurnBar",
            promptSummary: "Fix auth",
            filesTouched: ["Auth.swift"],
            toolsUsed: ["xcodebuild test", "write_to_file"],
            durationSeconds: 120,
            tokensPerSecond: 180,
            cacheHitPercentage: 88,
            totalCostUSD: 0.03,
            lastAssistantMessage: "All 12 unit tests passed."
        )
        let gitStats1 = ReceiptGitStats(
            insertions: 40,
            deletions: 5,
            filesChanged: 2,
            commitsCreated: 1
        )

        let badges1 = synthesizer.deriveAchievements(context: context1, gitStats: gitStats1)
        let badgeCodes1 = Set(badges1.map(\.code))

        XCTAssertTrue(badgeCodes1.contains("speed_demon"), "tokensPerSecond >= 150 triggers Speed Demon")
        XCTAssertTrue(badgeCodes1.contains("cache_beast"), "cacheHitPercentage >= 80 triggers Cache Beast")
        XCTAssertTrue(badgeCodes1.contains("tests_passing"), "Test tool usage triggers Tests Passing")
        XCTAssertTrue(badgeCodes1.contains("clean_commit"), "Commits created triggers Clean Commit")
        XCTAssertTrue(badgeCodes1.contains("frugal"), "Cost < $0.05 triggers Frugal")
        XCTAssertFalse(badgeCodes1.contains("marathon"), "Duration < 25m does not trigger Marathon")

        // 2. Marathon session
        let context2 = ReceiptAccomplishmentSynthesizer.SynthesisContext(
            projectName: "BurnBar",
            durationSeconds: 30 * 60,
            tokensPerSecond: 40,
            cacheHitPercentage: 20,
            totalCostUSD: 1.50
        )
        let badges2 = synthesizer.deriveAchievements(context: context2, gitStats: nil)
        let badgeCodes2 = Set(badges2.map(\.code))
        XCTAssertTrue(badgeCodes2.contains("marathon"), "Duration >= 25 min triggers Marathon")
    }

    func test_accomplishmentSynthesizer_deterministicFallback() {
        let synthesizer = ReceiptAccomplishmentSynthesizer()

        let gitStats = ReceiptGitStats(
            insertions: 50,
            deletions: 12,
            filesChanged: 3,
            commitsCreated: 2
        )

        let context = ReceiptAccomplishmentSynthesizer.SynthesisContext(
            projectName: "BurnBar",
            promptSummary: "Refactor database migrations",
            filesTouched: ["DB.swift", "Migration.swift"],
            toolsUsed: ["swift test"],
            lastAssistantMessage: "Successfully verified all database migrations and updated indexes."
        )

        let items = synthesizer.synthesizeDeterministic(context: context, gitStats: gitStats)

        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.contains(where: { $0.contains("Committed 2 changes") }))
        XCTAssertTrue(items.contains(where: { $0.contains("Modified 3 files") }))
        XCTAssertTrue(items.contains(where: { $0.contains("Executed automated test") }))
    }

    // MARK: - Quality Review & Rubric Auditor Tests

    func test_qualityAuditor_deterministicRubric() {
        let auditor = ReceiptQualityAuditor()

        let highRigorReceipt = ReceiptRecord(
            sessionId: "sess-rigor",
            projectName: "BurnBar",
            provider: .claudeCode,
            modelName: "claude-3-7-sonnet",
            harness: "Claude Code",
            durationSeconds: 180,
            inputTokens: 10_000,
            outputTokens: 2_000,
            cacheReadTokens: 12_000,
            totalCostUSD: 0.15,
            cacheHitPercentage: 85.0,
            tokensPerSecond: 130.0,
            promptSummary: "Implement robust thermal receipt popups",
            actualAccomplishments: ["Added ReceiptMiniFlyoutPopover", "Added ReceiptQualityAuditor"],
            achievements: [.speedDemon, .cacheBeast, .testsPassing, .cleanCommit],
            gitStats: ReceiptGitStats(insertions: 120, deletions: 10, filesChanged: 4, commitsCreated: 2),
            toolsUsed: ["swift test"]
        )

        let review = auditor.auditDeterministic(receipt: highRigorReceipt)

        XCTAssertGreaterThanOrEqual(review.score, 90.0, "High rigor and efficiency should score >= 90")
        XCTAssertTrue(["A+", "A"].contains(review.grade))
        XCTAssertGreaterThanOrEqual(review.goalScore, 85.0)
        XCTAssertGreaterThanOrEqual(review.rigorScore, 85.0)
        XCTAssertGreaterThanOrEqual(review.efficiencyScore, 80.0)
        XCTAssertFalse(review.wins.isEmpty)
        XCTAssertEqual(review.modelUsed, "heuristic-rubric")
    }

    func test_qualityAuditor_gradeThresholds() {
        XCTAssertEqual(ReceiptQualityAuditor.gradeForScore(96), "A+")
        XCTAssertEqual(ReceiptQualityAuditor.gradeForScore(91), "A")
        XCTAssertEqual(ReceiptQualityAuditor.gradeForScore(87), "A-")
        XCTAssertEqual(ReceiptQualityAuditor.gradeForScore(82), "B+")
        XCTAssertEqual(ReceiptQualityAuditor.gradeForScore(77), "B")
        XCTAssertEqual(ReceiptQualityAuditor.gradeForScore(72), "C")
        XCTAssertEqual(ReceiptQualityAuditor.gradeForScore(65), "D")
    }

    // MARK: - CLI Session Close Monitor Tests

    func test_fetchConversationsWithoutTranscripts_omitsOverflowBodies() async throws {
        let dbQueue = try makeDatabaseQueue()
        let store = ConversationStore(dbQueue: dbQueue)
        let blob = String(repeating: "transcript-body ", count: 4_000)
        try await store.upsertConversation(
            ConversationRecord(
                id: "conv-no-transcript",
                provider: .claudeCode,
                sessionId: "session-no-transcript",
                projectName: "BurnBar",
                startTime: Date(),
                endTime: nil,
                messageCount: 3,
                userWordCount: 10,
                assistantWordCount: 20,
                keyFiles: ["CLISessionCloseMonitor.swift"],
                keyCommands: [],
                keyTools: ["Edit"],
                inferredTaskTitle: "Keep burn live",
                lastAssistantMessage: blob,
                fullText: blob,
                workingDirectory: "/tmp",
                fileModifiedAt: Date(),
                summaryModel: "claude-opus"
            )
        )

        let metadata = try await store.fetchConversationsWithoutTranscripts(limit: 10)
        let recentOnly = try await store.fetchConversationsWithoutTranscripts(
            limit: 10,
            activeSince: Date().addingTimeInterval(-60)
        )
        let tooNew = try await store.fetchConversationsWithoutTranscripts(
            limit: 10,
            activeSince: Date().addingTimeInterval(60)
        )
        let full = try await store.fetchConversations(limit: 10)
        let row = try XCTUnwrap(metadata.first)
        XCTAssertEqual(row.sessionId, "session-no-transcript")
        XCTAssertEqual(row.messageCount, 3)
        XCTAssertTrue(row.fullText.isEmpty, "close-monitor poll must not decrypt transcript overflow pages")
        XCTAssertTrue(row.lastAssistantMessage.isEmpty)
        XCTAssertEqual(recentOnly.count, 1, "A session active in the last minute must survive the horizon filter")
        XCTAssertTrue(tooNew.isEmpty, "A future horizon must not pull yesterday's register")
        XCTAssertEqual(try XCTUnwrap(full.first).fullText, blob)

        let now = Date()
        try await store.upsertConversation(
            ConversationRecord(
                id: "conv-indexed-only",
                provider: .factory,
                sessionId: "factory-indexed-only",
                projectName: "BurnBar",
                startTime: nil,
                endTime: nil,
                messageCount: 2,
                userWordCount: 4,
                assistantWordCount: 8,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: "Indexer restamp",
                lastAssistantMessage: "",
                fullText: "",
                indexedAt: now,
                fileModifiedAt: nil
            )
        )
        let restamped = try await store.fetchConversationsWithoutTranscripts(
            limit: 10,
            activeSince: now.addingTimeInterval(-60)
        )
        XCTAssertFalse(
            restamped.contains(where: { $0.sessionId == "factory-indexed-only" }),
            "A rescan that only stamps indexedAt must not resurrect a session with no real activity"
        )

        let staleFile = now.addingTimeInterval(-8 * 60 * 60)
        let recentEnd = now.addingTimeInterval(-90)
        try await store.upsertConversation(
            ConversationRecord(
                id: "conv-stale-file-recent-end",
                provider: .factory,
                sessionId: "factory-stale-file",
                projectName: "BurnBar",
                startTime: staleFile,
                endTime: recentEnd,
                messageCount: 4,
                userWordCount: 8,
                assistantWordCount: 16,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: "Ended just now",
                lastAssistantMessage: "",
                fullText: "",
                fileModifiedAt: staleFile
            )
        )
        let byLatestActivity = try await store.fetchConversationsWithoutTranscripts(
            limit: 10,
            activeSince: now.addingTimeInterval(-60 * 60)
        )
        XCTAssertTrue(
            byLatestActivity.contains(where: { $0.sessionId == "factory-stale-file" }),
            "A recent endTime must beat a stale fileModifiedAt in the ingest horizon"
        )
    }

    func test_usageStore_fetchBySessionKeepsARowForEveryCandidate() async throws {
        let dbQueue = try makeDatabaseQueue()
        let store = UsageStore(dbQueue: dbQueue)
        let now = Date()
        for index in 0..<4 {
            try await store.insert(TokenUsage(
                provider: .factory,
                sessionId: "factory-old",
                projectName: "BurnBar",
                model: "droid",
                inputTokens: 10,
                outputTokens: 4,
                costUSD: 0.01,
                startTime: now.addingTimeInterval(TimeInterval(-400 + index)),
                endTime: now.addingTimeInterval(TimeInterval(-390 + index))
            ))
        }
        try await store.insert(TokenUsage(
            provider: .factory,
            sessionId: "factory-quiet",
            projectName: "BurnBar",
            model: "droid",
            inputTokens: 80,
            outputTokens: 20,
            costUSD: 0.40,
            startTime: now.addingTimeInterval(-90),
            endTime: now.addingTimeInterval(-30)
        ))

        let rows = try await store.fetchUsage(
            sessionIDs: ["factory-old", "factory-quiet"],
            limit: 2
        )
        let old = rows.filter { $0.sessionId == "factory-old" }
        let quiet = rows.filter { $0.sessionId == "factory-quiet" }
        XCTAssertEqual(old.count, 2, "Per-session cap must keep older chats, not drop them")
        XCTAssertEqual(quiet.count, 1)
        XCTAssertEqual(quiet.first?.inputTokens, 80)

        let allRows = try await store.fetchAllUsage(
            sessionIDs: ["factory-old", "factory-quiet"]
        )
        XCTAssertEqual(allRows.filter { $0.sessionId == "factory-old" }.count, 4)
        XCTAssertEqual(allRows.filter { $0.sessionId == "factory-quiet" }.count, 1)
    }

    func test_printedSessionIDs_failClosedOnLookupError() {
        struct LookupFailed: Error {}
        XCTAssertEqual(
            CLISessionCloseMonitor.printedSessionIDs(from: .success(["rcpt-1"])),
            ["rcpt-1"]
        )
        XCTAssertNil(
            CLISessionCloseMonitor.printedSessionIDs(from: .failure(LookupFailed())),
            "A failed printed-receipt lookup must abort ingest, not remint"
        )
    }

    func test_receiptLookupKeys_canonicalThenLegacyConversationIdentity() {
        XCTAssertEqual(
            CLISessionCloseMonitor.receiptLookupKeys(
                sessionID: "canonical-sid",
                conversationIdentity: "conv_legacy"
            ),
            ["canonical-sid", "conv_legacy"]
        )
        XCTAssertEqual(
            CLISessionCloseMonitor.receiptLookupKeys(
                sessionID: "same",
                conversationIdentity: "same"
            ),
            ["same"]
        )
    }

    @MainActor
    func test_cliSessionCloseMonitor_ingestsUsageOnlySessionByRecentEndTime() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let usageStore = UsageStore(dbQueue: dbQueue)
        let now = Date()
        try await usageStore.insert(TokenUsage(
            provider: .aider,
            sessionId: "aider-long-session",
            projectName: "BurnBar",
            model: "gpt-4o",
            inputTokens: 40,
            outputTokens: 12,
            costUSD: 0.08,
            startTime: now.addingTimeInterval(-8 * 60 * 60),
            endTime: now.addingTimeInterval(-20)
        ))

        let monitor = CLISessionCloseMonitor(dataStore: dataStore)
        monitor.quietPeriodSeconds = 60
        await monitor.checkClosedSessions(now: now)

        XCTAssertEqual(monitor.activeSessions.count, 1)
        let ingested = try XCTUnwrap(monitor.activeSessions["aider-long-session"])
        XCTAssertEqual(ingested.harness, "Aider")
        XCTAssertEqual(try XCTUnwrap(ingested.costUSD), 0.08, accuracy: 0.001)
    }

    @MainActor
    func test_cliSessionCloseMonitor_usageOnlyJoinLoadsEveryRowForTheSession() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let usageStore = UsageStore(dbQueue: dbQueue)
        let now = Date()
        try await usageStore.insert(TokenUsage(
            provider: .aider,
            sessionId: "aider-many-rows",
            projectName: "BurnBar",
            model: "gpt-4o",
            inputTokens: 10,
            outputTokens: 2,
            costUSD: 0.02,
            startTime: now.addingTimeInterval(-8 * 60 * 60),
            endTime: now.addingTimeInterval(-8 * 60 * 60 + 30)
        ))
        try await usageStore.insert(TokenUsage(
            provider: .aider,
            sessionId: "aider-many-rows",
            projectName: "BurnBar",
            model: "gpt-4o-mini",
            inputTokens: 40,
            outputTokens: 12,
            costUSD: 0.08,
            startTime: now.addingTimeInterval(-8 * 60 * 60),
            endTime: now.addingTimeInterval(-20)
        ))

        let monitor = CLISessionCloseMonitor(dataStore: dataStore)
        monitor.quietPeriodSeconds = 60
        await monitor.checkClosedSessions(now: now)

        let ingested = try XCTUnwrap(monitor.activeSessions["aider-many-rows"])
        XCTAssertEqual(try XCTUnwrap(ingested.costUSD), 0.10, accuracy: 0.001)
        XCTAssertEqual(ingested.inputTokens, 50)
    }

    @MainActor
    func test_cliSessionCloseMonitor_refreshesLegacyReceiptIdentityInsteadOfDuplicating() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        let conversation = factoryConversation(
            sessionId: "factory-canonical",
            start: now.addingTimeInterval(-90),
            fileModifiedAt: now.addingTimeInterval(-30),
            title: "Legacy keyed slip"
        )
        try await dataStore.upsertConversation(conversation)
        try await dataStore.insertReceipt(
            ReceiptRecord(
                id: "rcpt_\(conversation.id)",
                sessionId: conversation.id,
                projectName: "OpenBurnBar",
                provider: .factory,
                modelName: "unknown",
                harness: "Factory CLI",
                promptSummary: "Legacy keyed slip",
                isStarred: true
            )
        )

        var printedReceipt: ReceiptRecord?
        let probe = ToggleReceiptCLIRuntimeProbe(isOpen: true)
        let monitor = CLISessionCloseMonitor(
            dataStore: dataStore,
            settingsManager: .shared,
            runtimeProbe: probe,
            onReceiptPrinted: { receipt in
                printedReceipt = receipt
            }
        )
        monitor.quietPeriodSeconds = 60

        await monitor.checkClosedSessions(now: now.addingTimeInterval(35))
        XCTAssertNil(printedReceipt, "Still in the terminal — wait")
        XCTAssertEqual(monitor.activeSessions.count, 1)

        probe.isOpen = false
        await monitor.checkClosedSessions(now: now.addingTimeInterval(40))

        let canonical = try await dataStore.fetchReceiptForSession(sessionId: "factory-canonical")
        let legacy = try await dataStore.fetchReceiptForSession(sessionId: conversation.id)
        XCTAssertEqual(printedReceipt?.id, "rcpt_\(conversation.id)")
        XCTAssertEqual(printedReceipt?.isStarred, true)
        XCTAssertEqual(canonical?.id, "rcpt_\(conversation.id)")
        XCTAssertEqual(canonical?.isStarred, true)
        XCTAssertNil(legacy, "Refreshing must move the slip onto the canonical session id")
    }

    @MainActor
    func test_cliSessionCloseMonitor_ingestsFromRecentUsageWithoutConversationScan() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let usageStore = UsageStore(dbQueue: dbQueue)
        let now = Date()
        try await usageStore.insert(TokenUsage(
            provider: .codex,
            sessionId: "session-usage-only",
            projectName: "BurnBar",
            model: "gpt-5",
            inputTokens: 100,
            outputTokens: 40,
            costUSD: 0.5,
            startTime: now.addingTimeInterval(-30),
            endTime: now
        ))

        let monitor = CLISessionCloseMonitor(dataStore: dataStore)
        monitor.quietPeriodSeconds = 60
        await monitor.checkClosedSessions(now: now)

        XCTAssertEqual(monitor.activeSessions.count, 1)
        let ingestedSession = try XCTUnwrap(monitor.activeSessions["session-usage-only"])
        XCTAssertEqual(ingestedSession.harness, "Codex CLI")
        // Unwrap before the accuracy assert: the pinned Xcode 26 XCTest has no
        // Optional-friendly accuracy overload (local Xcode 27 silently accepted
        // the Double? operand — release run 35060876665 App Test Gate failed on it).
        XCTAssertEqual(try XCTUnwrap(ingestedSession.costUSD), 0.5, accuracy: 0.001)
    }

    @MainActor
    func test_cliSessionCloseMonitor_idleUsagePollDoesNotResetQuietPeriodClock() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        // Session last burned 30s ago; no conversation record exists, so the
        // monitor only ever sees it through the usage poll.
        try await dataStore.insert(TokenUsage(
            provider: .claudeCode,
            sessionId: "session-quiet-period",
            projectName: "BurnBar",
            model: "claude-3-7-sonnet",
            inputTokens: 80,
            outputTokens: 20,
            costUSD: 0.02,
            startTime: now.addingTimeInterval(-90),
            endTime: now.addingTimeInterval(-30)
        ))

        var printedReceipt: ReceiptRecord?
        let monitor = makeCloseMonitor(dataStore: dataStore) { receipt in
            printedReceipt = receipt
        }
        monitor.quietPeriodSeconds = 60

        // First poll discovers the session; activity is the persisted end
        // time, not the wall clock.
        await monitor.checkClosedSessions(now: now)
        XCTAssertEqual(monitor.activeSessions.count, 1)
        let trackedSession = try XCTUnwrap(monitor.activeSessions["session-quiet-period"])
        XCTAssertEqual(
            trackedSession.lastActiveAt.timeIntervalSince1970,
            now.addingTimeInterval(-30).timeIntervalSince1970,
            accuracy: 1.0
        )
        XCTAssertNil(printedReceipt, "The quiet period has not elapsed yet")

        // Second poll 35s later re-reads the SAME unchanged rows: it must
        // not treat itself as fresh activity, so the 60s quiet period since
        // the last persisted burn has elapsed and the receipt finalizes.
        await monitor.checkClosedSessions(now: now.addingTimeInterval(35))

        XCTAssertTrue(monitor.activeSessions.isEmpty, "An idle poll must not keep the session alive forever")
        XCTAssertEqual(printedReceipt?.sessionId, "session-quiet-period")
    }

    @MainActor
    func test_cliSessionCloseMonitor_harnessResolution() {
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .claudeCode), "Claude Code")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .codex), "Codex CLI")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .xAI), "Grok CLI")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .cursor), "Cursor")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .aider), "Aider")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .factory), "Factory CLI")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .hermes), "Hermes")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .geminiCLI), "Gemini CLI")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .goose), "Goose")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .antigravity), "Antigravity")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .muse), "Muse")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .openClaude), "OpenClaude")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .primeAgent), "Prime Agent")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .zai), "Z.ai")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .openClaw), "OpenClaw")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .junie), "Junie")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .ollama), "Ollama")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .copilot), "Copilot")
        XCTAssertNotEqual(
            CLISessionCloseMonitor.resolveHarnessName(for: .geminiCLI),
            "Gemini CLI CLI"
        )
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .windsurf), "Windsurf CLI")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .devin), "Devin CLI")
        XCTAssertFalse(
            CLISessionCloseMonitor.resolveHarnessName(for: .geminiCLI).contains("CLI CLI")
        )
    }

    func test_conversationHasRealEnd_ignoresPlaceholderEndEqualToStart() {
        let start = Date()
        let placeholder = ConversationRecord(
            id: "conv-placeholder",
            provider: .factory,
            sessionId: "factory-1",
            projectName: "tmp",
            startTime: start,
            endTime: start,
            messageCount: 4,
            userWordCount: 10,
            assistantWordCount: 20,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Factory worker",
            lastAssistantMessage: "",
            fullText: "",
            fileModifiedAt: start
        )
        XCTAssertFalse(CLISessionCloseMonitor.conversationHasRealEnd(placeholder))

        let ended = ConversationRecord(
            id: "conv-ended",
            provider: .factory,
            sessionId: "factory-2",
            projectName: "tmp",
            startTime: start,
            endTime: start.addingTimeInterval(30),
            messageCount: 4,
            userWordCount: 10,
            assistantWordCount: 20,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Factory worker",
            lastAssistantMessage: "",
            fullText: "",
            fileModifiedAt: start.addingTimeInterval(30)
        )
        XCTAssertTrue(CLISessionCloseMonitor.conversationHasRealEnd(ended))

        let windsurf = ConversationRecord(
            id: "conv-windsurf",
            provider: .windsurf,
            sessionId: "windsurf-1",
            projectName: "tmp",
            startTime: start,
            endTime: start.addingTimeInterval(3_600),
            messageCount: 8,
            userWordCount: 20,
            assistantWordCount: 40,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Still in the IDE",
            lastAssistantMessage: "",
            fullText: "",
            fileModifiedAt: start.addingTimeInterval(3_600)
        )
        XCTAssertFalse(
            CLISessionCloseMonitor.conversationHasRealEnd(windsurf),
            "Windsurf file mtime is not an explicit close"
        )

        let windsurfClosed = ConversationRecord(
            id: "conv-windsurf-closed",
            provider: .windsurf,
            sessionId: "windsurf-2",
            projectName: "tmp",
            startTime: start,
            endTime: start.addingTimeInterval(3_600),
            messageCount: 8,
            userWordCount: 20,
            assistantWordCount: 40,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Closed in the index",
            lastAssistantMessage: "",
            fullText: "",
            fileModifiedAt: start.addingTimeInterval(90)
        )
        XCTAssertTrue(
            CLISessionCloseMonitor.conversationHasRealEnd(windsurfClosed),
            "A terminal endTime distinct from file mtime is a real close"
        )
    }

    @MainActor
    func test_cliSessionCloseMonitor_printsFactoryConversationWithoutUsage() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        let conv = ConversationRecord(
            id: ConversationRecord.stableId(provider: .factory, sessionId: "factory-live-1"),
            provider: .factory,
            sessionId: "factory-live-1",
            projectName: "OpenBurnBar",
            startTime: now.addingTimeInterval(-90),
            endTime: now.addingTimeInterval(-90),
            messageCount: 6,
            userWordCount: 40,
            assistantWordCount: 80,
            keyFiles: ["ReceiptStore.swift"],
            keyCommands: [],
            keyTools: ["Read"],
            inferredTaskTitle: "Wire Factory receipt notifications",
            lastAssistantMessage: "",
            fullText: "",
            workingDirectory: "/private/tmp",
            fileModifiedAt: now.addingTimeInterval(-30),
            summary: "Factory finished the receipts notify path."
        )
        try await dataStore.upsertConversation(conv)

        var printedReceipt: ReceiptRecord?
        let monitor = makeCloseMonitor(dataStore: dataStore) { receipt in
            printedReceipt = receipt
        }
        monitor.quietPeriodSeconds = 60

        await monitor.checkClosedSessions(now: now)
        XCTAssertEqual(monitor.activeSessions.count, 1)
        XCTAssertEqual(monitor.activeSessions["factory-live-1"]?.harness, "Factory CLI")
        XCTAssertNil(printedReceipt, "Placeholder endTime == startTime must wait for the quiet period")

        await monitor.checkClosedSessions(now: now.addingTimeInterval(35))
        XCTAssertEqual(printedReceipt?.sessionId, "factory-live-1")
        XCTAssertEqual(printedReceipt?.harness, "Factory CLI")
        XCTAssertEqual(printedReceipt?.promptSummary, "Factory finished the receipts notify path.")
    }

    @MainActor
    func test_cliSessionCloseMonitor_mintsAndAnnouncesGrokCursorAndClaude() async throws {
        let cases: [(AgentProvider, String, String)] = [
            (.xAI, "grok-live-1", "Grok CLI"),
            (.cursor, "cursor-live-1", "Cursor"),
            (.claudeCode, "claude-live-1", "Claude Code"),
            (.geminiCLI, "gemini-live-1", "Gemini CLI"),
            (.aider, "aider-live-1", "Aider"),
            (.goose, "goose-live-1", "Goose"),
            (.openCode, "opencode-live-1", "OpenCode"),
            (.hermes, "hermes-live-1", "Hermes"),
            (.piAgent, "pi-live-1", "Pi"),
            (.muse, "muse-live-1", "Muse"),
            (.openClaude, "openclaude-live-1", "OpenClaude"),
            (.kimi, "kimi-live-1", "Kimi CLI"),
            (.minimax, "minimax-live-1", "MiniMax CLI"),
            (.zai, "zai-live-1", "Z.ai"),
            (.openClaw, "openclaw-live-1", "OpenClaw"),
            (.junie, "junie-live-1", "Junie"),
            (.ollama, "ollama-live-1", "Ollama"),
            (.forgeDev, "forge-live-1", "Forge"),
            (.omp, "omp-live-1", "OMP"),
            (.copilot, "copilot-live-1", "Copilot"),
            (.primeAgent, "prime-live-1", "Prime Agent"),
            (.antigravity, "antigravity-live-1", "Antigravity")
        ]
        for (provider, sessionId, harness) in cases {
            let dbQueue = try makeDatabaseQueue()
            let dataStore = try DataStore(databaseQueue: dbQueue)
            let now = Date()
            try await dataStore.upsertConversation(
                ConversationRecord(
                    id: ConversationRecord.stableId(provider: provider, sessionId: sessionId),
                    provider: provider,
                    sessionId: sessionId,
                    projectName: "OpenBurnBar",
                    startTime: now.addingTimeInterval(-90),
                    endTime: now.addingTimeInterval(-90),
                    messageCount: 5,
                    userWordCount: 20,
                    assistantWordCount: 40,
                    keyFiles: ["ReceiptChatBridge.swift"],
                    keyCommands: [],
                    keyTools: ["Read"],
                    inferredTaskTitle: "\(harness) receipts path",
                    lastAssistantMessage: "",
                    fullText: "",
                    workingDirectory: "/private/tmp",
                    fileModifiedAt: now.addingTimeInterval(-30),
                    summary: "\(harness) finished the receipts notify path."
                )
            )

            var printedReceipt: ReceiptRecord?
            let probe = ToggleReceiptCLIRuntimeProbe(isOpen: true)
            let monitor = CLISessionCloseMonitor(
                dataStore: dataStore,
                settingsManager: .shared,
                runtimeProbe: probe,
                onReceiptPrinted: { receipt in
                    printedReceipt = receipt
                }
            )
            monitor.quietPeriodSeconds = 60

            await monitor.checkClosedSessions(now: now.addingTimeInterval(35))
            XCTAssertNil(printedReceipt, "\(harness) must wait for the runtime to close")
            let quietSlip = try await dataStore.fetchReceiptForSession(sessionId: sessionId)
            XCTAssertNotNil(quietSlip, "\(harness) still prints the slip on quiet")

            probe.isOpen = false
            await monitor.checkClosedSessions(now: now.addingTimeInterval(40))
            XCTAssertEqual(printedReceipt?.sessionId, sessionId)
            XCTAssertEqual(printedReceipt?.harness, harness)
            XCTAssertTrue(monitor.activeSessions.isEmpty)
        }
    }

    @MainActor
    func test_cliSessionCloseMonitor_doesNotAnnounceStaleSessions() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        let conv = ConversationRecord(
            id: "conv-stale-factory",
            provider: .factory,
            sessionId: "factory-stale-1",
            projectName: "OpenBurnBar",
            startTime: now.addingTimeInterval(-4 * 60 * 60),
            endTime: now.addingTimeInterval(-3 * 60 * 60),
            messageCount: 8,
            userWordCount: 40,
            assistantWordCount: 80,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Old factory run",
            lastAssistantMessage: "",
            fullText: "",
            fileModifiedAt: now.addingTimeInterval(-3 * 60 * 60)
        )
        try await dataStore.upsertConversation(conv)

        var printedReceipt: ReceiptRecord?
        let monitor = makeCloseMonitor(dataStore: dataStore) { receipt in
            printedReceipt = receipt
        }
        monitor.quietPeriodSeconds = 60
        await monitor.checkClosedSessions(now: now)

        XCTAssertNil(printedReceipt, "A session that finished hours ago must not pop a flyout")
        let saved = try await dataStore.fetchReceiptForSession(sessionId: "factory-stale-1")
        XCTAssertNotNil(saved, "The slip is still persisted so the register stays complete")
    }

    @MainActor
    func test_cliSessionCloseMonitor_quietPeriodDoesNotAnnounceWhileRuntimeOpen() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        try await dataStore.upsertConversation(
            factoryConversation(
                sessionId: "factory-runtime-open-1",
                start: now.addingTimeInterval(-90),
                fileModifiedAt: now.addingTimeInterval(-30),
                title: "Still thinking in the terminal"
            )
        )

        var printedReceipt: ReceiptRecord?
        let monitor = makeCloseMonitor(dataStore: dataStore, runtimeOpen: true) { receipt in
            printedReceipt = receipt
        }
        monitor.quietPeriodSeconds = 60

        await monitor.checkClosedSessions(now: now)
        await monitor.checkClosedSessions(now: now.addingTimeInterval(35))

        XCTAssertNil(printedReceipt, "A quiet pause while the CLI is still running must not notify")
        XCTAssertEqual(monitor.activeSessions.count, 1, "Keep watching until the terminal actually closes")
        let saved = try await dataStore.fetchReceiptForSession(sessionId: "factory-runtime-open-1")
        XCTAssertNotNil(saved, "Quiet time still prints the slip so the register stays complete")
    }

    @MainActor
    func test_cliSessionCloseMonitor_doesNotAnnounceIfRuntimeReopensBeforeFlyout() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        try await dataStore.upsertConversation(
            factoryConversation(
                sessionId: "factory-reopen-1",
                start: now.addingTimeInterval(-90),
                fileModifiedAt: now.addingTimeInterval(-30),
                title: "Relaunched while the slip was printing"
            )
        )

        var printedReceipt: ReceiptRecord?
        // First snapshot (after ingest) looks closed. Persist / git
        // probes then take time; the pre-announce snapshot sees the
        // relaunched CLI and must hold the flyout.
        let probe = SequenceSnapshotReceiptCLIRuntimeProbe(snapshots: [false, true])
        let monitor = CLISessionCloseMonitor(
            dataStore: dataStore,
            settingsManager: .shared,
            runtimeProbe: probe,
            onReceiptPrinted: { receipt in
                printedReceipt = receipt
            }
        )
        monitor.quietPeriodSeconds = 60
        await monitor.checkClosedSessions(now: now)

        XCTAssertNil(printedReceipt, "A relaunched CLI must not get a flyout from a stale snapshot")
        XCTAssertEqual(monitor.activeSessions.count, 1)
        let saved = try await dataStore.fetchReceiptForSession(sessionId: "factory-reopen-1")
        XCTAssertNotNil(saved, "The slip still prints; only announce waits")
    }

    @MainActor
    func test_cliSessionCloseMonitor_announcesExistingSlipWhenRuntimeCloses() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        try await dataStore.upsertConversation(
            factoryConversation(
                sessionId: "factory-deferred-1",
                start: now.addingTimeInterval(-90),
                fileModifiedAt: now.addingTimeInterval(-30),
                title: "Close the terminal to announce"
            )
        )

        var printedReceipt: ReceiptRecord?
        let probe = ToggleReceiptCLIRuntimeProbe(isOpen: true)
        let monitor = CLISessionCloseMonitor(
            dataStore: dataStore,
            settingsManager: .shared,
            runtimeProbe: probe,
            onReceiptPrinted: { receipt in
                printedReceipt = receipt
            }
        )
        monitor.quietPeriodSeconds = 60

        await monitor.checkClosedSessions(now: now.addingTimeInterval(35))
        XCTAssertNil(printedReceipt)
        let deferredSlip = try await dataStore.fetchReceiptForSession(sessionId: "factory-deferred-1")
        XCTAssertNotNil(deferredSlip)

        probe.isOpen = false
        await monitor.checkClosedSessions(now: now.addingTimeInterval(40))

        XCTAssertEqual(printedReceipt?.sessionId, "factory-deferred-1")
        XCTAssertTrue(monitor.activeSessions.isEmpty)
    }

    @MainActor
    func test_cliSessionCloseMonitor_explicitEndDoesNotAnnounceWhileRuntimeOpen() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        let conv = ConversationRecord(
            id: ConversationRecord.stableId(provider: .codex, sessionId: "codex-still-thinking"),
            provider: .codex,
            sessionId: "codex-still-thinking",
            projectName: "OpenBurnBar",
            startTime: now.addingTimeInterval(-120),
            endTime: now.addingTimeInterval(-5),
            messageCount: 4,
            userWordCount: 20,
            assistantWordCount: 80,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Codex last-event endTime is not a close",
            lastAssistantMessage: "",
            fullText: "",
            workingDirectory: "/private/tmp",
            fileModifiedAt: now.addingTimeInterval(-5)
        )
        try await dataStore.upsertConversation(conv)

        var printedReceipt: ReceiptRecord?
        let monitor = makeCloseMonitor(dataStore: dataStore, runtimeOpen: true) { receipt in
            printedReceipt = receipt
        }
        await monitor.checkClosedSessions(now: now)

        XCTAssertNil(printedReceipt, "Codex stamping endTime from the last event must not notify while the process is up")
        let thinkingSlip = try await dataStore.fetchReceiptForSession(sessionId: "codex-still-thinking")
        XCTAssertNotNil(thinkingSlip)
        XCTAssertEqual(monitor.activeSessions.count, 1)
    }

    @MainActor
    func test_cliSessionCloseMonitor_doesNotReplayAlreadyPrintedSlipWhenRuntimeAlreadyClosed() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        try await dataStore.upsertConversation(
            factoryConversation(
                sessionId: "factory-already-printed",
                start: now.addingTimeInterval(-90),
                fileModifiedAt: now.addingTimeInterval(-30),
                title: "Already printed before launch"
            )
        )
        try await dataStore.insertReceipt(
            ReceiptRecord(
                id: "rcpt_factory-already-printed",
                sessionId: "factory-already-printed",
                projectName: "OpenBurnBar",
                provider: .factory,
                modelName: "unknown",
                harness: "Factory CLI",
                promptSummary: "Already printed before launch"
            )
        )

        var printedReceipt: ReceiptRecord?
        let monitor = makeCloseMonitor(dataStore: dataStore, runtimeOpen: false) { receipt in
            printedReceipt = receipt
        }
        monitor.quietPeriodSeconds = 60
        await monitor.checkClosedSessions(now: now.addingTimeInterval(35))

        XCTAssertNil(printedReceipt, "Relaunch must not replay a slip that is already in the register")
        XCTAssertTrue(monitor.activeSessions.isEmpty)
    }

    @MainActor
    func test_cliSessionCloseMonitor_preexistingSlipAnnouncesWhenRuntimeLaterCloses() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        try await dataStore.upsertConversation(
            factoryConversation(
                sessionId: "factory-preexisting-open",
                start: now.addingTimeInterval(-90),
                fileModifiedAt: now.addingTimeInterval(-30),
                title: "Printed during a pause, terminal still open"
            )
        )
        try await dataStore.insertReceipt(
            ReceiptRecord(
                id: "rcpt_factory-preexisting-open",
                sessionId: "factory-preexisting-open",
                projectName: "OpenBurnBar",
                provider: .factory,
                modelName: "unknown",
                harness: "Factory CLI",
                promptSummary: "Printed during a pause, terminal still open"
            )
        )

        var printedReceipt: ReceiptRecord?
        let probe = ToggleReceiptCLIRuntimeProbe(isOpen: true)
        let monitor = CLISessionCloseMonitor(
            dataStore: dataStore,
            settingsManager: .shared,
            runtimeProbe: probe,
            onReceiptPrinted: { receipt in
                printedReceipt = receipt
            }
        )
        monitor.quietPeriodSeconds = 60

        await monitor.checkClosedSessions(now: now.addingTimeInterval(35))
        XCTAssertNil(printedReceipt, "Still in the terminal — wait")
        XCTAssertEqual(monitor.activeSessions.count, 1)

        probe.isOpen = false
        await monitor.checkClosedSessions(now: now.addingTimeInterval(40))
        XCTAssertEqual(printedReceipt?.sessionId, "factory-preexisting-open")
        XCTAssertTrue(monitor.activeSessions.isEmpty)
    }

    @MainActor
    func test_cliSessionCloseMonitor_historicalSiblingDoesNotReplayOnLaterClose() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        try await dataStore.upsertConversation(
            factoryConversation(
                sessionId: "factory-old-printed",
                start: now.addingTimeInterval(-4 * 60 * 60),
                fileModifiedAt: now.addingTimeInterval(-3 * 60 * 60),
                title: "Yesterday's printed slip"
            )
        )
        try await dataStore.insertReceipt(
            ReceiptRecord(
                id: "rcpt_factory-old-printed",
                sessionId: "factory-old-printed",
                projectName: "OpenBurnBar",
                provider: .factory,
                modelName: "unknown",
                harness: "Factory CLI",
                promptSummary: "Yesterday's printed slip"
            )
        )
        try await dataStore.upsertConversation(
            factoryConversation(
                sessionId: "factory-live-printed",
                start: now.addingTimeInterval(-90),
                fileModifiedAt: now.addingTimeInterval(-30),
                title: "The session still in the terminal"
            )
        )
        try await dataStore.insertReceipt(
            ReceiptRecord(
                id: "rcpt_factory-live-printed",
                sessionId: "factory-live-printed",
                projectName: "OpenBurnBar",
                provider: .factory,
                modelName: "unknown",
                harness: "Factory CLI",
                promptSummary: "The session still in the terminal"
            )
        )

        var printed: [String] = []
        let probe = ToggleReceiptCLIRuntimeProbe(isOpen: true)
        let monitor = CLISessionCloseMonitor(
            dataStore: dataStore,
            settingsManager: .shared,
            runtimeProbe: probe,
            onReceiptPrinted: { receipt in
                printed.append(receipt.sessionId)
            }
        )
        monitor.quietPeriodSeconds = 60

        await monitor.checkClosedSessions(now: now.addingTimeInterval(35))
        XCTAssertTrue(printed.isEmpty, "Still in the terminal — wait")

        probe.isOpen = false
        await monitor.checkClosedSessions(now: now.addingTimeInterval(40))
        XCTAssertEqual(printed, ["factory-live-printed"])
    }

    func test_processReceiptCLIRuntimeProbe_ignoresCursorAppAndHelpers() async {
        XCTAssertNil(ProcessReceiptCLIRuntimeProbe.provider(forProcessLine: "/Applications/Cursor.app/Contents/MacOS/Cursor"))
        XCTAssertNil(ProcessReceiptCLIRuntimeProbe.provider(forProcessLine: "/usr/libexec/openburnbar-helper"))
        XCTAssertNil(ProcessReceiptCLIRuntimeProbe.provider(forProcessLine: "codex-daemon --serve"))
        XCTAssertEqual(
            ProcessReceiptCLIRuntimeProbe.provider(forProcessLine: "/opt/homebrew/bin/cursor-agent --workspace /tmp"),
            .cursor
        )
        XCTAssertEqual(
            ProcessReceiptCLIRuntimeProbe.provider(
                forProcessLine: "/Applications/Cursor.app/Contents/Resources/app/bin/cursor-agent --workspace /tmp"
            ),
            .cursor,
            "Bundled cursor-agent must count as open"
        )
        XCTAssertEqual(
            ProcessReceiptCLIRuntimeProbe.provider(forProcessLine: "/opt/homebrew/bin/codex exec"),
            .codex
        )
        XCTAssertEqual(
            ProcessReceiptCLIRuntimeProbe.provider(forProcessLine: "claude --dangerously-skip-permissions"),
            .claudeCode
        )
        XCTAssertEqual(
            ProcessReceiptCLIRuntimeProbe.provider(forProcessLine: "/usr/local/bin/droid run"),
            .factory
        )
        XCTAssertEqual(
            ProcessReceiptCLIRuntimeProbe.provider(forProcessLine: "grok --prompt ship"),
            .xAI
        )

        let probe = ProcessReceiptCLIRuntimeProbe(
            processLines: { ["/opt/homebrew/bin/codex exec"] },
            runningBundleIDs: { ["com.todesktop.230313mzl4w4u92"] }
        )
        let codexOpen = await probe.isSessionRuntimeOpen(provider: .codex, projectPath: nil)
        let factoryClosed = await probe.isSessionRuntimeOpen(provider: .factory, projectPath: nil)
        let cursorClosed = await probe.isSessionRuntimeOpen(provider: .cursorAgent, projectPath: nil)
        XCTAssertTrue(codexOpen)
        XCTAssertFalse(factoryClosed)
        XCTAssertFalse(cursorClosed)

        let bundledCursorAgent = ProcessReceiptCLIRuntimeProbe(
            processLines: {
                ["/Applications/Cursor.app/Contents/Resources/app/bin/cursor-agent --workspace /tmp"]
            },
            runningBundleIDs: { ["com.todesktop.230313mzl4w4u92"] }
        )
        let bundledOpen = await bundledCursorAgent.isSessionRuntimeOpen(provider: .cursor, projectPath: nil)
        XCTAssertTrue(bundledOpen, "cursor-agent inside Cursor.app must hold announce")

        let cursorAgent = ProcessReceiptCLIRuntimeProbe(
            processLines: { ["/opt/homebrew/bin/cursor-agent --workspace /tmp"] },
            runningBundleIDs: { [] }
        )
        let cursorAgentOpen = await cursorAgent.isSessionRuntimeOpen(provider: .cursorAgent, projectPath: nil)
        let cursorFamilyOpen = await cursorAgent.isSessionRuntimeOpen(provider: .cursor, projectPath: nil)
        let cursorIsNotCodex = await cursorAgent.isSessionRuntimeOpen(provider: .codex, projectPath: nil)
        XCTAssertTrue(cursorAgentOpen)
        XCTAssertTrue(cursorFamilyOpen, "A session stored as .cursor still waits for cursor-agent to exit")
        XCTAssertFalse(cursorIsNotCodex)

        let factoryApp = ProcessReceiptCLIRuntimeProbe(
            processLines: { [] },
            runningBundleIDs: { ["com.factory.app"] }
        )
        let factoryAppOpen = await factoryApp.isSessionRuntimeOpen(provider: .factory, projectPath: nil)
        let factoryIsNotCodex = await factoryApp.isSessionRuntimeOpen(provider: .codex, projectPath: nil)
        XCTAssertTrue(factoryAppOpen)
        XCTAssertFalse(factoryIsNotCodex)

        let cursorIDE = ProcessReceiptCLIRuntimeProbe(
            processLines: { [] },
            runningBundleIDs: { ["com.todesktop.230313mzl4w4u92"] }
        )
        let cursorIDEOpen = await cursorIDE.isSessionRuntimeOpen(provider: .cursor, projectPath: nil)
        XCTAssertFalse(cursorIDEOpen, "Cursor.app must not mute Cursor receipts")
    }

    @MainActor
    func test_cliSessionCloseMonitor_longThinkStillAnnouncesAfterRelaunch() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        try await dataStore.upsertConversation(
            factoryConversation(
                sessionId: "factory-long-think",
                start: now.addingTimeInterval(-40 * 60),
                fileModifiedAt: now.addingTimeInterval(-25 * 60),
                title: "Long think across a BurnBar relaunch"
            )
        )
        try await dataStore.insertReceipt(
            ReceiptRecord(
                id: "rcpt_factory-long-think",
                sessionId: "factory-long-think",
                projectName: "OpenBurnBar",
                provider: .factory,
                modelName: "unknown",
                harness: "Factory CLI",
                promptSummary: "Long think across a BurnBar relaunch"
            )
        )

        var printedReceipt: ReceiptRecord?
        let probe = ToggleReceiptCLIRuntimeProbe(isOpen: true)
        let monitor = CLISessionCloseMonitor(
            dataStore: dataStore,
            settingsManager: .shared,
            runtimeProbe: probe,
            onReceiptPrinted: { receipt in
                printedReceipt = receipt
            }
        )
        monitor.quietPeriodSeconds = 60

        await monitor.checkClosedSessions(now: now)
        XCTAssertNil(printedReceipt, "Still thinking — do not replay on launch")
        XCTAssertEqual(monitor.activeSessions.count, 1, "A 25-minute think must keep waiting after relaunch")

        probe.isOpen = false
        await monitor.checkClosedSessions(now: now.addingTimeInterval(5))
        XCTAssertEqual(printedReceipt?.sessionId, "factory-long-think")
        XCTAssertTrue(monitor.activeSessions.isEmpty)
    }

    @MainActor
    func test_cliSessionCloseMonitor_firstMintLongThinkStillAnnouncesWhenRuntimeCloses() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        try await dataStore.upsertConversation(
            factoryConversation(
                sessionId: "factory-first-mint-think",
                start: now.addingTimeInterval(-40 * 60),
                fileModifiedAt: now.addingTimeInterval(-25 * 60),
                title: "First mint during a 25-minute think"
            )
        )

        var printedReceipt: ReceiptRecord?
        let probe = ToggleReceiptCLIRuntimeProbe(isOpen: true)
        let monitor = CLISessionCloseMonitor(
            dataStore: dataStore,
            settingsManager: .shared,
            runtimeProbe: probe,
            onReceiptPrinted: { receipt in
                printedReceipt = receipt
            }
        )
        monitor.quietPeriodSeconds = 60

        await monitor.checkClosedSessions(now: now)
        XCTAssertNil(printedReceipt, "Still thinking — do not announce a first mint outside the live window")
        let firstMintSlip = try await dataStore.fetchReceiptForSession(sessionId: "factory-first-mint-think")
        XCTAssertNotNil(firstMintSlip, "Quiet time still prints the slip")
        XCTAssertEqual(monitor.activeSessions.count, 1)

        probe.isOpen = false
        await monitor.checkClosedSessions(now: now.addingTimeInterval(5))
        XCTAssertEqual(printedReceipt?.sessionId, "factory-first-mint-think")
        XCTAssertTrue(monitor.activeSessions.isEmpty)
    }

    @MainActor
    func test_cliSessionCloseMonitor_unobservableHarnessDoesNotAnnounceOnQuiet() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let now = Date()
        let start = now.addingTimeInterval(-90)
        try await dataStore.upsertConversation(
            ConversationRecord(
                id: ConversationRecord.stableId(provider: .windsurf, sessionId: "windsurf-quiet-1"),
                provider: .windsurf,
                sessionId: "windsurf-quiet-1",
                projectName: "OpenBurnBar",
                startTime: start,
                endTime: start,
                messageCount: 6,
                userWordCount: 20,
                assistantWordCount: 40,
                keyFiles: ["ReceiptChatBridge.swift"],
                keyCommands: [],
                keyTools: ["Read"],
                inferredTaskTitle: "Windsurf receipts path",
                lastAssistantMessage: "",
                fullText: "",
                workingDirectory: "/private/tmp",
                fileModifiedAt: now.addingTimeInterval(-30),
                summary: "Windsurf finished a turn."
            )
        )

        var printedReceipt: ReceiptRecord?
        let monitor = makeCloseMonitor(dataStore: dataStore, runtimeOpen: false) { receipt in
            printedReceipt = receipt
        }
        monitor.quietPeriodSeconds = 60

        await monitor.checkClosedSessions(now: now.addingTimeInterval(35))
        XCTAssertNil(printedReceipt, "No CLI we can see — quiet is not a close")
        let windsurfSlip = try await dataStore.fetchReceiptForSession(sessionId: "windsurf-quiet-1")
        XCTAssertNotNil(windsurfSlip, "The slip still prints on quiet")
        XCTAssertEqual(monitor.activeSessions.count, 1)

        try await dataStore.upsertConversation(
            ConversationRecord(
                id: ConversationRecord.stableId(provider: .windsurf, sessionId: "windsurf-quiet-1"),
                provider: .windsurf,
                sessionId: "windsurf-quiet-1",
                projectName: "OpenBurnBar",
                startTime: start,
                endTime: now,
                messageCount: 6,
                userWordCount: 20,
                assistantWordCount: 40,
                keyFiles: ["ReceiptChatBridge.swift"],
                keyCommands: [],
                keyTools: ["Read"],
                inferredTaskTitle: "Windsurf receipts path",
                lastAssistantMessage: "",
                fullText: "",
                workingDirectory: "/private/tmp",
                fileModifiedAt: now,
                summary: "Windsurf finished a turn."
            )
        )

        await monitor.checkClosedSessions(now: now.addingTimeInterval(40))
        XCTAssertNil(
            printedReceipt,
            "Windsurf file mtime stamped as endTime is not a close"
        )
        XCTAssertEqual(monitor.activeSessions.count, 1)

        try await dataStore.upsertConversation(
            ConversationRecord(
                id: ConversationRecord.stableId(provider: .windsurf, sessionId: "windsurf-quiet-1"),
                provider: .windsurf,
                sessionId: "windsurf-quiet-1",
                projectName: "OpenBurnBar",
                startTime: start,
                endTime: now.addingTimeInterval(45),
                messageCount: 6,
                userWordCount: 20,
                assistantWordCount: 40,
                keyFiles: ["ReceiptChatBridge.swift"],
                keyCommands: [],
                keyTools: ["Read"],
                inferredTaskTitle: "Windsurf receipts path",
                lastAssistantMessage: "",
                fullText: "",
                workingDirectory: "/private/tmp",
                fileModifiedAt: now.addingTimeInterval(-30),
                summary: "Windsurf finished a turn."
            )
        )

        await monitor.checkClosedSessions(now: now.addingTimeInterval(50))
        XCTAssertEqual(printedReceipt?.sessionId, "windsurf-quiet-1")
        XCTAssertEqual(printedReceipt?.harness, "Windsurf CLI")
        XCTAssertTrue(monitor.activeSessions.isEmpty)
    }

    @MainActor
    func test_cliSessionCloseMonitor_recordsActivityAndCloses() async throws {
        let dbQueue = try makeDatabaseQueue()
        let store = ReceiptStore(dbQueue: dbQueue)
        let dataStore = try DataStore(databaseQueue: dbQueue)

        var printedReceipt: ReceiptRecord?
        let monitor = makeCloseMonitor(dataStore: dataStore) { receipt in
            printedReceipt = receipt
        }
        monitor.quietPeriodSeconds = 1.0 // short quiet period for test

        let conv = ConversationRecord(
            id: "conv-101",
            provider: .claudeCode,
            sessionId: "session-101",
            projectName: "ReceiptEngine",
            startTime: Date().addingTimeInterval(-10),
            endTime: nil,
            messageCount: 4,
            userWordCount: 50,
            assistantWordCount: 200,
            keyFiles: ["ReceiptStore.swift"],
            keyCommands: ["swift build"],
            keyTools: ["Edit", "Run"],
            inferredTaskTitle: "Ship bespoke receipt notification",
            lastAssistantMessage: "All tasks completed.",
            fullText: "User asked for receipts. Agent implemented them.",
            workingDirectory: "/tmp",
            fileModifiedAt: Date(),
            summaryModel: "claude-3-7-sonnet"
        )

        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-101",
            projectName: "ReceiptEngine",
            model: "claude-3-7-sonnet",
            inputTokens: 2000,
            outputTokens: 800,
            costUSD: 0.12,
            startTime: Date().addingTimeInterval(-10),
            endTime: Date()
        )

        monitor.recordActivity(conversation: conv, usages: [usage], hasExplicitEnd: false)

        XCTAssertEqual(monitor.activeSessions.count, 1)
        XCTAssertEqual(monitor.activeSessions["session-101"]?.harness, "Claude Code")

        // Trigger close check with advance in time >= quietPeriodSeconds
        let future = Date().addingTimeInterval(5.0)
        await monitor.checkClosedSessions(now: future)

        XCTAssertEqual(monitor.activeSessions.count, 0, "Session should have transitioned from active to closed")
        XCTAssertNotNil(printedReceipt, "Receipt print callback should fire on close")
        XCTAssertEqual(printedReceipt?.projectName, "ReceiptEngine")
        XCTAssertEqual(printedReceipt?.harness, "Claude Code")
        XCTAssertEqual(printedReceipt?.totalCostUSD, 0.12)
    }

    @MainActor
    func test_recordActivity_usesConversationIdWhenSessionIdIsEmpty() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)
        let monitor = makeCloseMonitor(dataStore: dataStore)
        monitor.quietPeriodSeconds = 60

        let first = ConversationRecord(
            id: "conv-empty-sid-1",
            provider: .factory,
            sessionId: "",
            projectName: "OpenBurnBar",
            startTime: Date().addingTimeInterval(-120),
            endTime: nil,
            messageCount: 3,
            userWordCount: 10,
            assistantWordCount: 20,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "First empty-sid chat",
            lastAssistantMessage: "",
            fullText: "",
            workingDirectory: "/tmp/one",
            fileModifiedAt: Date()
        )
        let second = ConversationRecord(
            id: "conv-empty-sid-2",
            provider: .claudeCode,
            sessionId: "   ",
            projectName: "OpenBurnBar",
            startTime: Date().addingTimeInterval(-90),
            endTime: nil,
            messageCount: 5,
            userWordCount: 12,
            assistantWordCount: 24,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Second empty-sid chat",
            lastAssistantMessage: "",
            fullText: "",
            workingDirectory: "/tmp/two",
            fileModifiedAt: Date()
        )

        monitor.recordActivity(conversation: first)
        monitor.recordActivity(conversation: second)

        XCTAssertEqual(Set(monitor.activeSessions.keys), ["conv-empty-sid-1", "conv-empty-sid-2"])
        XCTAssertEqual(monitor.activeSessions["conv-empty-sid-1"]?.harness, "Factory CLI")
        XCTAssertEqual(monitor.activeSessions["conv-empty-sid-2"]?.harness, "Claude Code")
    }

    // MARK: - Store V66 Roundtrip Tests

    func test_receiptStore_v66Roundtrip() async throws {
        let dbQueue = try makeDatabaseQueue()
        let store = ReceiptStore(dbQueue: dbQueue)

        let quality = ReceiptQualityReview(
            grade: "A+",
            score: 96.0,
            goalScore: 98.0,
            rigorScore: 95.0,
            efficiencyScore: 95.0,
            wins: ["Zero warnings", "All tests green"],
            critiques: ["Slight cache miss at start"],
            reviewedAt: Date(),
            modelUsed: "claude-3.5-haiku"
        )

        let git = ReceiptGitStats(
            insertions: 85,
            deletions: 12,
            filesChanged: 3,
            commitsCreated: 1
        )

        let receipt = ReceiptRecord(
            id: "rcpt-v66-test",
            sessionId: "sess-v66",
            projectName: "OpenBurnBar",
            provider: .claudeCode,
            modelName: "claude-3-7-sonnet",
            harness: "Claude Code CLI",
            timestamp: Date(),
            durationSeconds: 45.0,
            inputTokens: 12000,
            outputTokens: 1500,
            cacheReadTokens: 10000,
            cacheWriteTokens: 2000,
            totalCostUSD: 0.28,
            estimatedCacheSavingsUSD: 0.09,
            cacheHitPercentage: 83.3,
            tokensPerSecond: 112.0,
            promptSummary: "Add receipt quality auditing",
            actualAccomplishments: ["Created ReceiptQualityAuditor", "Added migration V66"],
            qualityReview: quality,
            achievements: [.speedDemon, .testsPassing],
            gitStats: git,
            filesTouched: ["ReceiptStore.swift"],
            toolsUsed: ["write_to_file", "run_command"],
            gitBranch: "feat/receipts",
            gitCommit: "abc1234",
            isStarred: true
        )

        try await store.insert(receipt: receipt)

        let fetched = try await store.fetchReceipt(id: "rcpt-v66-test")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.harness, "Claude Code CLI")
        XCTAssertEqual(fetched?.actualAccomplishments.count, 2)
        XCTAssertEqual(fetched?.actualAccomplishments.first, "Created ReceiptQualityAuditor")
        XCTAssertEqual(fetched?.qualityReview?.grade, "A+")
        XCTAssertEqual(fetched?.qualityReview?.score, 96.0)
        XCTAssertEqual(fetched?.qualityReview?.wins.count, 2)
        XCTAssertEqual(fetched?.achievements.count, 2)
        XCTAssertEqual(fetched?.achievements.first?.code, "speed_demon")
        XCTAssertEqual(fetched?.gitStats?.commitsCreated, 1)
        XCTAssertEqual(fetched?.gitStats?.filesChanged, 3)

        // Test on-demand quality review update
        let updatedQuality = ReceiptQualityReview(
            grade: "A",
            score: 92.0,
            goalScore: 95.0,
            rigorScore: 90.0,
            efficiencyScore: 91.0,
            wins: ["Fast execution"],
            critiques: [],
            reviewedAt: Date(),
            modelUsed: "on-demand-rubric"
        )
        try await store.updateQualityReview(receiptId: "rcpt-v66-test", review: updatedQuality)

        let refetched = try await store.fetchReceipt(id: "rcpt-v66-test")
        XCTAssertEqual(refetched?.qualityReview?.grade, "A")
        XCTAssertEqual(refetched?.qualityReview?.score, 92.0)
        XCTAssertEqual(refetched?.qualityReview?.modelUsed, "on-demand-rubric")
    }

    // MARK: - Markdown Export Tests

    @MainActor
    func test_receiptExportService_includesNewSections() {
        let quality = ReceiptQualityReview(
            grade: "A+",
            score: 95.0,
            goalScore: 95.0,
            rigorScore: 95.0,
            efficiencyScore: 95.0,
            wins: ["Clean diff"],
            critiques: [],
            reviewedAt: Date(),
            modelUsed: "rubric"
        )

        let git = ReceiptGitStats(
            insertions: 50,
            deletions: 10,
            filesChanged: 2,
            commitsCreated: 1
        )

        let receipt = ReceiptRecord(
            id: "rcpt-export-test",
            sessionId: "sess-exp",
            projectName: "ReceiptExport",
            provider: .codex,
            modelName: "gpt-5",
            harness: "Codex CLI",
            totalCostUSD: 0.18,
            promptSummary: "Export verified receipt",
            actualAccomplishments: ["Verified markdown output"],
            qualityReview: quality,
            achievements: [.cleanCommit, .testsPassing],
            gitStats: git
        )

        let overlay = ReceiptConversationOverlay(
            conversationID: "conv-exp",
            sessionID: "sess-exp",
            inferredTaskTitle: "Export verified receipt",
            summary: "The slip markdown carries the chat join.",
            summaryTitle: nil,
            workingDirectory: "/tmp/receipts",
            messageCount: 4,
            keyFiles: []
        )
        let markdown = ReceiptExportService.makeMarkdown(for: receipt, overlay: overlay)

        XCTAssertTrue(markdown.contains("Codex CLI"))
        XCTAssertTrue(markdown.contains("**Chat:** The slip markdown carries the chat join."))
        XCTAssertTrue(markdown.contains("openburnbar://receipts/rcpt-export-test"))
        XCTAssertTrue(markdown.contains("openburnbar://sessions/conv-exp"))
        XCTAssertTrue(markdown.contains("Actually Accomplished"))
        XCTAssertTrue(markdown.contains("Verified markdown output"))
        XCTAssertTrue(markdown.contains("Quality Review"))
        XCTAssertTrue(markdown.contains("Grade A+"))
        XCTAssertTrue(markdown.contains("Badges Earned"))
        XCTAssertTrue(markdown.contains("Committed"))
        XCTAssertTrue(markdown.contains("Git Deliverables"))
        XCTAssertFalse(markdown.contains("Session completed successfully"))
    }

    @MainActor
    func test_receiptExportService_omitsGenericAccomplishments() {
        let receipt = ReceiptRecord(
            sessionId: "sess-generic",
            projectName: "OpenBurnBar",
            provider: .codex,
            modelName: "gpt-5.6-sol",
            actualAccomplishments: ["Session completed successfully"]
        )
        let markdown = ReceiptExportService.makeMarkdown(for: receipt)
        XCTAssertFalse(markdown.contains("Session completed successfully"))
        XCTAssertFalse(markdown.contains("Actually Accomplished"))
    }

    // MARK: - Auto-Ingestion & Markdown Fence Tests

    @MainActor
    func test_cliSessionCloseMonitor_autoIngestsFromDataStore() async throws {
        let dbQueue = try makeDatabaseQueue()
        let dataStore = try DataStore(databaseQueue: dbQueue)

        let conv = ConversationRecord(
            id: "conv-auto-1",
            provider: .claudeCode,
            sessionId: "session-auto-1",
            projectName: "AutoIngestProject",
            startTime: Date().addingTimeInterval(-20),
            endTime: Date().addingTimeInterval(-10),
            messageCount: 3,
            userWordCount: 40,
            assistantWordCount: 150,
            keyFiles: ["Test.swift"],
            keyCommands: ["swift test"],
            keyTools: ["write_to_file"],
            inferredTaskTitle: "Auto-ingestion test task",
            lastAssistantMessage: "Auto ingest complete.",
            fullText: "Ingested conversation",
            workingDirectory: "/tmp",
            fileModifiedAt: Date().addingTimeInterval(-10),
            summaryModel: "claude-3-7-sonnet"
        )
        try await dataStore.upsertConversation(conv)

        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-auto-1",
            projectName: "AutoIngestProject",
            model: "claude-3-7-sonnet",
            inputTokens: 1500,
            outputTokens: 400,
            costUSD: 0.08,
            startTime: Date().addingTimeInterval(-20),
            endTime: Date().addingTimeInterval(-10)
        )
        try await dataStore.insert(usage)

        var printedReceipt: ReceiptRecord?
        let monitor = makeCloseMonitor(dataStore: dataStore) { receipt in
            printedReceipt = receipt
        }

        // Run checkClosedSessions - this should auto-ingest and immediately close since endTime != nil
        await monitor.checkClosedSessions(now: Date())

        XCTAssertNotNil(printedReceipt, "Auto-ingested session with ended time should produce a printed receipt")
        XCTAssertEqual(printedReceipt?.sessionId, "session-auto-1")
        XCTAssertEqual(printedReceipt?.projectName, "AutoIngestProject")
        XCTAssertEqual(printedReceipt?.harness, "Claude Code")
        XCTAssertEqual(printedReceipt?.totalCostUSD, 0.08)

        // Conversation evidence must survive the usage-driven ingestion path:
        // prompt, files, and tools come from the metadata-only conversation
        // fetch, not just from the usage rows.
        XCTAssertEqual(printedReceipt?.promptSummary, "Auto-ingestion test task")
        XCTAssertEqual(printedReceipt?.filesTouched, ["Test.swift"])
        XCTAssertEqual(printedReceipt?.toolsUsed, ["write_to_file"])

        // Verify receipt is persisted in DataStore
        let saved = try await dataStore.fetchReceipt(id: "rcpt_session-auto-1")
        XCTAssertNotNil(saved, "Receipt should be persisted in DataStore")
    }

    func test_receiptAchievements_haveValidIcons() {
        let achievements = ReceiptAchievement.allPredefined
        XCTAssertFalse(achievements.isEmpty)

        for achievement in achievements {
            XCTAssertFalse(achievement.code.isEmpty, "Code must not be empty")
            XCTAssertFalse(achievement.title.isEmpty, "Title must not be empty")
            XCTAssertFalse(achievement.icon.isEmpty, "Icon must not be empty")
            XCTAssertFalse(achievement.detail.isEmpty, "Detail must not be empty")

            let image = NSImage(systemSymbolName: achievement.icon, accessibilityDescription: nil)
            XCTAssertNotNil(image, "Icon '\(achievement.icon)' for badge '\(achievement.title)' must be a valid SF Symbol")
        }
    }

    func test_accomplishmentSynthesizer_stripsMarkdownFences() {
        let rawWithFence = """
        ```json
        {
          "accomplishments": [
            "Fixed database migration concurrency",
            "Added 4 new test suites"
          ]
        }
        ```
        """
        let cleaned = ReceiptAccomplishmentSynthesizer.cleanJSONResponse(rawWithFence)
        XCTAssertFalse(cleaned.hasPrefix("```"))
        XCTAssertFalse(cleaned.hasSuffix("```"))
        XCTAssertTrue(cleaned.contains("\"accomplishments\""))

        let rawGenericFence = """
        ```
        {"accomplishments": ["Item A"]}
        ```
        """
        let cleanedGeneric = ReceiptAccomplishmentSynthesizer.cleanJSONResponse(rawGenericFence)
        XCTAssertEqual(cleanedGeneric, "{\"accomplishments\": [\"Item A\"]}")
    }

    func test_qualityAuditor_stripsMarkdownFences() {
        let rawWithFence = """
        ```json
        {
          "goalScore": 95,
          "rigorScore": 90,
          "efficiencyScore": 92,
          "wins": ["Fast turn"],
          "critiques": []
        }
        ```
        """
        let cleaned = ReceiptQualityAuditor.cleanJSONResponse(rawWithFence)
        XCTAssertFalse(cleaned.hasPrefix("```"))
        XCTAssertFalse(cleaned.hasSuffix("```"))
        XCTAssertTrue(cleaned.contains("\"goalScore\": 95"))
    }

    private func factoryConversation(
        sessionId: String,
        start: Date,
        fileModifiedAt: Date,
        title: String
    ) -> ConversationRecord {
        ConversationRecord(
            id: ConversationRecord.stableId(provider: .factory, sessionId: sessionId),
            provider: .factory,
            sessionId: sessionId,
            projectName: "OpenBurnBar",
            startTime: start,
            endTime: start,
            messageCount: 6,
            userWordCount: 40,
            assistantWordCount: 80,
            keyFiles: ["ReceiptStore.swift"],
            keyCommands: [],
            keyTools: ["Read"],
            inferredTaskTitle: title,
            lastAssistantMessage: "",
            fullText: "",
            workingDirectory: "/private/tmp",
            fileModifiedAt: fileModifiedAt,
            summary: title
        )
    }
}

/// Each `snapshotForPoll` freezes the next answer. A live
/// `isSessionRuntimeOpen` without a snapshot fails open so tests have
/// to go through the poll snapshot.
private final class SequenceSnapshotReceiptCLIRuntimeProbe: ReceiptCLIRuntimeProbe, Sendable {
    private let snapshots: OSAllocatedUnfairLock<[Bool]>

    init(snapshots: [Bool]) {
        self.snapshots = OSAllocatedUnfairLock(initialState: snapshots)
    }

    func isSessionRuntimeOpen(provider _: AgentProvider, projectPath _: String?) async -> Bool {
        true
    }

    func snapshotForPoll() async -> any ReceiptCLIRuntimeProbe {
        let frozen = snapshots.withLock { queue -> Bool in
            guard !queue.isEmpty else { return true }
            return queue.removeFirst()
        }
        return FixedReceiptCLIRuntimeProbe(isOpen: frozen)
    }
}

private final class ToggleReceiptCLIRuntimeProbe: ReceiptCLIRuntimeProbe, Sendable {
    private let state: OSAllocatedUnfairLock<Bool>

    var isOpen: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    init(isOpen: Bool) {
        state = OSAllocatedUnfairLock(initialState: isOpen)
    }

    func isSessionRuntimeOpen(provider: AgentProvider, projectPath: String?) async -> Bool {
        isOpen
    }
}
