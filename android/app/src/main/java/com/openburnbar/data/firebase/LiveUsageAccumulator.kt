package com.openburnbar.data.firebase

import com.openburnbar.data.models.TokenUsage

/**
 * Per-listener document cache for the Pulse live-usage snapshot listener
 * (`FirestoreRepository.listenToUsageSince`).
 *
 * Firestore delivers a full result set on every snapshot, but only
 * `documentChanges` actually differ. Patching this id-keyed cache from the
 * deltas makes each delivery O(changed docs) instead of O(window) — on a
 * heavy agent day (hundreds to thousands of rows in the rolling 24h window)
 * every streamed usage write used to re-map and re-decrypt the entire window.
 *
 * Mirrors the iOS `listenToUsageSince` incremental redesign: same query shape
 * (`endTime >= cutoff`, endTime-descending, defensive 2000-doc cap), same
 * docID-keyed delta cache, same emit ordering.
 *
 * Not thread-safe by itself — the listener confines all access to its
 * single-threaded snapshot executor.
 */
internal class LiveUsageAccumulator {
    private val byId = HashMap<String, TokenUsage>()

    fun upsert(usage: TokenUsage) {
        byId[usage.id] = usage
    }

    fun remove(id: String) {
        byId.remove(id)
    }

    /**
     * The current window contents, ordered exactly like the raw query
     * results this replaces: `endTime` descending with the document id as
     * the descending tiebreaker (Firestore implicitly appends `__name__` in
     * the sort direction of the last explicit `orderBy`).
     */
    fun snapshot(): List<TokenUsage> = byId.values.sortedWith(
        compareByDescending<TokenUsage> { it.endTime }.thenByDescending { it.id },
    )
}

/**
 * Memoizes opened `sealedProjectName` values by `(docId, updatedAt)` so a
 * MODIFIED delivery (live rows advance token totals on every agent write)
 * only re-runs the AES-GCM open when the document actually changed since the
 * cached open — `updatedAt` is rewritten on every document rewrite, which is
 * what makes it a sound cache key.
 *
 * A missing/unparseable `updatedAt` (`<= 0`) bypasses the cache entirely:
 * with no freshness signal a stale name must never be served.
 *
 * Not thread-safe by itself — confined to the listener's snapshot executor.
 */
internal class SealedProjectNameCache {
    private data class Entry(val updatedAtMillis: Long, val projectName: String?)

    private val byDocId = HashMap<String, Entry>()

    fun openOrCached(docId: String, updatedAtMillis: Long, open: () -> String?): String? {
        if (updatedAtMillis <= 0L) return open()
        val cached = byDocId[docId]
        if (cached != null && cached.updatedAtMillis == updatedAtMillis) return cached.projectName
        val opened = open()
        byDocId[docId] = Entry(updatedAtMillis, opened)
        return opened
    }

    fun remove(docId: String) {
        byDocId.remove(docId)
    }
}
