import XCTest
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Covers the incremental live-usage listener support types
/// (`LiveUsageAccumulator`, `SealedProjectNameCache`) and the
/// `FirestoreRepository` decode wiring that routes the sealed-project-name
/// open through the per-listener `(docID, updatedAt)` memo. Mirrors the
/// Android `LiveUsageAccumulator` contract: same emit ordering, same
/// fail-open cache semantics.
@MainActor
final class LiveUsageAccumulatorTests: XCTestCase {

    private func usage(endTime: Date, seed: Int = 0) -> TokenUsage {
        TokenUsage(
            provider: .codex,
            sessionId: "session-\(seed)",
            projectName: "BurnBar",
            model: "model",
            inputTokens: 10,
            outputTokens: 20,
            costUSD: Double(seed),
            startTime: endTime.addingTimeInterval(-60),
            endTime: endTime
        )
    }

    // MARK: - LiveUsageAccumulator

    func testSnapshot_ordersByEndTimeDescending_withDocIDDescendingTiebreak() {
        let accumulator = LiveUsageAccumulator()
        let now = Date()
        accumulator.upsert(usage(endTime: now.addingTimeInterval(-120), seed: 1), docID: "a")
        accumulator.upsert(usage(endTime: now, seed: 2), docID: "b")
        // Same endTime as "b": Firestore's implicit `__name__` tiebreaker
        // follows the last orderBy direction (descending).
        accumulator.upsert(usage(endTime: now, seed: 3), docID: "c")

        let rows = accumulator.snapshot()
        XCTAssertEqual(rows.map(\.sessionId), ["session-3", "session-2", "session-1"])
    }

    func testUpsert_replacesExistingRowForSameDocID() {
        let accumulator = LiveUsageAccumulator()
        let now = Date()
        accumulator.upsert(usage(endTime: now, seed: 1), docID: "a")
        accumulator.upsert(usage(endTime: now.addingTimeInterval(30), seed: 2), docID: "a")

        let rows = accumulator.snapshot()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.sessionId, "session-2")
    }

    func testRemove_dropsRow_andIsSafeForUnknownDocIDs() {
        let accumulator = LiveUsageAccumulator()
        accumulator.upsert(usage(endTime: Date(), seed: 1), docID: "a")
        accumulator.remove(docID: "a")
        accumulator.remove(docID: "never-seen")
        XCTAssertTrue(accumulator.snapshot().isEmpty)
    }

    // MARK: - SealedProjectNameCache

    func testOpenOrCached_memoizesByDocIDAndUpdatedAt() {
        let cache = SealedProjectNameCache()
        var openCount = 0

        let first = cache.openOrCached(docID: "doc", updatedAtMillis: 100) {
            openCount += 1
            return "Alpha"
        }
        let second = cache.openOrCached(docID: "doc", updatedAtMillis: 100) {
            openCount += 1
            return "ShouldNotRun"
        }

        XCTAssertEqual(first, "Alpha")
        XCTAssertEqual(second, "Alpha")
        XCTAssertEqual(openCount, 1)
    }

    func testOpenOrCached_reopensWhenUpdatedAtChanges() {
        let cache = SealedProjectNameCache()
        var openCount = 0

        _ = cache.openOrCached(docID: "doc", updatedAtMillis: 100) {
            openCount += 1
            return "Alpha"
        }
        let updated = cache.openOrCached(docID: "doc", updatedAtMillis: 200) {
            openCount += 1
            return "Beta"
        }

        XCTAssertEqual(updated, "Beta")
        XCTAssertEqual(openCount, 2)
    }

    func testOpenOrCached_bypassesCacheWithoutFreshnessSignal() {
        let cache = SealedProjectNameCache()
        var openCount = 0

        for _ in 0..<3 {
            _ = cache.openOrCached(docID: "doc", updatedAtMillis: 0) {
                openCount += 1
                return "Alpha"
            }
        }

        // `updatedAt <= 0` means no freshness signal: a stale name must
        // never be served, so every delivery re-opens.
        XCTAssertEqual(openCount, 3)
    }

    func testOpenOrCached_cachesNilResults() {
        let cache = SealedProjectNameCache()
        var openCount = 0

        let first = cache.openOrCached(docID: "doc", updatedAtMillis: 100) {
            openCount += 1
            return nil
        }
        let second = cache.openOrCached(docID: "doc", updatedAtMillis: 100) {
            openCount += 1
            return nil
        }

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(openCount, 1)
    }

    func testRemove_forgetsCachedEntry() {
        let cache = SealedProjectNameCache()
        var openCount = 0

        _ = cache.openOrCached(docID: "doc", updatedAtMillis: 100) {
            openCount += 1
            return "Alpha"
        }
        cache.remove(docID: "doc")
        _ = cache.openOrCached(docID: "doc", updatedAtMillis: 100) {
            openCount += 1
            return "Alpha"
        }

        XCTAssertEqual(openCount, 2)
    }

    // MARK: - FirestoreRepository decode wiring

    private func payload(projectName: String, endTime: Date) -> [String: Any] {
        [
            "provider": AgentProvider.codex.rawValue,
            "sessionId": "session",
            "projectName": projectName,
            "model": "model",
            "inputTokens": 10,
            "outputTokens": 20,
            "cost": 0.5,
            "startTime": Timestamp(date: endTime.addingTimeInterval(-60)),
            "endTime": Timestamp(date: endTime)
        ]
    }

    func testDecodeTokenUsage_routesProjectNameThroughMemo() {
        let repository = FirestoreRepository()
        let cache = SealedProjectNameCache()
        let docID = UUID().uuidString
        let now = Date()

        let first = repository.decodeTokenUsage(
            from: payload(projectName: "First", endTime: now),
            docID: docID,
            updatedAtMillis: 100,
            projectNames: cache
        )
        // Same (docID, updatedAt): the memo must serve the cached open even
        // though the raw payload now carries a different legacy name —
        // proof the AEAD-open path was skipped.
        let second = repository.decodeTokenUsage(
            from: payload(projectName: "Second", endTime: now),
            docID: docID,
            updatedAtMillis: 100,
            projectNames: cache
        )
        // New updatedAt: the memo must re-open and pick up the new name.
        let third = repository.decodeTokenUsage(
            from: payload(projectName: "Third", endTime: now),
            docID: docID,
            updatedAtMillis: 200,
            projectNames: cache
        )

        XCTAssertEqual(first?.projectName, "First")
        XCTAssertEqual(second?.projectName, "First")
        XCTAssertEqual(third?.projectName, "Third")
    }

    func testUpdatedAtMillis_parsesTimestampAndDate_failsOpenOtherwise() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        XCTAssertEqual(FirestoreRepository.updatedAtMillis(Timestamp(date: date)), 1_700_000_000_500)
        XCTAssertEqual(FirestoreRepository.updatedAtMillis(date), 1_700_000_000_500)
        XCTAssertEqual(FirestoreRepository.updatedAtMillis(nil), 0)
        XCTAssertEqual(FirestoreRepository.updatedAtMillis("2026-06-09T00:00:00Z"), 0)
    }
}
