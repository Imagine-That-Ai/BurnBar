package com.openburnbar

import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.data.models.TimelineScope
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.displayRemainingPercent
import org.junit.Assert.*
import org.junit.Test

class TokenUsageModelTest {

    @Test
    fun `TokenUsage default values`() {
        val usage = TokenUsage()
        assertEquals("", usage.id)
        assertEquals(0, usage.totalTokens)
        assertEquals(0.0, usage.cost, 0.001)
    }

    @Test
    fun `UsageDisplayMode has correct labels`() {
        assertEquals("USD", UsageDisplayMode.CURRENCY.label)
        assertEquals("Tokens", UsageDisplayMode.TOKENS.label)
    }

    @Test
    fun `TimelineScope has correct labels`() {
        assertEquals("Day", TimelineScope.DAY.label)
        assertEquals("Week", TimelineScope.WEEK.label)
        assertEquals("Month", TimelineScope.MONTH.label)
    }

    @Test
    fun `quota bucket usedPercent drives display remaining percent`() {
        val bucket = QuotaBucket(
            name = "claude-five-hour",
            used = 0.0,
            limit = 100.0,
            remaining = 0.0,
            window = "5h",
            meta = mapOf("unit" to "percent", "usedPercent" to "62")
        )

        assertEquals(38.0, bucket.displayRemainingPercent ?: -1.0, 0.001)
        assertEquals(
            38.0,
            ProviderQuotaSnapshot(provider = "claude-code", buckets = listOf(bucket)).percentageRemaining,
            0.001
        )
    }

    @Test
    fun `zero limit percent bucket uses percent denominator`() {
        val bucket = QuotaBucket(
            name = "codex-primary",
            used = 37.0,
            limit = 0.0,
            remaining = 63.0,
            window = "5h",
            meta = mapOf("unit" to "percent")
        )

        assertEquals(63.0, bucket.displayRemainingPercent ?: -1.0, 0.001)
    }

    @Test
    fun `remaining only unknown limit does not render as exhausted`() {
        val bucket = QuotaBucket(
            name = "zai-balance",
            used = 0.0,
            limit = -1.0,
            remaining = 23.0,
            window = "account",
            meta = mapOf("currency" to "CNY")
        )

        assertEquals(100.0, bucket.displayRemainingPercent ?: -1.0, 0.001)
        assertEquals(
            100.0,
            ProviderQuotaSnapshot(provider = "zai", buckets = listOf(bucket)).percentageRemaining,
            0.001
        )
    }

    @Test
    fun `empty quota snapshots do not render as exhausted`() {
        assertEquals(
            100.0,
            ProviderQuotaSnapshot(provider = "openai", buckets = emptyList()).percentageRemaining,
            0.001
        )
    }

    @Test
    fun `effectiveCost prefers costUsd and falls back to cost`() {
        // Case 1: Both present, costUsd is preferred
        val usageBoth = TokenUsage(cost = 0.05, costUsd = 0.08)
        assertEquals(0.08, usageBoth.effectiveCost, 0.0001)

        // Case 2: Only costUsd present
        val usageUsdOnly = TokenUsage(cost = 0.0, costUsd = 0.04)
        assertEquals(0.04, usageUsdOnly.effectiveCost, 0.0001)

        // Case 3: Only cost present (fallback)
        val usageCostOnly = TokenUsage(cost = 0.03, costUsd = 0.0)
        assertEquals(0.03, usageCostOnly.effectiveCost, 0.0001)
    }
}
