
package com.openburnbar.data.firebase

import com.openburnbar.data.models.TokenUsage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * Covers the incremental live-usage listener cache backing
 * `FirestoreRepository.listenToUsageSince` — the documentChanges-based
 * redesign that replaces the full-window re-map + re-decrypt on every
 * snapshot delivery (android-010 / ios-008 shared design).
 */
class LiveUsageAccumulatorTest {
    private fun usage(id: String, endTime: Long, cost: Double = 1.0) = TokenUsage(
        id = id,
        provider = "anthropic",
        cost = cost,
        timestamp = endTime,
        endTime = endTime,
    )

    @Test
    fun `snapshot orders by endTime descending with id as descending tiebreaker`() {
        // Matches the raw query ordering this cache replaces: orderBy endTime
        // DESC, where Firestore implicitly appends __name__ in the same
        // direction for ties.
        val accumulator = LiveUsageAccumulator()
        accumulator.upsert(usage(id = "a", endTime = 100L))
        accumulator.upsert(usage(id = "c", endTime = 300L))
        accumulator.upsert(usage(id = "b", endTime = 300L))

        assertEquals(listOf("c", "b", "a"), accumulator.snapshot().map { it.id })
    }

    @Test
    fun `modified document replaces the cached row instead of duplicating it`() {
        val accumulator = LiveUsageAccumulator()
        accumulator.upsert(usage(id = "live", endTime = 100L, cost = 1.0))
        accumulator.upsert(usage(id = "live", endTime = 250L, cost = 2.5))

        val rows = accumulator.snapshot()
        assertEquals(1, rows.size)
        assertEquals(250L, rows.first().endTime)
        assertEquals(2.5, rows.first().cost, 0.0)
    }

    @Test
    fun `removed document falls out of the snapshot`() {
        // REMOVED deltas arrive both for deletes and for rows pushed off the
        // 2000-doc limit boundary by newer writes.
        val accumulator = LiveUsageAccumulator()
        accumulator.upsert(usage(id = "old", endTime = 100L))
        accumulator.upsert(usage(id = "new", endTime = 200L))
        accumulator.remove("old")

        assertEquals(listOf("new"), accumulator.snapshot().map { it.id })
    }

    @Test
    fun `removing an unknown id is a no-op`() {
        val accumulator = LiveUsageAccumulator()
        accumulator.upsert(usage(id = "only", endTime = 100L))
        accumulator.remove("never-seen")

        assertEquals(listOf("only"), accumulator.snapshot().map { it.id })
    }

    @Test
    fun `empty accumulator emits an empty list`() {
        assertEquals(emptyList<TokenUsage>(), LiveUsageAccumulator().snapshot())
    }
}

class SealedProjectNameCacheTest {
    /** Counts how many times the AES-GCM open stand-in actually runs. */
    private class CountingOpener(private val produce: (Int) -> String?) {
        var opens = 0
            private set
        val open: () -> String? = {
            opens += 1
            produce(opens)
        }
    }

    @Test
    fun `same docId and updatedAt serves the cached open without recomputing`() {
        val cache = SealedProjectNameCache()
        val opener = CountingOpener { "burnbar" }

        assertEquals("burnbar", cache.openOrCached("doc-1", 1_000L, opener.open))
        assertEquals("burnbar", cache.openOrCached("doc-1", 1_000L, opener.open))
        assertEquals(1, opener.opens)
    }

    @Test
    fun `advanced updatedAt recomputes — token totals rewrite the doc`() {
        val cache = SealedProjectNameCache()
        val opener = CountingOpener { n -> "name-$n" }

        assertEquals("name-1", cache.openOrCached("doc-1", 1_000L, opener.open))
        assertEquals("name-2", cache.openOrCached("doc-1", 2_000L, opener.open))
        assertEquals(2, opener.opens)
        // The refreshed entry is what subsequent hits serve.
        assertEquals("name-2", cache.openOrCached("doc-1", 2_000L, opener.open))
        assertEquals(2, opener.opens)
    }

    @Test
    fun `a cached null is served as null instead of re-opening`() {
        // Null is a legal open result (vault inactive on this device), and
        // must be distinguishable from "absent from cache".
        val cache = SealedProjectNameCache()
        val opener = CountingOpener { null }

        assertNull(cache.openOrCached("doc-1", 1_000L, opener.open))
        assertNull(cache.openOrCached("doc-1", 1_000L, opener.open))
        assertEquals(1, opener.opens)
    }

    @Test
    fun `missing updatedAt bypasses the cache entirely`() {
        // Without a freshness signal a stale name must never be served.
        val cache = SealedProjectNameCache()
        val opener = CountingOpener { n -> "fresh-$n" }

        assertEquals("fresh-1", cache.openOrCached("doc-1", 0L, opener.open))
        assertEquals("fresh-2", cache.openOrCached("doc-1", 0L, opener.open))
        assertEquals(2, opener.opens)
    }

    @Test
    fun `removed doc is evicted and re-opens on return`() {
        val cache = SealedProjectNameCache()
        val opener = CountingOpener { "burnbar" }

        cache.openOrCached("doc-1", 1_000L, opener.open)
        cache.remove("doc-1")
        cache.openOrCached("doc-1", 1_000L, opener.open)
        assertEquals(2, opener.opens)
    }

    @Test
    fun `entries are independent per docId`() {
        val cache = SealedProjectNameCache()
        val nameA = "alpha"
        val nameB = "beta"

        assertSame(nameA, cache.openOrCached("doc-a", 1_000L) { nameA })
        assertSame(nameB, cache.openOrCached("doc-b", 1_000L) { nameB })
        // Cached independently — each serves its own value.
        assertSame(nameA, cache.openOrCached("doc-a", 1_000L) { error("must not re-open") })
        assertSame(nameB, cache.openOrCached("doc-b", 1_000L) { error("must not re-open") })
    }
}
