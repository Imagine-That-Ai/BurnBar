package com.openburnbar.data.derived

import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.LLMModelBrand
import com.openburnbar.data.models.RollupSummary
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.data.models.UsageRollups
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.max

internal object TrendDigestConstants {
    const val DEFAULT_SEMANTIC_HASH_LIMIT = 24
    const val PERCENT_SCALE = 1_000_000_000
    const val PERCENT_SCALE_DOUBLE = 1_000_000_000.0
    const val PERCENT_SCALE_MILLION = 1_000_000
    const val MIN_COST_DELTA_USD = 0.01
    const val CACHE_RATE_HIGH_THRESHOLD = 0.5
    const val CACHE_RATE_LOW_THRESHOLD = 0.25
    const val SAVINGS_COST_FACTOR = 0.9
    const val AVG_INPUT_COST_USD_PER_MILLION_TOKENS = 3.0
    const val PROVIDER_SHARE_DOMINANT_THRESHOLD = 50.0
    const val WEEK_OVER_WEEK_ALERT_THRESHOLD_PERCENT = 5.0
    const val HIGH_TOKEN_VOLUME_THRESHOLD = 100_000
    const val MIN_SESSION_DURATION_SECONDS = 5.0
    const val HOURS_PER_DAY = 24
    const val SECONDS_PER_MINUTE = 60
    const val MILLIS_PER_SECOND = 1000L
    const val MAX_HOUR_OF_DAY = 23
    const val ROLLING_WINDOW_DAYS = 7.0
}

/**
 * Compact, immutable analytics snapshot consumed by the Trend Atlas card and
 * insight rotator. Pure-Kotlin port of the iOS `TrendDataDigest` — same shape,
 * same caps, computed locally from the data already on the device so no
 * Firestore schema work is needed.
 */
