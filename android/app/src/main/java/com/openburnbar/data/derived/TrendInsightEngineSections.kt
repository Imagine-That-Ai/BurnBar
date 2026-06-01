@file:Suppress("MatchingDeclarationName")

package com.openburnbar.data.derived

import kotlin.math.abs

internal fun trendSpendVelocityInsight(today: TrendDataDigest.WindowTotals?, sevenDay: TrendDataDigest.WindowTotals?): TrendInsight? {
    if (today == null || sevenDay == null || sevenDay.costUsd <= TrendDigestConstants.MIN_COST_DELTA_USD) return null
    val avg7 = sevenDay.costUsd / TrendDigestConstants.ROLLING_WINDOW_DAYS
    val pct = (today.costUsd - avg7) / avg7 * 100.0
    val absPct = abs(pct).toInt()
    if (abs(pct) < TrendDigestConstants.WEEK_OVER_WEEK_ALERT_THRESHOLD_PERCENT) return null
    return TrendInsight(
        id = "spend.delta",
        title = if (pct > 0) "Spend up $absPct%" else "Spend down $absPct%",
        detail = "vs your 7-day average",
        tone = if (pct > 0) TrendInsightTone.WARNING else TrendInsightTone.POSITIVE,
        symbolName = if (pct > 0) "TrendingUp" else "TrendingDown",
        rank = 100 + absPct,
    )
}

internal fun trendProviderConcentrationInsight(digest: TrendDataDigest): TrendInsight? {
    val top = digest.providers.firstOrNull() ?: return null
    if (top.sharePct < TrendDigestConstants.PROVIDER_SHARE_DOMINANT_THRESHOLD) return null
    return TrendInsight(
        id = "provider.concentration",
        title = "${top.provider} = ${top.sharePct.toInt()}% of tokens",
        detail = "Most of your activity flows through one provider",
        tone = TrendInsightTone.NEUTRAL,
        symbolName = "DonutLarge",
        rank = 80,
    )
}

internal fun trendCacheInsights(digest: TrendDataDigest): List<TrendInsight> {
    if (digest.cache.totalCacheReadTokens <= 0) return emptyList()
    val cacheRate = digest.cache.cacheHitRate
    return when {
        cacheRate >= TrendDigestConstants.CACHE_RATE_HIGH_THRESHOLD ->
            listOf(
                TrendInsight(
                    id = "cache.healthy",
                    title = "Cache hit ${(cacheRate * 100).toInt()}%",
                    detail = "Saving ≈ $${"%.2f".format(digest.cache.estSavingsUsd)} on input tokens",
                    tone = TrendInsightTone.POSITIVE,
                    symbolName = "Bolt",
                    rank = 70,
                ),
            )
        cacheRate < TrendDigestConstants.CACHE_RATE_LOW_THRESHOLD ->
            listOf(
                TrendInsight(
                    id = "cache.cold",
                    title = "Cache hit ${(cacheRate * 100).toInt()}%",
                    detail = "Re-using context could reduce input cost",
                    tone = TrendInsightTone.WARNING,
                    symbolName = "AcUnit",
                    rank = 75,
                ),
            )
        else -> emptyList()
    }
}

internal fun trendPeakHourInsight(digest: TrendDataDigest): TrendInsight? {
    val peak = digest.hourly.maxByOrNull { it.tokens } ?: return null
    if (peak.tokens <= 0) return null
    val label = "${peak.hour.toString().padStart(2, '0')}:00"
    return TrendInsight(
        id = "hour.peak",
        title = "Peak hour $label",
        detail = "Most tokens flow through this slot in your typical day",
        tone = TrendInsightTone.NEUTRAL,
        symbolName = "Schedule",
        rank = 50,
    )
}

internal fun trendVelocityChampionInsight(digest: TrendDataDigest): TrendInsight? {
    val fastest =
        digest.recentSessions
            .filter { it.outputTokensPerSecond > 0 && it.durationSec > TrendDigestConstants.MIN_SESSION_DURATION_SECONDS }
            .maxByOrNull { it.outputTokensPerSecond }
            ?: return null
    return TrendInsight(
        id = "session.velocity",
        title = "${fastest.model.ifBlank { fastest.provider }} streamed ${fastest.outputTokensPerSecond.toInt()} tok/s",
        detail = "Your fastest recent session",
        tone = TrendInsightTone.POSITIVE,
        symbolName = "RocketLaunch",
        rank = 40,
    )
}

internal fun trendLongTailVolumeInsight(thirtyDay: TrendDataDigest.WindowTotals?): TrendInsight? {
    if (thirtyDay == null || thirtyDay.tokens <= TrendDigestConstants.HIGH_TOKEN_VOLUME_THRESHOLD) return null
    return TrendInsight(
        id = "tokens.30d",
        title = "${trendFormatTokens(thirtyDay.tokens)} tokens in 30 days",
        detail = "$${"%.2f".format(thirtyDay.costUsd)} total spend",
        tone = TrendInsightTone.NEUTRAL,
        symbolName = "Analytics",
        rank = 30,
    )
}

internal fun trendFormatTokens(n: Long): String = when {
    n >= TrendDigestConstants.PERCENT_SCALE -> "%.1fB".format(n / TrendDigestConstants.PERCENT_SCALE_DOUBLE)
    n >= TrendDigestConstants.PERCENT_SCALE_MILLION -> "%.1fM".format(n / TrendDigestConstants.PERCENT_SCALE_MILLION.toDouble())
    n >= 1_000 -> "%.1fK".format(n / 1_000.0)
    else -> n.toString()
}
