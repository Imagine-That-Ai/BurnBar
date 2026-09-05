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

    func test_receiptFilter_parsesSmartQueryTokens() {
        let input = "refactor auth spend:>1.50 model:sonnet cache:>80% is:starred"
        let (cleaned, modifiers) = ReceiptFilter.parseSmartQuery(input)

        XCTAssertEqual(cleaned, "refactor auth")
        XCTAssertEqual(modifiers.minSpend, 1.50)
        XCTAssertEqual(modifiers.model, "sonnet")
        XCTAssertEqual(modifiers.minCache, 80.0)
        XCTAssertEqual(modifiers.starred, Optional(true))
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