data class TrendDataDigest(
    val displayMode: UsageDisplayMode,
    val generatedAtMs: Long,
    val windowDescription: String,
    val totals: List<WindowTotals>,
    val providers: List<ProviderSlice>,
    val models: List<ModelSlice>,
    val projects: List<ProjectSlice>,
    val devices: List<DeviceSlice>,
    val daily: List<DailySeries>,
    val hourly: List<HourBucket>,
    val recentSessions: List<SessionSlice>,
    val cache: CacheAggregate,
) {
    data class WindowTotals(
        // "today" | "7d" | "30d"
        val window: String,
        val costUsd: Double,
        val tokens: Long,
        val requests: Int,
    )

    data class ProviderSlice(
        // display name
        val provider: String,
        // raw persisted token
        val providerKey: String,
        val costUsd: Double,
        val tokens: Long,
        val requests: Int,
        // 0..100
        val sharePct: Double,
    )

    data class ModelSlice(
        val model: String,
        val provider: String,
        val providerKey: String,
        val brand: LLMModelBrand,
        val costUsd: Double,
        val tokens: Long,
        val requests: Int,
        val sharePct: Double,
    )

    data class ProjectSlice(
        val project: String,
        val costUsd: Double,
        val tokens: Long,
        val sessions: Int,
    )

    data class DeviceSlice(
        val device: String,
        val tokens: Long,
        val requests: Int,
    )

    data class DailySeries(
        // ISO yyyy-MM-dd
        val date: String,
        val total: Double,
        // providerKey → cost
        val perProvider: Map<String, Double>,
    )

    data class HourBucket(
        // 0..23
        val hour: Int,
        val costUsd: Double,
        val tokens: Long,
    )

    data class SessionSlice(
        val id: String,
        val startedAtMs: Long,
        val durationSec: Int,
        val provider: String,
        val providerKey: String,
        val model: String,
        val project: String,
        val inputTokens: Int,
        val outputTokens: Int,
        val cacheReadTokens: Int,
        val cacheCreationTokens: Int,
        val reasoningTokens: Int,
        val costUsd: Double,
        // 0..1
        val cacheHitRate: Double,
        val outputTokensPerSecond: Double,
    )

    data class CacheAggregate(
        val totalCacheReadTokens: Long,
        val totalCacheCreationTokens: Long,
        val totalInputTokens: Long,
        // 0..1 across window
        val cacheHitRate: Double,
        val estSavingsUsd: Double,
    )

    companion object {
        private const val MAX_DAILY_DAYS = 21
        private const val MAX_HOURLY_LOOKBACK_DAYS = 14
        private const val MAX_PROVIDERS = 6
        private const val MAX_MODELS = 8
        private const val MAX_PROJECTS = 5
        private const val MAX_DEVICES = 4
        private const val MAX_SESSIONS = 15
        private const val MAX_PROVIDERS_PER_DAY = 4

        /**
         * Build the digest from the raw streams already flowing into Pulse.
         * `recentUsages` should be sorted desc by timestamp — we never order
         * them ourselves so the caller's existing pagination semantics win.
         */
        fun build(
            rollups: UsageRollups,
            recentUsages: List<TokenUsage>,
            displayMode: UsageDisplayMode = UsageDisplayMode.CURRENCY,
            windowDescription: String = "last 30 days",
            now: Date = Date(),
        ): TrendDataDigest {
            val totals =
                listOf(
                    WindowTotals(
                        window = "today",
                        costUsd = rollups.today,
                        tokens = rollups.todayTokens,
                        requests = countRequests(recentUsages, withinDays = 1, now = now),
                    ),
                    WindowTotals(
                        window = "7d",
                        costUsd = rollups.sevenDays,
                        tokens = rollups.sevenDayTokens,
                        requests = countRequests(recentUsages, withinDays = 7, now = now),
                    ),
                    WindowTotals(
                        window = "30d",
                        costUsd = rollups.thirtyDays,
                        tokens = rollups.thirtyDayTokens,
                        requests = countRequests(recentUsages, withinDays = 30, now = now),
                    ),
                )

            val providers = buildProviders(rollups.providerSummaries)
            val models = buildModels(rollups.modelSummaries)
            val projects = buildProjects(recentUsages)
            val devices = buildDevices(recentUsages)
            val daily = buildDailySeries(rollups.dailyPoints, recentUsages)
            val hourly = buildHourly(recentUsages, now)
            val sessions = buildSessions(recentUsages)
            val cache = trendDigestBuildCache(recentUsages)

            return TrendDataDigest(
                displayMode = displayMode,
                generatedAtMs = now.time,
                windowDescription = windowDescription,
                totals = totals,
                providers = providers,
                models = models,
                projects = projects,
                devices = devices,
                daily = daily,
                hourly = hourly,
                recentSessions = sessions,
                cache = cache,
            )
        }

        // ── Builders ──

        private fun countRequests(usages: List<TokenUsage>, withinDays: Int, now: Date): Int {
            val cutoff =
                now.time -
                    withinDays.toLong() *
                    TrendDigestConstants.HOURS_PER_DAY *
                    TrendDigestConstants.SECONDS_PER_MINUTE *
                    TrendDigestConstants.SECONDS_PER_MINUTE *
                    TrendDigestConstants.MILLIS_PER_SECOND
            return usages.count { it.timestamp >= cutoff }
        }

        private fun buildProviders(summaries: List<RollupSummary>): List<ProviderSlice> {
            // Collapse summaries by provider so duplicate account rows fold
            // together — the per-account view lives elsewhere.
            val byProvider =
                summaries.groupBy { it.provider }
                    .map { (key, group) ->
                        RollupSummary(
                            provider = key,
                            providerId = group.first().providerId,
                            accountLabel = "",
                            totalRequests = group.sumOf { it.totalRequests },
                            totalTokens = group.sumOf { it.totalTokens },
                            totalCost = group.sumOf { it.totalCost },
                        )
                    }
                    .sortedByDescending { it.totalCost }

            val total = byProvider.sumOf { it.totalTokens }.toDouble().coerceAtLeast(1.0)
            return byProvider.take(MAX_PROVIDERS).map { p ->
                val agent = AgentProvider.fromKey(p.provider)
                ProviderSlice(
                    provider = agent?.displayName ?: p.provider,
                    providerKey = agent?.key ?: p.provider,
                    costUsd = p.totalCost,
                    tokens = p.totalTokens,
                    requests = p.totalRequests,
                    sharePct = p.totalTokens.toDouble() / total * 100.0,
                )
            }
        }

        private fun buildModels(summaries: List<RollupSummary>): List<ModelSlice> {
            val total = summaries.sumOf { it.totalTokens }.toDouble().coerceAtLeast(1.0)
            // RollupSummary doesn't carry the model name as its own field — it
            // lives in `accountLabel` for model summaries (mirrors iOS where
            // ModelSlice flattens through the same RollupSummary struct).
            return summaries
                .sortedByDescending { it.totalCost }
                .take(MAX_MODELS)
                .map { m ->
                    val modelName = m.accountLabel.ifBlank { m.provider }
                    ModelSlice(
                        model = modelName,
                        provider = AgentProvider.fromKey(m.provider)?.displayName ?: m.provider,
                        providerKey = m.provider,
                        brand = LLMModelBrand.infer(modelName),
                        costUsd = m.totalCost,
                        tokens = m.totalTokens,
                        requests = m.totalRequests,
                        sharePct = m.totalTokens.toDouble() / total * 100.0,
                    )
                }
        }

        private fun buildProjects(usages: List<TokenUsage>): List<ProjectSlice> {
            return usages
                .mapNotNull { usage ->
                    usage.projectName?.takeIf { it.isNotBlank() }?.let { projectName -> projectName to usage }
                }
                .groupBy(keySelector = { it.first }, valueTransform = { it.second })
                .map { (project, list) ->
                    ProjectSlice(
                        project = project,
                        costUsd = list.sumOf { it.effectiveCost },
                        tokens = list.sumOf { it.totalTokens.toLong() },
                        sessions = list.distinctBy { it.sessionId ?: it.id }.size,
                    )
                }
                .sortedByDescending { it.costUsd }
                .take(MAX_PROJECTS)
        }

        private fun buildDevices(usages: List<TokenUsage>): List<DeviceSlice> {
            return usages
                .mapNotNull { usage ->
                    val deviceId =
                        usage.deviceId?.takeIf { it.isNotBlank() }
                            ?: usage.sourceDeviceId?.takeIf { it.isNotBlank() }
                    deviceId?.let { it to usage }
                }
                .groupBy(keySelector = { it.first }, valueTransform = { it.second })
                .map { (device, list) ->
                    DeviceSlice(
                        device = device,
                        tokens = list.sumOf { it.totalTokens.toLong() },
                        requests = list.size,
                    )
                }
                .sortedByDescending { it.tokens }
                .take(MAX_DEVICES)
        }

        private fun buildDailySeries(dailyPoints: Map<String, Double>, usages: List<TokenUsage>): List<DailySeries> {
            // Group usages by day-of-timestamp in user's local TZ so the
            // x-axis lines up with what the user sees on the calendar.
            val cal = Calendar.getInstance()
            val dayKey: (Long) -> String = { ms ->
                cal.time = Date(ms)
                cal.set(Calendar.HOUR_OF_DAY, 0)
                cal.set(Calendar.MINUTE, 0)
                cal.set(Calendar.SECOND, 0)
                cal.set(Calendar.MILLISECOND, 0)
                ISO_DAY.format(cal.time)
            }

            val perDayProviderTotals = mutableMapOf<String, MutableMap<String, Double>>()
            for (u in usages) {
                val date = dayKey(u.timestamp)
                val providerKey = AgentProvider.fromKey(u.provider)?.key ?: u.provider
                val bucket = perDayProviderTotals.getOrPut(date) { mutableMapOf() }
                bucket.merge(providerKey, u.effectiveCost) { a, b -> a + b }
            }

            // Union all day keys from dailyPoints (server-side totals) AND
            // any days we found locally. dailyPoints supplies fallback totals
            // for days that aren't in the recent-usages window.
            val allDays =
                (dailyPoints.keys + perDayProviderTotals.keys)
                    .toSortedSet()
                    .toList()
                    .takeLast(MAX_DAILY_DAYS)

            return allDays.map { date ->
                val perProvider = perDayProviderTotals[date] ?: emptyMap()
                // Keep only the top providers per day so the JSON / stacks
                // don't explode when a user has 10+ active providers.
                val topPerProvider =
                    perProvider.entries
                        .sortedByDescending { it.value }
                        .take(MAX_PROVIDERS_PER_DAY)
                        .associate { it.key to it.value }

                val computedTotal = topPerProvider.values.sum()
                val total = dailyPoints[date] ?: computedTotal
                DailySeries(
                    date = date,
                    total = max(total, computedTotal),
                    perProvider = topPerProvider,
                )
            }
        }

        private fun buildHourly(usages: List<TokenUsage>, now: Date): List<HourBucket> {
            val cutoff =
                now.time -
                    MAX_HOURLY_LOOKBACK_DAYS.toLong() *
                    TrendDigestConstants.HOURS_PER_DAY *
                    TrendDigestConstants.SECONDS_PER_MINUTE *
                    TrendDigestConstants.SECONDS_PER_MINUTE *
                    TrendDigestConstants.MILLIS_PER_SECOND
            val cal = Calendar.getInstance()
            val buckets = LongArray(TrendDigestConstants.DEFAULT_SEMANTIC_HASH_LIMIT)
            val costs = DoubleArray(TrendDigestConstants.DEFAULT_SEMANTIC_HASH_LIMIT)
            for (u in usages) {
                if (u.timestamp < cutoff) continue
                cal.time = Date(u.timestamp)
                val h = cal.get(Calendar.HOUR_OF_DAY).coerceIn(0, TrendDigestConstants.MAX_HOUR_OF_DAY)
                buckets[h] = buckets[h] + u.totalTokens
                costs[h] = costs[h] + u.effectiveCost
            }
            return (0..TrendDigestConstants.MAX_HOUR_OF_DAY).map { h ->
                HourBucket(hour = h, costUsd = costs[h], tokens = buckets[h])
            }
        }

        private fun buildSessions(usages: List<TokenUsage>): List<SessionSlice> {
            return usages.take(MAX_SESSIONS).map { u ->
                val duration = ((u.endTime - u.startTime).coerceAtLeast(0) / 1000L).toInt()
                val cacheTotal = u.cacheReadTokens + u.cacheCreationTokens
                val hitRate =
                    if (cacheTotal > 0) {
                        u.cacheReadTokens.toDouble() / cacheTotal.toDouble()
                    } else {
                        0.0
                    }
                val velocity = if (duration > 0) u.outputTokens.toDouble() / duration else 0.0

                SessionSlice(
                    id = u.id.ifBlank { u.sessionId.orEmpty() },
                    startedAtMs = if (u.startTime > 0) u.startTime else u.timestamp,
                    durationSec = duration,
                    provider = AgentProvider.fromKey(u.provider)?.displayName ?: u.provider,
                    providerKey = AgentProvider.fromKey(u.provider)?.key ?: u.provider,
                    model = u.model.orEmpty(),
                    project = u.projectName.orEmpty(),
                    inputTokens = u.inputTokens,
                    outputTokens = u.outputTokens,
                    cacheReadTokens = u.cacheReadTokens,
                    cacheCreationTokens = u.cacheCreationTokens,
                    reasoningTokens = u.reasoningTokens,
                    costUsd = u.effectiveCost,
                    cacheHitRate = hitRate,
                    outputTokensPerSecond = velocity,
                )
            }
        }

        private val ISO_DAY: SimpleDateFormat =
            SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
                timeZone = TimeZone.getDefault()
            }
    }
}

