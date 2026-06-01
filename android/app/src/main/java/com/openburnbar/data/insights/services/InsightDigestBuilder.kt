package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightTaxonomy
import com.openburnbar.data.insights.InsightTimeWindow
import java.security.MessageDigest

/**
 * Builds a privacy-bounded InsightDigest from Firestore rollups on Android.
 * Mirrors the Swift InsightDigestBuilder with the same 24KB ceiling.
 *
 * Android-specific note: useCaseHistogram, agentFocusSignals, and modelFocusSignals
 * are left empty because raw session data isn't synced to Android.
 */
data class InsightDigestBuildInput(
    val filter: InsightFilter,
    val totals: InsightDigest.Totals,
    val providers: List<InsightDigest.ProviderSnapshot>,
    val models: List<InsightDigest.ModelSnapshot>,
    val projects: List<InsightDigest.ProjectSnapshot>,
    val daily: List<InsightDigest.DailyPoint>,
    val quotaSnapshots: List<InsightDigest.QuotaSnapshotSummary>,
    val modelBenchmarks: List<InsightDigest.ModelBenchmarkSummary> = emptyList(),
    val anomalies: List<InsightDigest.PrecomputedAnomaly> = emptyList(),
)

object InsightDigestBuilder {
    private const val VAL_10 = 10
    private const val VAL_12 = 12
    private const val VAL_14 = 14
    private const val VAL_16 = 16
    private const val VAL_18 = 18
    private const val VAL_24 = 24
    private const val VAL_24_0 = 24.0
    private const val VAL_3 = 3
    private const val VAL_30 = 30
    private const val VAL_36 = 36
    private const val VAL_365 = 365
    private const val VAL_4 = 4
    private const val VAL_45 = 45
    private const val VAL_6 = 6
    private const val VAL_60 = 60
    private const val VAL_7 = 7
    private const val VAL_8 = 8
    private const val VAL_90 = 90
    private const val MAX_ENCODED_BYTES = InsightDigest.MAX_ENCODED_BYTES
    private const val HASH_ALGORITHM = "SHA-256"

    /**
     * Build a digest from available Firestore rollup data.
     * Fields that require local macOS-only data are intentionally empty.
     */
    fun build(input: InsightDigestBuildInput): InsightDigest {
        val filter = input.filter
        val totals = input.totals
        val providers = input.providers
        val models = input.models
        val projects = input.projects
        val daily = input.daily
        val quotaSnapshots = input.quotaSnapshots
        val modelBenchmarks = input.modelBenchmarks
        val anomalies = input.anomalies
        val window = filter.window
        val windowInterval = window.toInterval()
        val baseDigest =
            InsightDigest(
                contentHash = "",
                generatedAt = java.time.Instant.now().toString(),
                windowStart = windowInterval.first,
                windowEnd = windowInterval.second,
                rowCount = totals.sessionCount,
                totals = totals,
                providers = providers.sortedByDescending { it.costUSD }.take(VAL_12),
                models = models.sortedByDescending { it.costUSD }.take(VAL_16),
                projects = projects,
                devices = emptyList(), // Android doesn't sync device data
                daily = daily.takeLast(VAL_90),
                hourly = computeHourly(daily),
                useCaseHistogram = emptyList(), // Requires local macOS session data
                agentFocusSignals = emptyList(), // Requires local macOS session data
                modelFocusSignals = emptyList(), // Requires local macOS session data
                quotaSnapshots = quotaSnapshots.take(VAL_16),
                operatingActions = emptyList(), // macOS-only
                summaryRunsLog = emptyList(), // macOS-only
                modelBenchmarks =
                modelBenchmarks
                    .filter { it.score != null || it.rank != null || it.costSignal != null }
                    .sortedWith(
                        compareByDescending<InsightDigest.ModelBenchmarkSummary> { it.score ?: -1.0 }
                            .thenBy { it.rank ?: Int.MAX_VALUE }
                            .thenBy { it.modelID },
                    )
                    .take(VAL_36),
                anomalies = anomalies,
                glossary = InsightTaxonomy.DEFAULT,
            )

        val digest = shrinkToBudget(baseDigest)

        return digest.copy(
            contentHash =
            sha256Hex(
                kotlinx.serialization.json.Json.encodeToString(
                    kotlinx.serialization.serializer<InsightDigest>(),
                    digest,
                ),
            ),
        )
    }

    private fun encodedSize(value: InsightDigest): Int = kotlinx.serialization.json.Json.encodeToString(
        kotlinx.serialization.serializer<InsightDigest>(),
        value,
    ).toByteArray(Charsets.UTF_8).size

