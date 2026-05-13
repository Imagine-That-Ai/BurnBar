package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightTaxonomy
import java.security.MessageDigest

/**
 * Builds a privacy-bounded InsightDigest from Firestore rollups on Android.
 * Mirrors the Swift InsightDigestBuilder with the same 24KB ceiling.
 *
 * Android-specific note: useCaseHistogram, agentFocusSignals, and modelFocusSignals
 * are left empty because raw session data isn't synced to Android.
 */
object InsightDigestBuilder {

    private const val MAX_ENCODED_BYTES = InsightDigest.MAX_ENCODED_BYTES
    private const val HASH_ALGORITHM = "SHA-256"

    /**
     * Build a digest from available Firestore rollup data.
     * Fields that require local macOS-only data are intentionally empty.
     */
    fun build(
        filter: InsightFilter,
        totals: InsightDigest.Totals,
        providers: List<InsightDigest.ProviderSnapshot>,
        models: List<InsightDigest.ModelSnapshot>,
        projects: List<InsightDigest.ProjectSnapshot>,
        daily: List<InsightDigest.DailyPoint>,
        quotaSnapshots: List<InsightDigest.QuotaSnapshotSummary>,
        anomalies: List<InsightDigest.PrecomputedAnomaly> = emptyList()
    ): InsightDigest {
        val window = filter.window
        val windowInterval = window.toInterval()
        val digest = InsightDigest(
            contentHash = "",
            generatedAt = java.time.Instant.now().toString(),
            windowStart = windowInterval.first,
            windowEnd = windowInterval.second,
            rowCount = totals.sessionCount,
            totals = totals,
            providers = providers,
            models = models,
            projects = projects,
            devices = emptyList(), // Android doesn't sync device data
            daily = daily,
            hourly = computeHourly(daily),
            useCaseHistogram = emptyList(), // Requires local macOS session data
            agentFocusSignals = emptyList(), // Requires local macOS session data
            modelFocusSignals = emptyList(), // Requires local macOS session data
            quotaSnapshots = quotaSnapshots,
            operatingActions = emptyList(), // macOS-only
            summaryRunsLog = emptyList(), // macOS-only
            anomalies = anomalies,
            glossary = InsightTaxonomy.DEFAULT
        )

        val encodedSize = kotlinx.serialization.json.Json.encodeToString(
            kotlinx.serialization.serializer<InsightDigest>(), digest
        ).toByteArray(Charsets.UTF_8).size

        check(encodedSize <= MAX_ENCODED_BYTES) {
            "InsightDigest ($encodedSize bytes) exceeds the $MAX_ENCODED_BYTES byte ceiling"
        }

        return digest.copy(contentHash = sha256Hex(kotlinx.serialization.json.Json.encodeToString(
            kotlinx.serialization.serializer<InsightDigest>(), digest
        )))
    }

    private fun computeHourly(daily: List<InsightDigest.DailyPoint>): List<Int> {
        val buckets = MutableList(24) { 0 }
        for (point in daily) {
            val hourEstimate = (point.sessionCount / 24.0).toInt().coerceAtLeast(0)
            for (h in 0 until 24) { buckets[h] += hourEstimate }
        }
        return buckets
    }

    private fun sha256Hex(input: String): String {
        val digest = MessageDigest.getInstance(HASH_ALGORITHM)
        val hash = digest.digest(input.toByteArray(Charsets.UTF_8))
        return hash.joinToString("") { "%02x".format(it) }
    }

    private fun InsightTimeWindow.toInterval(): Pair<String, String> {
        val now = java.time.Instant.now()
        val start: java.time.Instant = when (this) {
            is InsightTimeWindow.Today -> now.minus(java.time.Duration.ofDays(1))
            is InsightTimeWindow.Last24h -> now.minus(java.time.Duration.ofHours(24))
            is InsightTimeWindow.Last7d -> now.minus(java.time.Duration.ofDays(7))
            is InsightTimeWindow.Last30d -> now.minus(java.time.Duration.ofDays(30))
            is InsightTimeWindow.Last90d -> now.minus(java.time.Duration.ofDays(90))
            is InsightTimeWindow.Last365d -> now.minus(java.time.Duration.ofDays(365))
            is InsightTimeWindow.AllTime -> java.time.Instant.EPOCH
            is InsightTimeWindow.Custom -> return this.start to this.end
        }
        return start.toString() to now.toString()
    }
}
