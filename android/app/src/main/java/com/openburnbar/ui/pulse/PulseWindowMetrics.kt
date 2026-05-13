package com.openburnbar.ui.pulse

import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups

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
    nowMillis: Long = System.currentTimeMillis()
): PulseWindowMetrics {
    return when (scope) {
        PulseTimelineScope.MINUTE -> usageMetricsForWindow(
            recentUsages = recentUsages,
            cutoffMillis = nowMillis - 60_000L,
            trailingValue = rollups.sevenDays,
            trailingTokenValue = rollups.sevenDayTokens
        )
        PulseTimelineScope.HOUR -> usageMetricsForWindow(
            recentUsages = recentUsages,
            cutoffMillis = nowMillis - 60L * 60L * 1_000L,
            trailingValue = rollups.sevenDays,
            trailingTokenValue = rollups.sevenDayTokens
        )
        PulseTimelineScope.DAY -> PulseWindowMetrics(
            value = rollups.today,
            trailingValue = rollups.sevenDays,
            tokenValue = rollups.todayTokens,
            trailingTokenValue = rollups.sevenDayTokens,
            requestValue = rollups.todayRequests
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
    trailingValue: Double,
    trailingTokenValue: Long
): PulseWindowMetrics {
    val usages = recentUsages.filter { it.effectiveTimeMillis >= cutoffMillis }
    return PulseWindowMetrics(
        value = usages.sumOf { it.effectiveCost },
        trailingValue = trailingValue,
        tokenValue = usages.sumOf { it.effectiveTotalTokens },
        trailingTokenValue = trailingTokenValue,
        requestValue = usages.size
    )
}

private val TokenUsage.effectiveTimeMillis: Long
    get() = listOf(startTime, timestamp, endTime, updatedAt, createdAt).firstOrNull { it > 0L } ?: 0L

private val TokenUsage.effectiveTotalTokens: Long
    get() {
        if (totalTokens > 0) return totalTokens.toLong()
        return inputTokens.toLong() +
            outputTokens.toLong() +
            cacheCreationTokens.toLong() +
            cacheReadTokens.toLong() +
            reasoningTokens.toLong()
    }