    private fun shrinkToBudget(digest: InsightDigest): InsightDigest {
        var candidate = digest
        if (encodedSize(candidate) <= MAX_ENCODED_BYTES) return candidate

        val shrunk = shrinkWithProgressiveLimits(digest)
        if (shrunk != null) return shrunk

        candidate =
            digest.copy(
                providers = digest.providers.take(VAL_3),
                models = digest.models.take(VAL_3),
                projects = emptyList(),
                devices = emptyList(),
                daily = digest.daily.takeLast(VAL_7),
                hourly = computeHourly(digest.daily.takeLast(VAL_7)),
                quotaSnapshots = emptyList(),
                modelBenchmarks = digest.modelBenchmarks.take(VAL_6),
                anomalies = emptyList(),
                glossary = InsightTaxonomy(),
            )

        check(encodedSize(candidate) <= MAX_ENCODED_BYTES) {
            "InsightDigest could not be reduced below the $MAX_ENCODED_BYTES byte ceiling"
        }
        return candidate
    }

    private fun shrinkWithProgressiveLimits(digest: InsightDigest): InsightDigest? =
        shrinkLimitCombinations().firstNotNullOfOrNull { limits ->
            val candidate =
                shrunkDigestCandidate(
                    digest = digest,
                    dailyLimit = limits.daily,
                    providerLimit = limits.provider,
                    modelLimit = limits.model,
                    quotaLimit = limits.quota,
                )
            candidate.takeIf { encodedSize(it) <= MAX_ENCODED_BYTES }
        }

    private data class ShrinkLimits(val daily: Int, val provider: Int, val model: Int, val quota: Int)

    private fun shrinkLimitCombinations(): List<ShrinkLimits> {
        val dailyLimits = listOf(VAL_60, VAL_45, VAL_30, VAL_14, VAL_7)
        val providerLimits = listOf(VAL_10, VAL_8, VAL_6, VAL_4)
        val modelLimits = listOf(VAL_12, VAL_10, VAL_8, VAL_6, VAL_4)
        val quotaLimits = listOf(VAL_12, VAL_8, VAL_4, 0)
        return dailyLimits.flatMap { dailyLimit ->
            providerLimits.flatMap { providerLimit ->
                modelLimits.flatMap { modelLimit ->
                    quotaLimits.map { quotaLimit ->
                        ShrinkLimits(dailyLimit, providerLimit, modelLimit, quotaLimit)
                    }
                }
            }
        }
    }

    private fun shrunkDigestCandidate(
        digest: InsightDigest,
        dailyLimit: Int,
        providerLimit: Int,
        modelLimit: Int,
        quotaLimit: Int,
    ): InsightDigest {
        val trimmedDaily = digest.daily.takeLast(dailyLimit)
        return digest.copy(
            providers = digest.providers.take(providerLimit),
            models = digest.models.take(modelLimit),
            daily = trimmedDaily,
            hourly = computeHourly(trimmedDaily),
            quotaSnapshots = digest.quotaSnapshots.take(quotaLimit),
            modelBenchmarks = digest.modelBenchmarks.take(VAL_18),
            anomalies = digest.anomalies.take(VAL_6),
        )
    }

    private fun computeHourly(daily: List<InsightDigest.DailyPoint>): List<Int> {
        val buckets = MutableList(VAL_24) { 0 }
        for (point in daily) {
            val hourEstimate = point.sessionCount / VAL_24_0.toInt().coerceAtLeast(0)
            for (h in 0 until VAL_24) {
                buckets[h] += hourEstimate
            }
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
        val start: java.time.Instant =
            when (this) {
                is InsightTimeWindow.Today -> now.minus(java.time.Duration.ofDays(1))
                is InsightTimeWindow.Last24h -> now.minus(java.time.Duration.ofHours(VAL_24.toLong()))
                is InsightTimeWindow.Last7d -> now.minus(java.time.Duration.ofDays(VAL_7.toLong()))
                is InsightTimeWindow.Last30d -> now.minus(java.time.Duration.ofDays(VAL_30.toLong()))
                is InsightTimeWindow.Last90d -> now.minus(java.time.Duration.ofDays(VAL_90.toLong()))
                is InsightTimeWindow.Last365d -> now.minus(java.time.Duration.ofDays(VAL_365.toLong()))
                is InsightTimeWindow.AllTime -> java.time.Instant.EPOCH
                is InsightTimeWindow.Custom -> return this.start to this.end
            }
        return start.toString() to now.toString()
    }
}