/** Sentiment tone surfaced by the insight engine. */
enum class TrendInsightTone { POSITIVE, NEUTRAL, WARNING }

/** A single ranked insight rendered by `InsightAutoRotator`. */
data class TrendInsight(
    val id: String,
    val title: String,
    val detail: String,
    val tone: TrendInsightTone,
    /** Material symbol name (Compose `Icons.Filled.X` lookup happens at render time). */
    val symbolName: String,
    val rank: Int,
)

/**
 * Deterministic, stateless rules engine that translates a `TrendDataDigest`
 * into a ranked list of `TrendInsight`s. Ports the iOS
 * `TrendInsightEngine` — same intent, idiomatic Kotlin output.
 */
object TrendInsightEngine {
    fun insights(digest: TrendDataDigest): List<TrendInsight> {
        val today = digest.totals.firstOrNull { it.window == "today" }
        val sevenDay = digest.totals.firstOrNull { it.window == "7d" }
        val thirtyDay = digest.totals.firstOrNull { it.window == "30d" }
        val out = mutableListOf<TrendInsight>()
        trendSpendVelocityInsight(today, sevenDay)?.let { out += it }
        trendProviderConcentrationInsight(digest)?.let { out += it }
        out += trendCacheInsights(digest)
        trendPeakHourInsight(digest)?.let { out += it }
        trendVelocityChampionInsight(digest)?.let { out += it }
        trendLongTailVolumeInsight(thirtyDay)?.let { out += it }
        return out.sortedByDescending { it.rank }
    }
}
