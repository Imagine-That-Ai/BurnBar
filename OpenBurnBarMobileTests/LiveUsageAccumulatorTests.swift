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

    func testUpsert_reordersRowWhenEndTimeAdvances() {
        // A live row's totals advance: same doc id, newer endTime. The row
        // must move to its new position, not duplicate.
        let accumulator = LiveUsageAccumulator()
        let now = Date()
        accumulator.upsert(usage(endTime: now, seed: 1), docID: "a")
        accumulator.upsert(usage(endTime: now.addingTimeInterval(10), seed: 2), docID: "b")
        accumulator.upsert(usage(endTime: now.addingTimeInterval(20), seed: 3), docID: "a")

        let rows = accumulator.snapshot()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.sessionId), ["session-3", "session-2"])
    }

    /// A fixed-seed pseudo-random stream of upserts, reorder writes and
    /// removals must always match the naive whole-window sort the incremental
    /// order replaced.
    func testSnapshot_matchesNaiveSort() {
        var rng = SplitMix64(seed: 0xC10C)
        let accumulator = LiveUsageAccumulator()
        var model: [String: TokenUsage] = [:]
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for step in 0..<2_000 {
            let docID = "doc-\(rng.next(upperBound: 300))"
            switch rng.next(upperBound: 10) {
            case 0..<7:
                // New rows and reorder writes share a small endTime pool so
                // ties are frequent and the tiebreaker is exercised.
                let skew = TimeInterval(rng.next(upperBound: 50))
                let row = usage(endTime: base.addingTimeInterval(skew), seed: step)
                accumulator.upsert(row, docID: docID)
                model[docID] = row
            default:
                accumulator.remove(docID: docID)
                model.removeValue(forKey: docID)
            }
            if step % 211 == 0 {
                XCTAssertEqual(snapshotSessions(accumulator), naiveSessions(model), "diverged at step \(step)")
            }
        }
        XCTAssertEqual(snapshotSessions(accumulator), naiveSessions(model))
    }

    private func snapshotSessions(_ accumulator: LiveUsageAccumulator) -> [String] {
        accumulator.snapshot().map(\.sessionId)
    }

    private func naiveSessions(_ model: [String: TokenUsage]) -> [String] {
        model
            .sorted { lhs, rhs in
                if lhs.value.endTime != rhs.value.endTime {
                    return lhs.value.endTime > rhs.value.endTime
                }
                return lhs.key > rhs.key
            }
            .map(\.value.sessionId)
    }

    /// One changed document in a full window: the delivery must not re-sort
    /// the window. Reports, rather than asserts — the number is the Stream C
    /// evidence; the differential test above is the guard.
    ///
    /// `OPENBURNBAR_ACCUMULATOR_LOAD_N` scales the window past the 2,000-doc
    /// listener cap for the 10x load probe. The naive-sort baseline next to
    /// each number is the exact whole-window sort this order replaced.
    func testPerformance_singleChangeDelivery() {
        let window = Int(ProcessInfo.processInfo.environment["OPENBURNBAR_ACCUMULATOR_LOAD_N"] ?? "") ?? 2_000
        let accumulator = LiveUsageAccumulator()
        var model: [String: TokenUsage] = [:]
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<window {
            let row = usage(endTime: base.addingTimeInterval(TimeInterval(index)), seed: index)
            accumulator.upsert(row, docID: "doc-\(index)")
            model["doc-\(index)"] = row
        }
        // Baseline first: what one delivery cost when the whole window
        // re-sorted per delivery.
        let naiveStart = Date()
        let naiveIterations = 20
        for tick in 1...naiveIterations {
            model["doc-0"] = usage(endTime: base.addingTimeInterval(TimeInterval(window + tick)), seed: window + tick)
            _ = model
                .sorted { lhs, rhs in
                    if lhs.value.endTime != rhs.value.endTime {
                        return lhs.value.endTime > rhs.value.endTime
                    }
                    return lhs.key > rhs.key
                }
                .map(\.value)
        }
        print(
            "PERF window=\(window) naiveSortPerDeliverySeconds=\(Date().timeIntervalSince(naiveStart) / Double(naiveIterations))"
        )
        var tick = 0
        measure {
            tick += 1
            accumulator.upsert(
                usage(endTime: base.addingTimeInterval(TimeInterval(window + tick)), seed: window + tick),
                docID: "doc-0"
            )
            _ = accumulator.snapshot()
        }
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

/// SplitMix64: a tiny deterministic RNG so the differential test replays the
/// same stream on every run and every platform.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(upperBound: UInt64) -> UInt64 {
        next() % upperBound
    }
}
