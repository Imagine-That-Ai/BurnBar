import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - SearchQueryCacheTests

final class SearchQueryCacheTests: XCTestCase {

    // MARK: - Helpers

    private func makeKey(_ text: String) -> SearchQueryCacheKey {
        SearchQueryCacheKey(query: RetrievalQuery(text: text))
    }

    private func makeResult(_ label: String) -> OpenBurnBarQueryRunResult {
        OpenBurnBarQueryRunResult(
            plan: BurnBarSearchPlan(
                mode: .retrieve,
                lexicalFTSQuery: label,
                semanticText: label,
                aggregatePatterns: [],
                requestedResultCount: nil,
                rankingIntent: .none,
                analysisIntent: .none,
                note: nil
            ),
            retrievalResults: [],
            aggregateOccurrenceCount: nil,
            aggregateWindowDescription: nil
        )
    }

    private func freshCache(maxEntries: Int = 4) -> SearchQueryCache {
        SearchQueryCache(maxEntries: maxEntries)
    }

    // MARK: - Tests

    func test_setThenGet_returnsCachedResult() {
        let cache = freshCache()
        let key = makeKey("hello")
        let now = Date()
        let result = makeResult("hello")
        cache.set(key: key, result: result, now: now)

        let hit = cache.get(key: key, now: now)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.plan.lexicalFTSQuery, "hello")
    }

    func test_expiredEntry_isEvictedOnGet() {
        let cache = freshCache()
        let key = makeKey("hello")
        let t0 = Date()
        cache.set(key: key, result: makeResult("hello"), now: t0)

        // TTL is 30s; advancing past that should miss.
        let t1 = t0.addingTimeInterval(31)
        let hit = cache.get(key: key, now: t1)
        XCTAssertNil(hit)
    }

    func test_lruEviction_dropsLeastRecentlyUsed() {
        let cache = freshCache(maxEntries: 2)
        let t0 = Date()
        let keyA = makeKey("a")
        let keyB = makeKey("b")
        let keyC = makeKey("c")

        cache.set(key: keyA, result: makeResult("a"), now: t0)
        cache.set(key: keyB, result: makeResult("b"), now: t0)

        // Touch A to make B the LRU.
        _ = cache.get(key: keyA, now: t0)

        // Insert C → evict B (LRU).
        cache.set(key: keyC, result: makeResult("c"), now: t0)

        XCTAssertNotNil(cache.get(key: keyA, now: t0))
        XCTAssertNil(cache.get(key: keyB, now: t0))
        XCTAssertNotNil(cache.get(key: keyC, now: t0))
    }

    func test_counters_trackHitsAndMisses() {
        let cache = freshCache()
        let t0 = Date()
        let key = makeKey("hello")
        cache.set(key: key, result: makeResult("hello"), now: t0)

        _ = cache.get(key: key, now: t0)       // hit
        _ = cache.get(key: makeKey("miss"), now: t0)  // miss

        let snapshot = cache.snapshotAndResetCounters()
        XCTAssertEqual(snapshot.hits, 1)
        XCTAssertEqual(snapshot.misses, 1)
        XCTAssertEqual(snapshot.entryCount, 1)

        // Counters reset after snapshot.
        let snapshot2 = cache.snapshotAndResetCounters()
        XCTAssertEqual(snapshot2.hits, 0)
        XCTAssertEqual(snapshot2.misses, 0)
    }

    func test_counters_trackEvictions() {
        let cache = freshCache(maxEntries: 2)
        let t0 = Date()
        cache.set(key: makeKey("a"), result: makeResult("a"), now: t0)
        cache.set(key: makeKey("b"), result: makeResult("b"), now: t0)
        // Insert C → evict the LRU (A, since B was inserted last).
        cache.set(key: makeKey("c"), result: makeResult("c"), now: t0)

        let snapshot = cache.snapshotAndResetCounters()
        XCTAssertEqual(snapshot.evictions, 1)
        XCTAssertEqual(snapshot.entryCount, 2)
    }

    func test_expiredEvictionCounters_onOpportunisticSweep() {
        let cache = freshCache(maxEntries: 4)
        let t0 = Date()
        // Fill to half-capacity with entries that will expire.
        cache.set(key: makeKey("a"), result: makeResult("a"), now: t0)
        cache.set(key: makeKey("b"), result: makeResult("b"), now: t0)

        // Advance past TTL; the next set triggers the opportunistic sweep.
        let t1 = t0.addingTimeInterval(31)
        cache.set(key: makeKey("c"), result: makeResult("c"), now: t1)

        let snapshot = cache.snapshotAndResetCounters()
        XCTAssertEqual(snapshot.expiredEvictions, 2)
    }

    func test_clearRemovesAllEntries() {
        let cache = freshCache()
        let t0 = Date()
        cache.set(key: makeKey("a"), result: makeResult("a"), now: t0)
        cache.set(key: makeKey("b"), result: makeResult("b"), now: t0)
        XCTAssertEqual(cache.count, 2)

        cache.clear()
        XCTAssertEqual(cache.count, 0)
    }

    func test_hitRateCalculation() {
        let counters = SearchQueryCacheCounters(hits: 3, misses: 1, evictions: 0, expiredEvictions: 0, entryCount: 1)
        XCTAssertEqual(counters.hitRate, 0.75, accuracy: 0.001)

        let empty = SearchQueryCacheCounters(hits: 0, misses: 0, evictions: 0, expiredEvictions: 0, entryCount: 0)
        XCTAssertEqual(empty.hitRate, 0.0)
    }

    func test_concurrentAccess_isSafe() {
        let cache = freshCache(maxEntries: 64)
        let t0 = Date()
        let keys = (0..<100).map { makeKey("key\($0)") }

        // Hammer from multiple threads.
        let group = DispatchGroup()
        for i in 0..<100 {
            group.enter()
            let result = makeResult("v\(i)")
            DispatchQueue.global().async {
                let key = keys[i % keys.count]
                cache.set(key: key, result: result, now: t0)
                _ = cache.get(key: key, now: t0)
                group.leave()
            }
        }
        group.wait()

        // After concurrent hammering, the cache must be within its cap.
        XCTAssertLessThanOrEqual(cache.count, 64)
        let snapshot = cache.snapshotAndResetCounters()
        // Only `get` operations produce hit/miss counters; `set` does not.
        // 100 concurrent gets → 100 total hits + misses.
        XCTAssertEqual(snapshot.hits + snapshot.misses, 100)
    }
}
