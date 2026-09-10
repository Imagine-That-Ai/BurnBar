import XCTest
import GRDB
@testable import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - ReceiptStore Tests

final class ReceiptStoreTests: XCTestCase {

    private func makeDatabaseQueue() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: dbQueue)
        try database.runMigrationsSafely()
        return dbQueue
    }

    // MARK: - Model & Signature Tests

    func test_receiptRecord_computesDeterministicSignature() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let r1 = ReceiptRecord(
            sessionId: "sess-1",
            projectName: "BurnBar",
            provider: .claudeCode,
            modelName: "claude-3-7-sonnet",
            timestamp: date,
            inputTokens: 1000,
            outputTokens: 500,
            totalCostUSD: 0.42
        )

        let r2 = ReceiptRecord(
            sessionId: "sess-1",
            projectName: "BurnBar",
            provider: .claudeCode,
            modelName: "claude-3-7-sonnet",
            timestamp: date,
            inputTokens: 1000,
            outputTokens: 500,
            totalCostUSD: 0.42
        )

        XCTAssertEqual(r1.contentSignature, r2.contentSignature)
        XCTAssertEqual(r1.shortSignature.count, 8)
        XCTAssertEqual(r1.formattedCost, "$0.42")
    }

    // MARK: - Filter Power Query Token Parsing

    /// Every lower-bound spend prefix. `spend:>=` and `cost:>=` are the ordering
    /// fences: if a longer prefix ever lost to a shorter one, `spend:>=1.50`
    /// would match the `spend:>` arm, `Double("=1.50")` would be nil, and the
    /// token would silently fall through to free-text search with the suite
    /// still green.
    func test_receiptFilter_parsesEveryMinimumSpendPrefix() {
        for prefix in ["spend:>=", "spend:>", "cost:>=", "cost:>"] {
            let (cleaned, mods) = ReceiptFilter.parseSmartQuery("\(prefix)$5.00")
            XCTAssertEqual(mods.minSpend, 5.00, "\(prefix) did not set minSpend")
            XCTAssertNil(mods.maxSpend, "\(prefix) must not set maxSpend")
            XCTAssertEqual(cleaned, "", "\(prefix) leaked into the free-text query")
        }
    }

    /// Every upper-bound spend prefix, same ordering fence.
    func test_receiptFilter_parsesEveryMaximumSpendPrefix() {
        for prefix in ["spend:<=", "spend:<", "cost:<=", "cost:<"] {
            let (cleaned, mods) = ReceiptFilter.parseSmartQuery("\(prefix)$20.00")
            XCTAssertEqual(mods.maxSpend, 20.00, "\(prefix) did not set maxSpend")
            XCTAssertNil(mods.minSpend, "\(prefix) must not set minSpend")
            XCTAssertEqual(cleaned, "", "\(prefix) leaked into the free-text query")
        }
    }

    func test_receiptFilter_parsesEveryCacheThresholdPrefix() {
        for prefix in ["cache:>=", "cache:>"] {
            let (cleaned, mods) = ReceiptFilter.parseSmartQuery("\(prefix)80%")
            XCTAssertEqual(mods.minCache, 80.0, "\(prefix) did not set minCache")
            XCTAssertEqual(cleaned, "", "\(prefix) leaked into the free-text query")
        }
    }

    /// `cost:>` is six characters. The old parser used a hardcoded `dropFirst(7)`,
    /// so `cost:>5.00` parsed as `00` — a $0.00 floor that matched everything.
    func test_receiptFilter_takesOffsetsFromThePrefixNotAFixedCount() {
        let (cleaned, mods) = ReceiptFilter.parseSmartQuery("fix bug cost:>$5.00 cost:<=$20.00")
        XCTAssertEqual(cleaned, "fix bug")
        XCTAssertEqual(mods.minSpend, 5.00)
        XCTAssertEqual(mods.maxSpend, 20.00)
    }

    func test_receiptFilter_parsesModelAndProjectPrefixes() {
        let (cleaned, mods) = ReceiptFilter.parseSmartQuery("refactor model:claude-3-7-sonnet project:AgentLens")
        XCTAssertEqual(cleaned, "refactor")
        XCTAssertEqual(mods.model, "claude-3-7-sonnet")
        XCTAssertEqual(mods.project, "AgentLens")
    }

    func test_receiptFilter_parsesEveryStarAlias() {
        for alias in ["is:starred", "starred:true", "has:star"] {
            let (cleaned, mods) = ReceiptFilter.parseSmartQuery("audit \(alias)")
            XCTAssertEqual(mods.starred, Optional(true), "\(alias) did not set starred")
            XCTAssertEqual(cleaned, "audit")
        }
    }

    func test_receiptFilter_parsesAMixedQuery() {
        let (cleaned, mods) = ReceiptFilter.parseSmartQuery("refactor auth spend:>1.50 model:sonnet cache:>80% is:starred")
        XCTAssertEqual(cleaned, "refactor auth")
        XCTAssertEqual(mods.minSpend, 1.50)
        XCTAssertEqual(mods.model, "sonnet")
        XCTAssertEqual(mods.minCache, 80.0)
        XCTAssertEqual(mods.starred, Optional(true))
    }

    /// A token that cannot be parsed stays free text. An empty value in
    /// particular must never become a filter: `model:` used to yield `""`, which
    /// becomes `modelName LIKE '%%'` downstream and matches every row.
    func test_receiptFilter_leavesEmptyAndUnknownTokensAsFreeText() {
        let empties = ["spend:>", "spend:>=", "cost:<", "cache:>", "model:", "project:"]
        for token in empties {
            let (cleaned, mods) = ReceiptFilter.parseSmartQuery(token)
            XCTAssertEqual(cleaned, token, "\(token) was swallowed instead of searched")
            XCTAssertNil(mods.minSpend, "\(token) set minSpend")
            XCTAssertNil(mods.maxSpend, "\(token) set maxSpend")
            XCTAssertNil(mods.minCache, "\(token) set minCache")
            XCTAssertNil(mods.model, "\(token) set model")
            XCTAssertNil(mods.project, "\(token) set project")
            XCTAssertNil(mods.starred, "\(token) set starred")
        }

        // Unknown prefixes, unknown star aliases, and non-numeric values alike.
        for token in ["vibe:>3", "spend:!=2", "is:pinned", "cost:>abc"] {
            let (cleaned, mods) = ReceiptFilter.parseSmartQuery("triage \(token)")
            XCTAssertEqual(cleaned, "triage \(token)", "\(token) was swallowed instead of searched")
            XCTAssertNil(mods.minSpend, "\(token) set minSpend")
            XCTAssertNil(mods.maxSpend, "\(token) set maxSpend")
            XCTAssertNil(mods.starred, "\(token) set starred")
        }
    }

    // MARK: - CRUD & Starring

    func test_receiptStore_insertAndFetch() async throws {
        let dbQueue = try makeDatabaseQueue()
        let store = ReceiptStore(dbQueue: dbQueue)

        let receipt = ReceiptRecord(
            id: "rcpt-001",
            sessionId: "session-abc",
            projectName: "BurnBar",
            provider: .claudeCode,
            modelName: "claude-3-7-sonnet",
            timestamp: Date(),
            durationSeconds: 14.5,
            inputTokens: 5000,
            outputTokens: 1200,
            cacheReadTokens: 4000,
            cacheWriteTokens: 1000,
            totalCostUSD: 0.35,
            estimatedCacheSavingsUSD: 0.12,
            cacheHitPercentage: 80.0,
            tokensPerSecond: 77.2,
            promptSummary: "Add beautiful custom receipts to OpenBurnBar",
            filesTouched: ["ReceiptStore.swift", "ReceiptCardView.swift"],
            toolsUsed: ["write_to_file", "view_file"],
            isStarred: false
        )

        try await store.insert(receipt: receipt)

        let fetched = try await store.fetchReceipt(id: "rcpt-001")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.sessionId, "session-abc")
        XCTAssertEqual(fetched?.projectName, "BurnBar")
        XCTAssertEqual(fetched?.totalCostUSD, 0.35)
        XCTAssertEqual(fetched?.filesTouched.count, 2)
        XCTAssertEqual(fetched?.toolsUsed.count, 2)
        XCTAssertEqual(fetched?.isStarred, false)

        // Test Star toggle
        try await store.setStarred(receiptId: "rcpt-001", isStarred: true)
        let starredFetched = try await store.fetchReceipt(id: "rcpt-001")
        XCTAssertEqual(starredFetched?.isStarred, true)
    }

    // MARK: - SQLite FTS5 Search & Ranking

    func test_receiptStore_ftsSearch() async throws {
        let dbQueue = try makeDatabaseQueue()
        let store = ReceiptStore(dbQueue: dbQueue)

        let r1 = ReceiptRecord(
            id: "rcpt-1",
            sessionId: "s-1",
            projectName: "BurnBar",
            provider: .claudeCode,
            modelName: "claude-3-7-sonnet",
            promptSummary: "Fix SQLCipher encryption key migration issue",
            filesTouched: ["OpenBurnBarDatabase.swift"]
        )

        let r2 = ReceiptRecord(
            id: "rcpt-2",
            sessionId: "s-2",
            projectName: "Mercury",
            provider: .codex,
            modelName: "gpt-4o",
            promptSummary: "Implement real-time audio voice pipeline",
            filesTouched: ["MercuryAudio.swift"]
        )

        try await store.insert(receipt: r1)
        try await store.insert(receipt: r2)

        // Search for "SQLCipher"
        let filter1 = ReceiptFilter(searchQuery: "SQLCipher")
        let results1 = try await store.fetchReceipts(filter: filter1)
        XCTAssertEqual(results1.count, 1)
        XCTAssertEqual(results1.first?.id, "rcpt-1")

        // Search for "MercuryAudio.swift" (file search)
        let filter2 = ReceiptFilter(searchQuery: "MercuryAudio")
        let results2 = try await store.fetchReceipts(filter: filter2)
        XCTAssertEqual(results2.count, 1)
        XCTAssertEqual(results2.first?.id, "rcpt-2")
    }

    // MARK: - Aggregate Calculations

    func test_receiptStore_aggregateSummary() async throws {
        let dbQueue = try makeDatabaseQueue()
        let store = ReceiptStore(dbQueue: dbQueue)

        let r1 = ReceiptRecord(
            id: "rcpt-1",
            sessionId: "s-1",
            projectName: "BurnBar",
            provider: .claudeCode,
            modelName: "claude-3-7-sonnet",
            inputTokens: 10_000,
            outputTokens: 2_000,
            totalCostUSD: 1.50,
            estimatedCacheSavingsUSD: 0.50,
            cacheHitPercentage: 80.0
        )

        let r2 = ReceiptRecord(
            id: "rcpt-2",
            sessionId: "s-2",
            projectName: "BurnBar",
            provider: .codex,
            modelName: "gpt-4o",
            inputTokens: 5_000,
            outputTokens: 1_000,
            totalCostUSD: 0.50,
            estimatedCacheSavingsUSD: 0.20,
            cacheHitPercentage: 60.0
        )

        try await store.insert(receipt: r1)
        try await store.insert(receipt: r2)

        let summary = try await store.calculateAggregateSummary(filter: ReceiptFilter())
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.totalCostUSD, 2.00, accuracy: 0.001)
        XCTAssertEqual(summary.totalTokens, 18_000)
        XCTAssertEqual(summary.totalCacheSavingsUSD, 0.70, accuracy: 0.001)
        XCTAssertEqual(summary.averageCacheHitPercentage, 70.0, accuracy: 0.001)
    }

    // MARK: - Markdown & JSON Exporter

    @MainActor
    func test_receiptExportService_formatsMarkdownAndJSON() {
        let receipt = ReceiptRecord(
            id: "rcpt-export-1",
            sessionId: "sess-999",
            projectName: "BurnBar",
            provider: .claudeCode,
            modelName: "claude-3-7-sonnet",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 12.0,
            inputTokens: 8000,
            outputTokens: 1500,
            cacheReadTokens: 6000,
            cacheWriteTokens: 1000,
            totalCostUSD: 0.48,
            estimatedCacheSavingsUSD: 0.18,
            cacheHitPercentage: 75.0,
            tokensPerSecond: 87.5,
            promptSummary: "Export test receipt",
            filesTouched: ["Export.swift"],
            toolsUsed: ["write_to_file"],
            gitBranch: "feature/receipts",
            gitCommit: "abcdef123456"
        )

        let md = ReceiptExportService.makeMarkdown(for: receipt)
        XCTAssertTrue(md.contains("OpenBurnBar Receipt: `BurnBar`"))
        XCTAssertTrue(md.contains("claude-3-7-sonnet"))
        XCTAssertTrue(md.contains("$0.48"))
        XCTAssertTrue(md.contains("feature/receipts"))
        XCTAssertTrue(md.contains("Export.swift"))

        let json = ReceiptExportService.makeJSON(for: receipt)
        XCTAssertTrue(json.contains("\"sessionId\" : \"sess-999\""))
        XCTAssertTrue(json.contains("\"totalCostUSD\" : 0.48"))
    }
}

