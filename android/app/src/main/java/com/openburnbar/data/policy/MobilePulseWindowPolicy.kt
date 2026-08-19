package com.openburnbar.data.policy

import java.util.Calendar
import java.util.Locale
import java.util.TimeZone
import kotlin.math.max

/**
 * Pulse timeline scopes. Source oracle:
 * `PulseWindowMetricBuilder` in
 * `OpenBurnBarMobile/Views/Pulse/PulseWindowMetrics.swift`.
 */
enum class MobilePulseTimelineScope {
    MINUTE,
    HOUR,
    DAY,
    WEEK,
    MONTH,
}

data class MobilePulseUsageEvent(
    val startMs: Long,
    val endMs: Long,
    val tokens: Long,
    val costUsd: Double,
) {
    /** iOS oracle: `max(startTime, endTime)`. Sync `updatedAt` is not an event time. */
    val eventDateMs: Long get() = max(startMs, endMs)
}

data class MobilePulseRollupTotals(
    val requests: Int,
    val tokens: Long,
    val costUsd: Double,
) {
    companion object {
        val ZERO = MobilePulseRollupTotals(0, 0, 0.0)
    }
}

data class MobilePulseWindowResult(
    val total: MobilePulseRollupTotals,
    val trailing: MobilePulseRollupTotals?,
)

enum class MobilePulseLoadPresentation(val wire: String) {
    LOADING("loading"),
    FAILED("failed"),
    EMPTY("empty"),
    LIVE("live"),
    STALE_REFRESH_FAILED("stale-refresh-failed"),
    ;

    val looksLikeLiveZero: Boolean get() = this == LIVE
}

/** Shared Pulse/Burn window math. Authority: iOS `PulseWindowMetricBuilder`. */
object MobilePulseWindowPolicy {
    const val DAY_WINDOW_MS: Long = 24L * 60L * 60L * 1_000L
    const val HOUR_WINDOW_MS: Long = 60L * 60L * 1_000L
    const val MINUTE_WINDOW_MS: Long = 60L * 1_000L
    private const val COST_ZERO_EPSILON = 1e-9
    private const val COST_CENT_THRESHOLD = 0.01
    private const val TOKEN_BILLION = 1_000_000_000
    private const val TOKEN_MILLION = 1_000_000
    private const val TOKEN_THOUSAND = 1_000

    fun metrics(
        scope: MobilePulseTimelineScope,
        rollups: Map<String, MobilePulseRollupTotals>,
        usages: List<MobilePulseUsageEvent>,
        nowMs: Long,
    ): MobilePulseWindowResult = when (scope) {
        MobilePulseTimelineScope.MINUTE ->
            liveMetrics(usages, nowMs - MINUTE_WINDOW_MS, nowMs, rollups["7d"])
        MobilePulseTimelineScope.HOUR ->
            liveMetrics(usages, nowMs - HOUR_WINDOW_MS, nowMs, rollups["7d"])
        MobilePulseTimelineScope.DAY ->
            liveMetrics(usages, nowMs - DAY_WINDOW_MS, nowMs, rollups["7d"])
        MobilePulseTimelineScope.WEEK ->
            MobilePulseWindowResult(rollups["7d"] ?: MobilePulseRollupTotals.ZERO, rollups["30d"])
        MobilePulseTimelineScope.MONTH ->
            MobilePulseWindowResult(rollups["30d"] ?: MobilePulseRollupTotals.ZERO, rollups["90d"])
    }

    fun liveQueryStartMs(nowMs: Long, timeZoneIdentifier: String): Long {
        val tz =
            if (timeZoneIdentifier.isBlank()) {
                TimeZone.getTimeZone("GMT")
            } else {
                TimeZone.getTimeZone(timeZoneIdentifier)
            }
        val calendar = Calendar.getInstance(tz)
        calendar.timeInMillis = nowMs - DAY_WINDOW_MS
        calendar.set(Calendar.MINUTE, 0)
        calendar.set(Calendar.SECOND, 0)
        calendar.set(Calendar.MILLISECOND, 0)
        return calendar.timeInMillis
    }

    fun loadPresentation(isLoading: Boolean, failed: Boolean, hasCachedData: Boolean): MobilePulseLoadPresentation = when {
        isLoading && !hasCachedData -> MobilePulseLoadPresentation.LOADING
        failed && hasCachedData -> MobilePulseLoadPresentation.STALE_REFRESH_FAILED
        failed -> MobilePulseLoadPresentation.FAILED
        !hasCachedData -> MobilePulseLoadPresentation.EMPTY
        else -> MobilePulseLoadPresentation.LIVE
    }

    fun currencyHero(costUsd: Double): String = formatAsCost(max(0.0, costUsd))

    fun tokensHero(tokens: Long): String = formatAsTokenVolume(max(0L, tokens))

    fun quotaDedupKey(provider: String, accountId: String?, accountLabel: String?): String {
        val providerKey = provider.lowercase()
        val accountKey =
            accountId?.trim()?.takeIf { it.isNotEmpty() }
                ?: accountLabel?.trim()?.takeIf { it.isNotEmpty() }
                ?: "provider-level"
        return "$providerKey::${accountKey.lowercase()}"
    }

    fun sortQuotaKeys(keys: List<String>): List<String> = keys.sortedWith(String.CASE_INSENSITIVE_ORDER)

    fun pulseCost(costUsd: Double, costUSD: Double, cost: Double): Double {
        val raw = sequenceOf(costUsd, costUSD, cost).firstOrNull { it != 0.0 } ?: 0.0
        return max(0.0, raw)
    }

    fun pulseTokens(totalTokens: Int, inputTokens: Int, outputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int, reasoningTokens: Int): Long {
        val billed =
            max(0, inputTokens).toLong() + max(0, outputTokens) + max(0, cacheCreationTokens) +
                max(0, cacheReadTokens) + max(0, reasoningTokens)
        val raw = if (totalTokens != 0) totalTokens.toLong() else billed
        return max(0L, raw)
    }

    private fun liveMetrics(usages: List<MobilePulseUsageEvent>, startMs: Long, endMs: Long, trailing: MobilePulseRollupTotals?): MobilePulseWindowResult {
        val rows = usages.filter { it.eventDateMs in startMs..endMs }
        return MobilePulseWindowResult(
            total = MobilePulseRollupTotals(
                requests = rows.size,
                tokens = rows.sumOf { max(0L, it.tokens) },
                costUsd = rows.sumOf { max(0.0, it.costUsd) },
            ),
            trailing = trailing,
        )
    }

    private fun formatAsCost(value: Double): String {
        if (value < COST_ZERO_EPSILON) return "$0.00"
        return if (value < COST_CENT_THRESHOLD) {
            "$" + "%.4f".format(Locale.US, value)
        } else {
            "$" + "%.2f".format(Locale.US, value)
        }
    }

    private fun formatAsTokenVolume(tokens: Long): String {
        val magnitude = tokens.toDouble()
        return when {
            tokens >= TOKEN_BILLION -> "%.2fB".format(Locale.US, magnitude / TOKEN_BILLION)
            tokens >= TOKEN_MILLION -> "%.2fM".format(Locale.US, magnitude / TOKEN_MILLION)
            tokens >= TOKEN_THOUSAND -> "%.1fK".format(Locale.US, magnitude / TOKEN_THOUSAND)
            else -> tokens.toString()
        }
    }
}
