package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightDigest.Totals

/**
 * Test fixture that produces a deterministic digest for unit tests.
 */
class InMemoryInsightDataSource : InsightDataSource {
    var testDigest: InsightDigest = InsightDigest(
        totals = Totals(costUSD = 42.50, totalTokens = 850_000, sessionCount = 127),
        providers = listOf(
            InsightDigest.ProviderSnapshot(id = "anthropic", displayName = "Anthropic", costUSD = 30.0, totalTokens = 600_000, sessionCount = 80),
            InsightDigest.ProviderSnapshot(id = "openai", displayName = "OpenAI", costUSD = 12.50, totalTokens = 250_000, sessionCount = 47)
        ),
        models = listOf(
            InsightDigest.ModelSnapshot(id = "claude-sonnet-4-6", providerID = "anthropic", costUSD = 25.0, totalTokens = 500_000, sessionCount = 60, avgCostPerSession = 0.42, cacheHitRate = 0.35),
            InsightDigest.ModelSnapshot(id = "gpt-4.1", providerID = "openai", costUSD = 10.0, totalTokens = 200_000, sessionCount = 30, avgCostPerSession = 0.33, cacheHitRate = 0.0)
        )
    )

    override suspend fun buildDigest(filter: InsightFilter): InsightDigest = testDigest
    override suspend fun buildDigest(window: InsightTimeWindow): InsightDigest = testDigest
}
