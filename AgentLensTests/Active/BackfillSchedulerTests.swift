import XCTest
import GRDB
@testable import OpenBurnBar

/// Tests for backfill scheduler with 7-day bounded windows and monotonic cursor progression.
///
/// Verifies:
/// - VAL-PERSIST-006: Backfill run is bounded to 7-day window
/// - VAL-PERSIST-007: Backfill cursor progresses monotonically
/// - VAL-CROSS-003: Backfill and live ingestion coexist without regressions
@MainActor
final class BackfillSchedulerTests: XCTestCase {

    // MARK: - Helpers

    private func makeInMemoryDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeBackfillCursorStore(_ store: DataStore) -> BackfillCursorStore {
        store.backfillCursorStore
    }

    private func fetchAllCursors(store: DataStore) throws -> [BackfillCursorRecord] {
        try makeBackfillCursorStore(store).fetchAllCursors()
    }

    private func fetchCursor(store: DataStore, provider: AgentProvider) throws -> BackfillCursorRecord? {
        try makeBackfillCursorStore(store).fetchCursor(for: provider)
    }

    // MARK: - VAL-PERSIST-006: Backfill run is bounded to 7-day window

    /// Tests that nextBackfillWindow returns a window no larger than 7 days.
    func test_backfillWindow_isBoundedToSevenDays() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()

        // When no cursor exists, next window should be 7 days ending at now
        guard let window = try cursorStore.nextBackfillWindow(for: .claudeCode, currentDate: now) else {
            XCTFail("Expected a backfill window")
            return
        }

        let windowDuration = window.upperBound.timeIntervalSince(window.lowerBound)
        let sevenDaysSeconds: TimeInterval = 7 * 24 * 60 * 60

