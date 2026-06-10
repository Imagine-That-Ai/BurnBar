package com.openburnbar.data.firebase

import com.google.firebase.firestore.DocumentSnapshot
import com.openburnbar.data.models.RollupSummary
import com.openburnbar.data.models.UsageRollups

internal val firestoreRollupWindowKeys = listOf("today", "7d", "30d", "90d", "all_time")

private fun DocumentSnapshot.toRollups(): UsageRollups? {
    val data = data ?: return null
    return UsageRollups(
        today = (data["today"] as? Number)?.toDouble() ?: 0.0,
        sevenDays = (data["7d"] as? Number)?.toDouble() ?: 0.0,
        thirtyDays = (data["30d"] as? Number)?.toDouble() ?: 0.0,
        ninetyDays = (data["90d"] as? Number)?.toDouble() ?: 0.0,
        allTime = (data["all_time"] as? Number)?.toDouble() ?: 0.0,
        totals =
        (data["totals"] as? Map<*, *>)
            ?.mapNotNull { (key, value) -> (key as? String)?.let { it to ((value as? Number)?.toDouble() ?: 0.0) } }
            ?.toMap()
            ?: emptyMap(),
        providerSummaries = (data["providerSummaries"] as? List<*>)?.mapNotNull { (it as? Map<*, *>)?.toRollupSummary() } ?: emptyList(),
        accountSummaries = (data["accountSummaries"] as? List<*>)?.mapNotNull { (it as? Map<*, *>)?.toRollupSummary() } ?: emptyList(),
        modelSummaries = (data["modelSummaries"] as? List<*>)?.mapNotNull { (it as? Map<*, *>)?.toRollupSummary() } ?: emptyList(),
        deviceSummaries = (data["deviceSummaries"] as? List<*>)?.mapNotNull { (it as? Map<*, *>)?.toRollupSummary() } ?: emptyList(),
        dailyPoints =
        (data["dailyPoints"] as? Map<*, *>)
            ?.mapNotNull { (key, value) -> (key as? String)?.let { it to ((value as? Number)?.toDouble() ?: 0.0) } }
            ?.toMap()
            ?: emptyMap(),
        computedAt = data["computedAt"] as? String,
        schemaVersion = (data["schemaVersion"] as? Number)?.toInt() ?: 0,
    )
}

private fun Map<*, *>.toRollupSummary(): RollupSummary = RollupSummary(
    provider = this["provider"] as? String ?: this["model"] as? String ?: this["deviceId"] as? String ?: "",
    providerId = this["providerID"] as? String,
    accountId = this["accountID"] as? String,
    accountLabel = this["accountLabel"] as? String ?: "",
    storageScope = this["storageScope"] as? String,
    totalRequests = (this["totalRequests"] as? Number)?.toInt() ?: (this["requests"] as? Number)?.toInt() ?: 0,
    totalTokens = (this["totalTokens"] as? Number)?.toLong() ?: (this["tokens"] as? Number)?.toLong() ?: 0L,
    totalCost = (this["totalCost"] as? Number)?.toDouble() ?: (this["cost"] as? Number)?.toDouble() ?: 0.0,
)

internal object FirestoreRollupMerger {
    /**
     * Merge a whole usage_rollups collection snapshot (one read/listener
     * instead of five per-document ones). Drops any document whose ID is not
     * one of the five window keys so the output is identical to per-key reads
     * even if a stray doc ever lands in the collection.
     */
    fun mergeCollectionDocs(documents: List<DocumentSnapshot>): UsageRollups =
        mergeWindowDocs(
            documents
                .filter { it.id in firestoreRollupWindowKeys }
                .associateBy { it.id },
        )

    /** Merge per-window UsageRollupDoc documents into the flat client model. */
    fun mergeWindowDocs(docs: Map<String, DocumentSnapshot?>): UsageRollups {
        val allDocs =
            docs.mapNotNull { (key, snap) ->
                snap?.toRollups()?.let { key to it }
            }.toMap()
        if (allDocs.isEmpty()) return UsageRollups()

        val allTimeDoc = allDocs["all_time"] ?: allDocs.values.first()
        return buildMergedRollups(allDocs, allTimeDoc)
    }

    private fun buildMergedRollups(allDocs: Map<String, UsageRollups>, allTimeDoc: UsageRollups): UsageRollups =
        UsageRollups(
            today = windowCost(allDocs, "today", allTimeDoc),
            sevenDays = windowCost(allDocs, "7d", allTimeDoc),
            thirtyDays = windowCost(allDocs, "30d", allTimeDoc),
            ninetyDays = windowCost(allDocs, "90d", allTimeDoc),
            allTime = allTimeDoc.costUsd(),
            todayTokens = windowTokens(allDocs, "today", allTimeDoc),
            sevenDayTokens = windowTokens(allDocs, "7d", allTimeDoc),
            thirtyDayTokens = windowTokens(allDocs, "30d", allTimeDoc),
            ninetyDayTokens = windowTokens(allDocs, "90d", allTimeDoc),
            allTimeTokens = allTimeDoc.tokens(),
            todayRequests = windowRequests(allDocs, "today", allTimeDoc),
            sevenDayRequests = windowRequests(allDocs, "7d", allTimeDoc),
            thirtyDayRequests = windowRequests(allDocs, "30d", allTimeDoc),
            ninetyDayRequests = windowRequests(allDocs, "90d", allTimeDoc),
            allTimeRequests = allTimeDoc.requests(),
            totals = allTimeDoc.totals,
            providerSummaries = allTimeDoc.providerSummaries,
            accountSummaries = allTimeDoc.accountSummaries,
            modelSummaries = allTimeDoc.modelSummaries,
            deviceSummaries = allTimeDoc.deviceSummaries,
            dailyPoints = allTimeDoc.dailyPoints,
            computedAt = allTimeDoc.computedAt,
            schemaVersion = allTimeDoc.schemaVersion,
        )

    private fun windowCost(allDocs: Map<String, UsageRollups>, key: String, fallback: UsageRollups): Double =
        allDocs[key]?.costUsd() ?: fallback.costUsd()

    private fun windowTokens(allDocs: Map<String, UsageRollups>, key: String, fallback: UsageRollups): Long =
        allDocs[key]?.tokens() ?: fallback.tokens()

    private fun windowRequests(allDocs: Map<String, UsageRollups>, key: String, fallback: UsageRollups): Int =
        allDocs[key]?.requests() ?: fallback.requests()

    private fun UsageRollups.costUsd(): Double = totals["costUsd"] ?: 0.0

    private fun UsageRollups.tokens(): Long =
        listOfNotNull(
            totals["tokens"],
            today.takeIf { it > 0 },
            sevenDays.takeIf { it > 0 },
            thirtyDays.takeIf { it > 0 },
            ninetyDays.takeIf { it > 0 },
            allTime.takeIf { it > 0 },
        ).firstOrNull()?.toLong() ?: 0L

    private fun UsageRollups.requests(): Int = (totals["requests"] ?: 0.0).toInt()
}
