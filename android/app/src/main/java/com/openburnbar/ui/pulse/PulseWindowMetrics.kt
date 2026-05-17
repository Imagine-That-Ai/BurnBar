package com.openburnbar.ui.pulse

import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import java.time.Instant
import java.time.ZoneId

data class PulseWindowMetrics(
    val value: Double,
    val trailingValue: Double,
    val tokenValue: Long,
    val trailingTokenValue: Long,
    val requestValue: Int
)

fun pulseWindowMetrics(
    scope: PulseTimelineScope,
    rollups: UsageRollups,
    recentUsages: List<TokenUsage>,
    nowMillis: Long = System.currentTimeMillis(),
    zoneId: ZoneId = ZoneId.systemDefault()
): PulseWindowMetrics {
    return when (scope) {
        PulseTimelineScope.MINUTE -> usageMetricsForWindow(
            recentUsages = recentUsages,
            cutoffMillis = nowMillis - 60_000L,
            nowMillis = nowMillis,
            trailingValue = rollups.sevenDays,
            trailingTokenValue = rollups.sevenDayTokens
        )
        PulseTimelineScope.HOUR -> usageMetricsForWindow(
            recentUsages = recentUsages,
            cutoffMillis = nowMillis - 60L * 60L * 1_000L,
            nowMillis = nowMillis,
            trailingValue = rollups.sevenDays,
            trailingTokenValue = rollups.sevenDayTokens
        )
        PulseTimelineScope.DAY -> usageMetricsForWindow(
            recentUsages = recentUsages,
            cutoffMillis = nowMillis - DAY_WINDOW_MILLIS,
            nowMillis = nowMillis,
            trailingValue = rollups.sevenDays,
            trailingTokenValue = rollups.sevenDayTokens
        )
        PulseTimelineScope.WEEK -> PulseWindowMetrics(
            value = rollups.sevenDays,
            trailingValue = rollups.thirtyDays,
            tokenValue = rollups.sevenDayTokens,
            trailingTokenValue = rollups.thirtyDayTokens,
            requestValue = rollups.sevenDayRequests
        )
        PulseTimelineScope.MONTH -> PulseWindowMetrics(
            value = rollups.thirtyDays,
            trailingValue = rollups.ninetyDays,
            tokenValue = rollups.thirtyDayTokens,
            trailingTokenValue = rollups.ninetyDayTokens,
            requestValue = rollups.thirtyDayRequests
        )
    }
}

private fun usageMetricsForWindow(
    recentUsages: List<TokenUsage>,
    cutoffMillis: Long,
    nowMillis: Long,
    trailingValue: Double,
    trailingTokenValue: Long
): PulseWindowMetrics {
    val usages = recentUsages.filter {
        val attributedAt = it.effectiveTimeMillis
        attributedAt in cutoffMillis..nowMillis
    }
    return PulseWindowMetrics(
        value = usages.sumOf { it.effectiveCost },
        trailingValue = trailingValue,
        tokenValue = usages.sumOf { it.effectiveTotalTokens },
        trailingTokenValue = trailingTokenValue,
        requestValue = usages.size
    )
}

private val TokenUsage.effectiveTimeMillis: Long
    get() {
        val eventTimes = listOf(timestamp, startTime, endTime).filter { it > 0L }
        eventTimes.maxOrNull()?.let { return it }
        return listOf(updatedAt, createdAt).firstOrNull { it > 0L } ?: 0L
    }

private val TokenUsage.effectiveTotalTokens: Long
    get() {
        if (totalTokens > 0) return totalTokens.toLong()
        return inputTokens.toLong() +
            outputTokens.toLong() +
            cacheCreationTokens.toLong() +
            cacheReadTokens.toLong() +
            reasoningTokens.toLong()
    }

fun startOfLocalPulseDayMillis(
    nowMillis: Long = System.currentTimeMillis(),
    zoneId: ZoneId = ZoneId.systemDefault()
): Long = startOfLocalDayMillis(nowMillis, zoneId)

fun livePulseUsageQueryStartMillis(
    nowMillis: Long = System.currentTimeMillis(),
    zoneId: ZoneId = ZoneId.systemDefault()
): Long {
    val rollingStart = nowMillis - DAY_WINDOW_MILLIS
    return Instant.ofEpochMilli(rollingStart)
        .atZone(zoneId)
        .withMinute(0)
        .withSecond(0)
        .withNano(0)
        .toInstant()
        .toEpochMilli()
}

private const val DAY_WINDOW_MILLIS: Long = 24L * 60L * 60L * 1_000L

private fun startOfLocalDayMillis(nowMillis: Long, zoneId: ZoneId): Long {
    return Instant.ofEpochMilli(nowMillis)
        .atZone(zoneId)
        .toLocalDate()
        .atStartOfDay(zoneId)
        .toInstant()
        .toEpochMilli()
}