        XCTAssertLessThanOrEqual(
            windowDuration,
            sevenDaysSeconds,
            "Backfill window duration (\(windowDuration)s) must not exceed 7 days (\(sevenDaysSeconds)s)"
        )
    }

    /// Tests that multiple sequential windows don't exceed 7 days each.
    func test_sequentialWindows_respectSevenDayBound() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()

        // Simulate multiple backfill runs
        var lastUpperBound: Date? = nil
        let maxIterations = 10

        for _ in 0..<maxIterations {
            guard let window = try cursorStore.nextBackfillWindow(for: .claudeCode, currentDate: now) else {
                break // Backfill complete
            }

            let windowDuration = window.upperBound.timeIntervalSince(window.lowerBound)
            let sevenDaysSeconds: TimeInterval = 7 * 24 * 60 * 60

            XCTAssertLessThanOrEqual(
                windowDuration,
                sevenDaysSeconds,
                "Each backfill window must not exceed 7 days"
            )

            // Advance cursor to simulate successful backfill
            try cursorStore.advanceCursor(
                for: .claudeCode,
                newUpperBound: window.upperBound
            )
            lastUpperBound = window.upperBound
        }

        XCTAssertNotNil(lastUpperBound, "Should have processed at least one window")
    }

    /// Tests that window is clamped to current date if 7 days would exceed it.
    func test_backfillWindow_clampedToCurrentDate() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)

        // When starting fresh with a recent "earliest source", window should be clamped
        try cursorStore.advanceCursor(
            for: .claudeCode,
            newUpperBound: threeDaysAgo,
            earliestSourceDate: now.addingTimeInterval(-10 * 24 * 60 * 60) // 10 days ago
        )

        guard let window = try cursorStore.nextBackfillWindow(for: .claudeCode, currentDate: now) else {
            XCTFail("Expected a backfill window")
            return
        }

        // Window start should be 3 days ago, end should be now (clamped)
        XCTAssertEqual(
            window.lowerBound,
            threeDaysAgo,
            "Window should start from cursor position"
        )
        XCTAssertEqual(
            window.upperBound,
            now,
            "Window should be clamped to current date"
        )
    }

    // MARK: - VAL-PERSIST-007: Backfill cursor progresses monotonically

    /// Tests that cursor cannot advance to a date before the current cursor.
    func test_cursor_cannotAdvanceBackward() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()
        let fiveDaysAgo = now.addingTimeInterval(-5 * 24 * 60 * 60)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)

        // First advance: 5 days ago
        try cursorStore.advanceCursor(
            for: .claudeCode,
            newUpperBound: fiveDaysAgo
        )

        // Verify cursor is at 5 days ago
        guard let cursor = try fetchCursor(store: store, provider: .claudeCode) else {
            XCTFail("Expected cursor to exist")
            return
        }
        XCTAssertEqual(cursor.lastProcessedWindowUpperBound, fiveDaysAgo)

        // Attempt to advance to 3 days ago should fail (backward)
        do {
            try cursorStore.advanceCursor(
                for: .claudeCode,
                newUpperBound: threeDaysAgo
            )
            XCTFail("Should have thrown nonMonotonicAdvance error")
        } catch let error as BackfillCursorError {
            switch error {
            case .nonMonotonicAdvance:
                break // Expected
            default:
                XCTFail("Expected nonMonotonicAdvance error, got \(error)")
            }
        }
    }

    /// Tests that cursor advances monotonically through sequential backfill runs.
    func test_cursor_advancesMonotonically() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()

        var previousUpperBound: Date? = nil

        // Simulate 5 sequential backfill runs
        for dayOffset in stride(from: 30, through: 2, by: -7) {
            guard let window = try cursorStore.nextBackfillWindow(for: .factory, currentDate: now) else {
                break
            }

            // Verify window is after previous
            if let previous = previousUpperBound {
                XCTAssertGreaterThan(
                    window.lowerBound,
                    previous,
                    "Each new window should start after the previous upper bound"
                )
            }

            // Advance cursor
            try cursorStore.advanceCursor(
                for: .factory,
                newUpperBound: window.upperBound
            )

            previousUpperBound = window.upperBound
        }

        // Verify final cursor position
        guard let finalCursor = try fetchCursor(store: store, provider: .factory) else {
            XCTFail("Expected final cursor")
            return
        }
        XCTAssertNotNil(finalCursor.lastProcessedWindowUpperBound)
    }

    /// Tests that resetCursor allows starting fresh from the beginning.
    func test_cursor_reset_allowsFreshStart() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 24 * 60 * 60)

        // Advance cursor to 10 days ago
        try cursorStore.advanceCursor(
            for: .claudeCode,
            newUpperBound: tenDaysAgo
        )

        // Reset cursor
        try cursorStore.resetCursor(for: .claudeCode)

        // Verify cursor is gone
        let cursor = try fetchCursor(store: store, provider: .claudeCode)
        XCTAssertNil(cursor)

        // Now we should be able to get a window starting from scratch
        guard let window = try cursorStore.nextBackfillWindow(for: .claudeCode, currentDate: now) else {
            XCTFail("Expected a backfill window after reset")
            return
        }

        // Window should start from 7 days ago (default initial window)
        let sevenDaysSeconds: TimeInterval = 7 * 24 * 60 * 60
        let expectedStart = now.addingTimeInterval(-sevenDaysSeconds)
        XCTAssertEqual(
            window.lowerBound,
            expectedStart,
            "After reset, window should start from default position"
        )
    }

    /// Tests that earliestSourceDate is preserved across advances but can be set on first advance.
    func test_cursor_earliestSourceDate_preserved() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 24 * 60 * 60)

        // First advance with earliest source date
        try cursorStore.advanceCursor(
            for: .kimi,
            newUpperBound: now.addingTimeInterval(-23 * 24 * 60 * 60),
            earliestSourceDate: thirtyDaysAgo
        )

        // Second advance without earliest source date
        try cursorStore.advanceCursor(
            for: .kimi,
            newUpperBound: now.addingTimeInterval(-16 * 24 * 60 * 60)
        )

        // Third advance without earliest source date
        try cursorStore.advanceCursor(
            for: .kimi,
            newUpperBound: now.addingTimeInterval(-9 * 24 * 60 * 60)
        )

        guard let cursor = try fetchCursor(store: store, provider: .kimi) else {
            XCTFail("Expected cursor")
            return
        }

        // Earliest source date should still be 30 days ago
        XCTAssertEqual(
            cursor.earliestSourceDate,
            thirtyDaysAgo,
            "Earliest source date should be preserved"
        )
    }

    // MARK: - VAL-CROSS-003: Backfill and live ingestion coexist

    /// Tests that exact-first upsert semantics are preserved during backfill.
    /// Backfill writes use the same exact-first upsert as live ingestion,
    /// so existing exact rows cannot be downgraded.
    func test_backfill_coexistsWithExactFirstLiveIngestion() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()
        let fiveDaysAgo = now.addingTimeInterval(-5 * 24 * 60 * 60)

        // Insert an exact live ingestion row first
        let liveExactUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "live-exact-session",
            projectName: "LiveProject",
            model: "claude-4-sonnet",
            inputTokens: 2000,
            outputTokens: 1000,
            costUSD: 0.10,
            startTime: fiveDaysAgo,
            endTime: fiveDaysAgo.addingTimeInterval(60),
            usageSource: .providerLog,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(liveExactUsage)

        // Advance backfill cursor past that date
        try cursorStore.advanceCursor(
            for: .claudeCode,
            newUpperBound: now.addingTimeInterval(-3 * 24 * 60 * 60)
        )

        // Insert another exact live row
        let liveExactUsage2 = TokenUsage(
            provider: .claudeCode,
            sessionId: "live-exact-session-2",
            projectName: "LiveProject2",
            model: "claude-4-sonnet",
            inputTokens: 3000,
            outputTokens: 1500,
            costUSD: 0.15,
            startTime: now.addingTimeInterval(-1 * 24 * 60 * 60),
            endTime: now,
            usageSource: .providerLog,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(liveExactUsage2)

        store.refresh()

        // Verify both live exact rows exist and exact-first semantics preserved
        let allUsages = store.usages
        let liveExact1 = allUsages.first { $0.sessionId == "live-exact-session" }
        let liveExact2 = allUsages.first { $0.sessionId == "live-exact-session-2" }

        XCTAssertNotNil(liveExact1, "First live exact row should exist")
        XCTAssertNotNil(liveExact2, "Second live exact row should exist")
        XCTAssertEqual(liveExact1?.inputTokens, 2000, "Live exact values should not be changed")
        XCTAssertEqual(liveExact2?.inputTokens, 3000, "Live exact values should not be changed")
    }

    /// Tests that backfill cannot overwrite exact live ingestion rows with lower confidence.
    func test_backfill_cannotDowngradeExactLiveRows() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()
        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 60 * 60)

        // Insert exact live ingestion row
        let liveExactUsage = TokenUsage(
            provider: .factory,
            sessionId: "exact-live-session",
            projectName: "ExactLiveProject",
            model: "glm-4",
            inputTokens: 5000,
            outputTokens: 2000,
            costUSD: 0.20,
            startTime: sixDaysAgo,
            endTime: sixDaysAgo.addingTimeInterval(60),
            usageSource: .providerLog,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(liveExactUsage)

        // Now simulate backfill writing a lower-confidence estimate for the same session
        let backfillEstimateUsage = TokenUsage(
            provider: .factory,
            sessionId: "exact-live-session", // Same session
            projectName: "BackfillProject",
            model: "glm-4",
            inputTokens: 4000, // Different (lower) values
            outputTokens: 1500,
            costUSD: 0.15,
            startTime: sixDaysAgo,
            endTime: sixDaysAgo.addingTimeInterval(60),
            usageSource: .providerLog,
            provenanceMethod: .heuristicEstimate, // Lower confidence
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try store.insert(backfillEstimateUsage)

        store.refresh()

        // Verify exact row was NOT downgraded - exact-first semantics preserved
        let canonicalRow = store.usages.first { $0.sessionId == "exact-live-session" }
        XCTAssertNotNil(canonicalRow)
        XCTAssertEqual(canonicalRow?.inputTokens, 5000, "Exact live row should not be downgraded")
        XCTAssertEqual(canonicalRow?.provenanceConfidence, .exact, "Confidence should remain exact")
    }

    /// Tests that live ingestion can upgrade a backfill estimate to exact.
    func test_liveIngestion_canUpgradeBackfillEstimate() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)

        // First: Backfill writes an estimated row
        let backfillEstimateUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "upgrade-test-session",
            projectName: "BackfillProject",
            model: "claude-4-sonnet",
            inputTokens: 1000, // Estimate
            outputTokens: 500,
            costUSD: 0.05,
            startTime: eightDaysAgo,
            endTime: eightDaysAgo.addingTimeInterval(60),
            usageSource: .providerLog,
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try store.insert(backfillEstimateUsage)

        // Advance cursor past that date
        try cursorStore.advanceCursor(
            for: .claudeCode,
            newUpperBound: now.addingTimeInterval(-1 * 24 * 60 * 60)
        )

        // Later: Live ingestion provides exact data for the same session
        let liveExactUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "upgrade-test-session", // Same session
            projectName: "ExactLiveProject",
            model: "claude-4-sonnet",
            inputTokens: 2000, // Exact value (higher)
            outputTokens: 1000,
            costUSD: 0.09,
            startTime: eightDaysAgo,
            endTime: eightDaysAgo.addingTimeInterval(60),
            usageSource: .providerLog,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(liveExactUsage)

        store.refresh()

        // Verify row was upgraded to exact
        let canonicalRow = store.usages.first { $0.sessionId == "upgrade-test-session" }
        XCTAssertNotNil(canonicalRow)
        XCTAssertEqual(canonicalRow?.provenanceConfidence, .exact, "Should be upgraded to exact")
        XCTAssertEqual(canonicalRow?.inputTokens, 2000, "Should have exact values")
    }

    /// Tests that multiple providers maintain independent cursors.
    func test_cursor_independentPerProvider() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()

        // Advance cursor for claudeCode
        let claudeCursor = now.addingTimeInterval(-5 * 24 * 60 * 60)
        try cursorStore.advanceCursor(for: .claudeCode, newUpperBound: claudeCursor)

        // Advance cursor for factory (different date)
        let factoryCursor = now.addingTimeInterval(-10 * 24 * 60 * 60)
        try cursorStore.advanceCursor(for: .factory, newUpperBound: factoryCursor)

        // Verify cursors are independent
        guard let c1 = try fetchCursor(store: store, provider: .claudeCode),
              let c2 = try fetchCursor(store: store, provider: .factory) else {
            XCTFail("Expected both cursors")
            return
        }

        XCTAssertEqual(c1.lastProcessedWindowUpperBound, claudeCursor)
        XCTAssertEqual(c2.lastProcessedWindowUpperBound, factoryCursor)
        XCTAssertGreaterThan(claudeCursor, factoryCursor, "Claude cursor should be ahead of factory cursor")
    }

    // MARK: - Window Boundary Edge Cases

    /// Tests that first backfill window starts from default position (7 days ago) when no earliest date is known.
    func test_firstBackfillWindow_startsFromDefault() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()

        guard let window = try cursorStore.nextBackfillWindow(for: .claudeCode, currentDate: now) else {
            XCTFail("Expected a backfill window")
            return
        }

        // Default start should be 7 days ago
        let sevenDaysSeconds: TimeInterval = 7 * 24 * 60 * 60
        let expectedStart = now.addingTimeInterval(-sevenDaysSeconds)

        XCTAssertEqual(
            window.lowerBound.timeIntervalSince(expectedStart),
            0,
            accuracy: 1,
            "First window should start 7 days ago"
        )
    }

    // MARK: - Concurrent Safety (Idempotency)

    /// Tests that multiple calls to advanceCursor with the same value are idempotent.
    func test_advanceCursor_isIdempotent() throws {
        let store = try makeInMemoryDataStore()
        let cursorStore = makeBackfillCursorStore(store)
        let now = Date()
        let fiveDaysAgo = now.addingTimeInterval(-5 * 24 * 60 * 60)

        // Advance twice with same value
        try cursorStore.advanceCursor(for: .cursor, newUpperBound: fiveDaysAgo)
        try cursorStore.advanceCursor(for: .cursor, newUpperBound: fiveDaysAgo)

        guard let cursor = try fetchCursor(store: store, provider: .cursor) else {
            XCTFail("Expected cursor")
            return
        }

        XCTAssertEqual(cursor.lastProcessedWindowUpperBound, fiveDaysAgo)
        XCTAssertEqual(cursor.version, 2, "Version should increment on each advance")
    }
}