// MARK: - Slip Inspector State

/// `ReceiptDetailCardView` carries no `.id(receipt.id)`, so one view instance
/// sees successive receipts and these two value types carry the whole
/// "what resets, what survives" contract.
final class ReceiptInspectorStateTests: XCTestCase {

    private func makeReceipt(
        id: String,
        isStarred: Bool = false,
        review: ReceiptQualityReview? = nil
    ) -> ReceiptRecord {
        var receipt = ReceiptRecord(
            id: id,
            sessionId: "sess-\(id)",
            projectName: "BurnBar",
            provider: .claudeCode,
            modelName: "claude-3-7-sonnet",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            inputTokens: 100,
            outputTokens: 50,
            totalCostUSD: 0.10,
            isStarred: isStarred
        )
        receipt.qualityReview = review
        return receipt
    }

    private func makeReview(grade: String) -> ReceiptQualityReview {
        ReceiptQualityReview(
            grade: grade,
            score: 90,
            goalScore: 90,
            rigorScore: 90,
            efficiencyScore: 90,
            reviewedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func test_inspectorState_resetsPerReceiptStateWhenTheReceiptChanges() {
        var state = ReceiptInspectorState(receipt: makeReceipt(id: "a", isStarred: true))
        XCTAssertTrue(state.isStarred)

        state.showCopiedAlert = true
        state.copiedAlertText = "Thermal Slip PNG Copied"

        state.receiptChanged(to: makeReceipt(id: "b", isStarred: false))

        XCTAssertFalse(state.isStarred, "the star must follow the newly selected receipt")
        XCTAssertFalse(state.showCopiedAlert, "receipt A's toast must not sit on receipt B")
        XCTAssertEqual(state.copiedAlertText, ReceiptInspectorState.defaultCopiedAlertText)
    }

    func test_inspectorState_keepsTheLensAcrossReceipts() {
        var state = ReceiptInspectorState(receipt: makeReceipt(id: "a"))
        state.selectedLens = .audit

        state.receiptChanged(to: makeReceipt(id: "b"))

        XCTAssertEqual(
            state.selectedLens,
            .audit,
            "the lens is a viewing mode the user chose, not per-receipt state"
        )
    }

    func test_inspectorState_seedsFromTheReceiptAndTheRequestedLens() {
        let state = ReceiptInspectorState(receipt: makeReceipt(id: "a", isStarred: true), lens: .efficiency)
        XCTAssertEqual(state.selectedLens, .efficiency)
        XCTAssertTrue(state.isStarred)
        XCTAssertFalse(state.showCopiedAlert)
    }

    func test_slipState_resetsGradeAndCopyStateWhenTheReceiptChanges() {
        let graded = makeReceipt(id: "a", review: makeReview(grade: "A+"))
        var state = ReceiptSlipState(receipt: graded)
        XCTAssertEqual(state.localReview?.grade, "A+")

        state.isGrading = true
        state.hasCopied = true

        state.receiptChanged(to: makeReceipt(id: "b"))

        XCTAssertNil(state.localReview, "receipt A's grade must not show on receipt B")
        XCTAssertFalse(state.isGrading)
        XCTAssertFalse(state.hasCopied)
    }

    func test_slipState_adoptsTheNewReceiptsExistingReview() {
        var state = ReceiptSlipState(receipt: makeReceipt(id: "a"))
        XCTAssertNil(state.localReview)

        state.receiptChanged(to: makeReceipt(id: "b", review: makeReview(grade: "B")))

        XCTAssertEqual(state.localReview?.grade, "B")
    }

    func test_slipState_appliesAGradeForTheReceiptItIsStillGrading() {
        var state = ReceiptSlipState(receipt: makeReceipt(id: "a"))
        state.startGrading(makeReceipt(id: "a"))
        XCTAssertTrue(state.isGrading)

        XCTAssertTrue(state.applyGrade(makeReview(grade: "A+"), from: "a"))

        XCTAssertEqual(state.localReview?.grade, "A+")
        XCTAssertFalse(state.isGrading)
    }

    func test_slipState_dropsALateGradeThatBelongsToAPreviousReceipt() {
        var state = ReceiptSlipState(receipt: makeReceipt(id: "a"))
        state.startGrading(makeReceipt(id: "a"))

        // The user selects receipt B while A's audit is still in flight.
        state.receiptChanged(to: makeReceipt(id: "b"))
        XCTAssertFalse(state.isGrading, "receipt B is not being graded")

        XCTAssertFalse(
            state.applyGrade(makeReview(grade: "A+"), from: "a"),
            "a grade for a receipt this slip is no longer grading must be refused"
        )
        XCTAssertNil(state.localReview, "receipt A's late grade must not paint receipt B's slip")
        XCTAssertFalse(state.isGrading)

        // Returning to A does not resurrect the abandoned audit either: the
        // grade reaches A through its persisted `qualityReview`, not through
        // this slip's in-flight slot.
        state.receiptChanged(to: makeReceipt(id: "a"))
        XCTAssertFalse(state.applyGrade(makeReview(grade: "A+"), from: "a"))
        XCTAssertNil(state.localReview)
    }
}
