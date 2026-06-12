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
    // Calendar units shared by window intervals and daily-history caps.
    private const val HOURS_PER_DAY = 24
    private const val HOURS_PER_DAY_DOUBLE = 24.0
    private const val DAYS_PER_WEEK = 7
    private const val DAYS_PER_FORTNIGHT = 14
    private const val DAYS_PER_MONTH = 30
    private const val DAYS_PER_MONTH_AND_HALF = 45
    private const val DAYS_PER_TWO_MONTHS = 60
    private const val DAYS_PER_QUARTER = 90
    private const val DAYS_PER_YEAR = 365

    // Section caps for a full-size digest.
    private const val MAX_PROVIDER_SNAPSHOTS = 12
    private const val MAX_MODEL_SNAPSHOTS = 16
    private const val MAX_QUOTA_SNAPSHOTS = 16
    private const val MAX_MODEL_BENCHMARKS = 36

    // Candidate section caps tried widest-to-narrowest while shrinking to the byte budget.
    private const val SHRINK_CAP_WIDEST = 12
    private const val SHRINK_CAP_WIDE = 10
    private const val SHRINK_CAP_MEDIUM = 8
    private const val SHRINK_CAP_NARROW = 6
    private const val SHRINK_CAP_NARROWEST = 4
    private const val SHRUNK_BENCHMARK_LIMIT = 18
    private const val SHRUNK_ANOMALY_LIMIT = 6

    // Last-resort caps when progressive shrinking still exceeds the budget.
    private const val LAST_RESORT_SNAPSHOT_LIMIT = 3
    private const val LAST_RESORT_BENCHMARK_LIMIT = 6

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
                providers = providers.sortedByDescending { it.costUSD }.take(MAX_PROVIDER_SNAPSHOTS),
                models = models.sortedByDescending { it.costUSD }.take(MAX_MODEL_SNAPSHOTS),
                projects = projects,
                devices = emptyList(), // Android doesn't sync device data
                daily = daily.takeLast(DAYS_PER_QUARTER),
                hourly = computeHourly(daily),
                useCaseHistogram = emptyList(), // Requires local macOS session data
                agentFocusSignals = emptyList(), // Requires local macOS session data
                modelFocusSignals = emptyList(), // Requires local macOS session data
                quotaSnapshots = quotaSnapshots.take(MAX_QUOTA_SNAPSHOTS),
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
                    .take(MAX_MODEL_BENCHMARKS),
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
                providers = digest.providers.take(LAST_RESORT_SNAPSHOT_LIMIT),
                models = digest.models.take(LAST_RESORT_SNAPSHOT_LIMIT),
                projects = emptyList(),
                devices = emptyList(),
                daily = digest.daily.takeLast(DAYS_PER_WEEK),
                hourly = computeHourly(digest.daily.takeLast(DAYS_PER_WEEK)),
                quotaSnapshots = emptyList(),
                modelBenchmarks = digest.modelBenchmarks.take(LAST_RESORT_BENCHMARK_LIMIT),
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
        val dailyLimits = listOf(DAYS_PER_TWO_MONTHS, DAYS_PER_MONTH_AND_HALF, DAYS_PER_MONTH, DAYS_PER_FORTNIGHT, DAYS_PER_WEEK)
        val providerLimits = listOf(SHRINK_CAP_WIDE, SHRINK_CAP_MEDIUM, SHRINK_CAP_NARROW, SHRINK_CAP_NARROWEST)
        val modelLimits = listOf(SHRINK_CAP_WIDEST, SHRINK_CAP_WIDE, SHRINK_CAP_MEDIUM, SHRINK_CAP_NARROW, SHRINK_CAP_NARROWEST)
        val quotaLimits = listOf(SHRINK_CAP_WIDEST, SHRINK_CAP_MEDIUM, SHRINK_CAP_NARROWEST, 0)
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
            modelBenchmarks = digest.modelBenchmarks.take(SHRUNK_BENCHMARK_LIMIT),
            anomalies = digest.anomalies.take(SHRUNK_ANOMALY_LIMIT),
        )
    }

    private fun computeHourly(daily: List<InsightDigest.DailyPoint>): List<Int> {
        val buckets = MutableList(HOURS_PER_DAY) { 0 }
        for (point in daily) {
            val hourEstimate = point.sessionCount / HOURS_PER_DAY_DOUBLE.toInt().coerceAtLeast(0)
            for (h in 0 until HOURS_PER_DAY) {
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
                is InsightTimeWindow.Last24h -> now.minus(java.time.Duration.ofHours(HOURS_PER_DAY.toLong()))
                is InsightTimeWindow.Last7d -> now.minus(java.time.Duration.ofDays(DAYS_PER_WEEK.toLong()))
                is InsightTimeWindow.Last30d -> now.minus(java.time.Duration.ofDays(DAYS_PER_MONTH.toLong()))
                is InsightTimeWindow.Last90d -> now.minus(java.time.Duration.ofDays(DAYS_PER_QUARTER.toLong()))
                is InsightTimeWindow.Last365d -> now.minus(java.time.Duration.ofDays(DAYS_PER_YEAR.toLong()))
                is InsightTimeWindow.AllTime -> java.time.Instant.EPOCH
                is InsightTimeWindow.Custom -> return this.start to this.end
            }
        return start.toString() to now.toString()
    }
}
