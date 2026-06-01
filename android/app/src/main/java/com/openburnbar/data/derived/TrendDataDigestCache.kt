package com.openburnbar.data.derived

import com.openburnbar.data.models.TokenUsage

internal fun trendDigestBuildCache(usages: List<TokenUsage>): TrendDataDigest.CacheAggregate {
    val totalRead = usages.sumOf { it.cacheReadTokens.toLong() }
    val totalCreate = usages.sumOf { it.cacheCreationTokens.toLong() }
    val totalInput = usages.sumOf { it.inputTokens.toLong() }
    val denom = totalRead + totalCreate
    val rate = if (denom > 0) totalRead.toDouble() / denom.toDouble() else 0.0
    val avgInputCostPerMillion = TrendDigestConstants.AVG_INPUT_COST_USD_PER_MILLION_TOKENS
    val savedTokens = totalRead.toDouble()
    val estSavings =
        savedTokens / TrendDigestConstants.PERCENT_SCALE_MILLION.toDouble() *
            avgInputCostPerMillion *
            TrendDigestConstants.SAVINGS_COST_FACTOR
    return TrendDataDigest.CacheAggregate(
        totalCacheReadTokens = totalRead,
        totalCacheCreationTokens = totalCreate,
        totalInputTokens = totalInput,
        cacheHitRate = rate,
        estSavingsUsd = estSavings,
    )
}
