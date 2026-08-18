package com.openburnbar.ui.pulse

import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.policy.MobilePulseRollupTotals
import com.openburnbar.data.policy.MobilePulseTimelineScope
import com.openburnbar.data.policy.MobilePulseUsageEvent
import com.openburnbar.data.policy.MobilePulseWindowPolicy
import java.time.Instant
import java.time.ZoneId

data class PulseWindowMetrics(
    val value: Double,
    val trailingValue: Double,
    val tokenValue: Long,
    val trailingTokenValue: Long,
    val requestValue: Int,
)

fun pulseWindowMetrics(
    scope: PulseTimelineScope,
    rollups: UsageRollups,
    recentUsages: List<TokenUsage>,
    nowMillis: Long = System.currentTimeMillis(),
): PulseWindowMetrics {
    val result = MobilePulseWindowPolicy.metrics(
        scope = scope.toPolicyScope(),
        rollups = rollups.toPolicyMap(),
        usages = recentUsages.map { it.toPulseEvent() },
        nowMs = nowMillis,
    )
    return PulseWindowMetrics(
        value = result.total.costUsd,
        trailingValue = result.trailing?.costUsd ?: 0.0,
        tokenValue = result.total.tokens.toLong(),
        trailingTokenValue = result.trailing?.tokens?.toLong() ?: 0L,
        requestValue = result.total.requests,
    )
}

fun startOfLocalPulseDayMillis(nowMillis: Long = System.currentTimeMillis(), zoneId: ZoneId = ZoneId.systemDefault()): Long = Instant.ofEpochMilli(nowMillis)
    .atZone(zoneId)
    .toLocalDate()
    .atStartOfDay(zoneId)
    .toInstant()
    .toEpochMilli()

fun livePulseUsageQueryStartMillis(nowMillis: Long = System.currentTimeMillis(), zoneId: ZoneId = ZoneId.systemDefault()): Long =
    MobilePulseWindowPolicy.liveQueryStartMs(nowMillis, zoneId.id)

private fun PulseTimelineScope.toPolicyScope(): MobilePulseTimelineScope = when (this) {
    PulseTimelineScope.MINUTE -> MobilePulseTimelineScope.MINUTE
    PulseTimelineScope.HOUR -> MobilePulseTimelineScope.HOUR
    PulseTimelineScope.DAY -> MobilePulseTimelineScope.DAY
    PulseTimelineScope.WEEK -> MobilePulseTimelineScope.WEEK
    PulseTimelineScope.MONTH -> MobilePulseTimelineScope.MONTH
}

private fun UsageRollups.toPolicyMap(): Map<String, MobilePulseRollupTotals> = mapOf(
    "today" to MobilePulseRollupTotals(todayRequests, todayTokens.toInt(), today),
    "7d" to MobilePulseRollupTotals(sevenDayRequests, sevenDayTokens.toInt(), sevenDays),
    "30d" to MobilePulseRollupTotals(thirtyDayRequests, thirtyDayTokens.toInt(), thirtyDays),
    "90d" to MobilePulseRollupTotals(ninetyDayRequests, ninetyDayTokens.toInt(), ninetyDays),
)

private fun TokenUsage.toPulseEvent(): MobilePulseUsageEvent = MobilePulseUsageEvent(
    startMs = startTime,
    endMs = endTime,
    tokens = MobilePulseWindowPolicy.pulseTokens(
        totalTokens = totalTokens,
        inputTokens = inputTokens,
        outputTokens = outputTokens,
        cacheCreationTokens = cacheCreationTokens,
        cacheReadTokens = cacheReadTokens,
        reasoningTokens = reasoningTokens,
    ),
    costUsd = MobilePulseWindowPolicy.pulseCost(costUsd, costUSD, cost),
)
