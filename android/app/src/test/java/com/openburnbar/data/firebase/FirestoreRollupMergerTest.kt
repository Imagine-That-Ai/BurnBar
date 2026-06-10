@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.firebase

import com.google.firebase.firestore.DocumentSnapshot
import com.openburnbar.data.models.UsageRollups
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Proves the single-collection rollup read (`mergeCollectionDocs`, one
 * round-trip / one listener) yields output identical to the previous
 * five per-document window reads (`mergeWindowDocs` fed per-key), and that
 * stray non-window documents in the collection never change the result.
 */
class FirestoreRollupMergerTest {
    private fun doc(docId: String, docData: Map<String, Any>?): DocumentSnapshot {
        val snap = mockk<DocumentSnapshot>()
        every { snap.id } returns docId
        every { snap.data } returns docData
        return snap
    }

    private fun windowDoc(key: String, cost: Double, tokens: Long, requests: Int): DocumentSnapshot = doc(
        key,
        mapOf(
            "totals" to mapOf("costUsd" to cost, "tokens" to tokens, "requests" to requests),
            "providerSummaries" to listOf(
                mapOf("provider" to "anthropic", "totalRequests" to requests, "totalTokens" to tokens, "totalCost" to cost),
            ),
            "modelSummaries" to listOf(
                mapOf("provider" to "anthropic", "model" to "claude", "totalTokens" to tokens, "totalCost" to cost),
            ),
            "dailyPoints" to mapOf("2026-06-09" to cost),
            "computedAt" to "2026-06-09T00:00:00Z",
            "schemaVersion" to 3,
        ),
    )

    private val allWindowDocs = listOf(
        windowDoc("today", cost = 1.25, tokens = 100L, requests = 2),
        windowDoc("7d", cost = 7.5, tokens = 700L, requests = 14),
        windowDoc("30d", cost = 30.0, tokens = 3_000L, requests = 60),
        windowDoc("90d", cost = 90.75, tokens = 9_000L, requests = 180),
        windowDoc("all_time", cost = 365.5, tokens = 36_500L, requests = 730),
    )

    /** The pre-batching fetch shape: one (possibly missing) snapshot per window key. */
    private fun perKeyReads(docs: List<DocumentSnapshot>): Map<String, DocumentSnapshot?> =
        firestoreRollupWindowKeys.associateWith { key -> docs.firstOrNull { it.id == key } }

    @Test
    fun `collection read merges identically to five per-key reads`() {
        val merged = FirestoreRollupMerger.mergeCollectionDocs(allWindowDocs)

        assertEquals(FirestoreRollupMerger.mergeWindowDocs(perKeyReads(allWindowDocs)), merged)
        assertEquals(1.25, merged.today, 0.0)
        assertEquals(365.5, merged.allTime, 0.0)
        assertEquals(100L, merged.todayTokens)
        assertEquals(730, merged.allTimeRequests)
    }

    @Test
    fun `stray non-window documents are dropped`() {
        val withStray = allWindowDocs + doc("metadata", mapOf("totals" to mapOf("costUsd" to 9_999.0)))

        assertEquals(
            FirestoreRollupMerger.mergeCollectionDocs(allWindowDocs),
            FirestoreRollupMerger.mergeCollectionDocs(withStray),
        )
    }

    @Test
    fun `missing windows fall back to all_time like per-key reads`() {
        val onlyAllTime = listOf(windowDoc("all_time", cost = 42.0, tokens = 4_200L, requests = 84))

        val merged = FirestoreRollupMerger.mergeCollectionDocs(onlyAllTime)

        assertEquals(FirestoreRollupMerger.mergeWindowDocs(perKeyReads(onlyAllTime)), merged)
        assertEquals(42.0, merged.today, 0.0)
        assertEquals(42.0, merged.allTime, 0.0)
    }

    @Test
    fun `empty collection yields empty rollups`() {
        assertEquals(UsageRollups(), FirestoreRollupMerger.mergeCollectionDocs(emptyList()))
    }
}
