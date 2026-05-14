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
        modelBenchmarks: List<InsightDigest.ModelBenchmarkSummary> = emptyList(),
        anomalies: List<InsightDigest.PrecomputedAnomaly> = emptyList()
    ): InsightDigest {
        val window = filter.window
        val windowInterval = window.toInterval()
        val baseDigest = InsightDigest(
            contentHash = "",
            generatedAt = java.time.Instant.now().toString(),
            windowStart = windowInterval.first,
            windowEnd = windowInterval.second,
            rowCount = totals.sessionCount,
            totals = totals,
            providers = providers.sortedByDescending { it.costUSD }.take(12),
            models = models.sortedByDescending { it.costUSD }.take(16),
            projects = projects,
            devices = emptyList(), // Android doesn't sync device data
            daily = daily.takeLast(90),
            hourly = computeHourly(daily),
            useCaseHistogram = emptyList(), // Requires local macOS session data
            agentFocusSignals = emptyList(), // Requires local macOS session data
            modelFocusSignals = emptyList(), // Requires local macOS session data
            quotaSnapshots = quotaSnapshots.take(16),
            operatingActions = emptyList(), // macOS-only
            summaryRunsLog = emptyList(), // macOS-only
            modelBenchmarks = modelBenchmarks
                .filter { it.score != null || it.rank != null || it.costSignal != null }
                .sortedWith(compareByDescending<InsightDigest.ModelBenchmarkSummary> { it.score ?: -1.0 }
                    .thenBy { it.rank ?: Int.MAX_VALUE }
                    .thenBy { it.modelID })
                .take(36),
            anomalies = anomalies,
            glossary = InsightTaxonomy.DEFAULT
        )

        val digest = shrinkToBudget(baseDigest)

        return digest.copy(contentHash = sha256Hex(kotlinx.serialization.json.Json.encodeToString(
            kotlinx.serialization.serializer<InsightDigest>(), digest
        )))
    }

    private fun shrinkToBudget(digest: InsightDigest): InsightDigest {
        fun encodedSize(value: InsightDigest): Int = kotlinx.serialization.json.Json.encodeToString(
            kotlinx.serialization.serializer<InsightDigest>(), value
        ).toByteArray(Charsets.UTF_8).size

        var candidate = digest
        if (encodedSize(candidate) <= MAX_ENCODED_BYTES) return candidate

        val dailyLimits = listOf(60, 45, 30, 14, 7)
        val providerLimits = listOf(10, 8, 6, 4)
        val modelLimits = listOf(12, 10, 8, 6, 4)
        val quotaLimits = listOf(12, 8, 4, 0)

        for (dailyLimit in dailyLimits) {
            for (providerLimit in providerLimits) {
                for (modelLimit in modelLimits) {
                    for (quotaLimit in quotaLimits) {
                        candidate = digest.copy(
                            providers = digest.providers.take(providerLimit),
                            models = digest.models.take(modelLimit),
                            daily = digest.daily.takeLast(dailyLimit),
                            hourly = computeHourly(digest.daily.takeLast(dailyLimit)),
                            quotaSnapshots = digest.quotaSnapshots.take(quotaLimit),
                            modelBenchmarks = digest.modelBenchmarks.take(18),
                            anomalies = digest.anomalies.take(6)
                        )
                        if (encodedSize(candidate) <= MAX_ENCODED_BYTES) return candidate
                    }
                }
            }
        }

        candidate = digest.copy(
            providers = digest.providers.take(3),
            models = digest.models.take(3),
            projects = emptyList(),
            devices = emptyList(),
            daily = digest.daily.takeLast(7),
            hourly = computeHourly(digest.daily.takeLast(7)),
            quotaSnapshots = emptyList(),
            modelBenchmarks = digest.modelBenchmarks.take(6),
            anomalies = emptyList(),
            glossary = InsightTaxonomy()
        )

        check(encodedSize(candidate) <= MAX_ENCODED_BYTES) {
            "InsightDigest could not be reduced below the $MAX_ENCODED_BYTES byte ceiling"
        }
        return candidate
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
