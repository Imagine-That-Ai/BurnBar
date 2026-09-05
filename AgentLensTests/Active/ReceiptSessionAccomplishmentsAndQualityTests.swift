import XCTest
import GRDB
@testable import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Receipt Accomplishments & Quality Review Tests

final class ReceiptSessionAccomplishmentsAndQualityTests: XCTestCase {

    private func makeDatabaseQueue() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: dbQueue)
        try database.runMigrationsSafely()
        return dbQueue
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

    @MainActor
    func test_cliSessionCloseMonitor_harnessResolution() {
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .claudeCode), "Claude Code")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .codex), "Codex CLI")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .xAI), "Grok CLI")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .cursor), "Cursor")
        XCTAssertEqual(CLISessionCloseMonitor.resolveHarnessName(for: .aider), "Aider")
    }

    @MainActor
    func test_cliSessionCloseMonitor_recordsActivityAndCloses() async throws {
        let dbQueue = try makeDatabaseQueue()
        let store = ReceiptStore(dbQueue: dbQueue)
        let dataStore = try DataStore(databaseQueue: dbQueue)

        var printedReceipt: ReceiptRecord?
        let monitor = CLISessionCloseMonitor(
            dataStore: dataStore,
            settingsManager: .shared,
            onReceiptPrinted: { receipt in
                printedReceipt = receipt
            }
        )
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

        let markdown = ReceiptExportService.makeMarkdown(for: receipt)

        XCTAssertTrue(markdown.contains("Codex CLI"))
        XCTAssertTrue(markdown.contains("Actually Accomplished"))
        XCTAssertTrue(markdown.contains("Verified markdown output"))
        XCTAssertTrue(markdown.contains("Quality Review"))
        XCTAssertTrue(markdown.contains("Grade A+"))
        XCTAssertTrue(markdown.contains("Badges Earned"))
        XCTAssertTrue(markdown.contains("Committed"))
        XCTAssertTrue(markdown.contains("Git Deliverables"))
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
        let monitor = CLISessionCloseMonitor(
            dataStore: dataStore,
            settingsManager: .shared,
            onReceiptPrinted: { receipt in
                printedReceipt = receipt
            }
        )

        // Run checkClosedSessions - this should auto-ingest and immediately close since endTime != nil
        await monitor.checkClosedSessions(now: Date())

        XCTAssertNotNil(printedReceipt, "Auto-ingested session with ended time should produce a printed receipt")
        XCTAssertEqual(printedReceipt?.sessionId, "session-auto-1")
        XCTAssertEqual(printedReceipt?.projectName, "AutoIngestProject")
        XCTAssertEqual(printedReceipt?.harness, "Claude Code")
        XCTAssertEqual(printedReceipt?.totalCostUSD, 0.08)

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
}
