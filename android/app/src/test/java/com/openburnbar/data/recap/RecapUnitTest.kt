package com.openburnbar.data.recap

import com.openburnbar.data.models.TokenUsage
import java.time.LocalDate
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecapUnitTest {

    @Test
    fun testRecapWindowArithmetic() {
        val w = RecapWindow(2026, 8)
        assertEquals("2026-08", w.key)
        assertEquals("August 2026", w.displayLabel())
        assertEquals("August", w.monthLabel())
        assertEquals(31, w.dayCount())

        val prev = w.previous
        assertEquals(2026, prev.year)
        assertEquals(7, prev.month)
        assertEquals("2026-07", prev.key)

        val jan = RecapWindow(2026, 1)
        val dec = jan.previous
        assertEquals(2025, dec.year)
        assertEquals(12, dec.month)

        val parsed = RecapWindow.parse("2026-08")
        assertEquals(w, parsed)
    }

    @Test
    fun testRecapFactsBuilderFold() {
        val window = RecapWindow(2026, 8)
        val zone = ZoneId.of("UTC")
        val aug10 = LocalDate.of(2026, 8, 10).atStartOfDay(zone).toInstant().toEpochMilli() + 10 * 3600 * 1000 // 10:00 UTC
        val aug11 = LocalDate.of(2026, 8, 11).atStartOfDay(zone).toInstant().toEpochMilli() + 14 * 3600 * 1000 // 14:00 UTC

        val usages = listOf(
            TokenUsage(
                id = "u1",
                provider = "anthropic",
                model = "claude-3-7-sonnet",
                inputTokens = 1000,
                outputTokens = 500,
                cacheReadTokens = 200,
                reasoningTokens = 100,
                totalTokens = 1500,
                costUSD = 0.50,
                startTime = aug10,
                endTime = aug10 + 300_000,
                sessionId = "sess-1",
            ),
            TokenUsage(
                id = "u2",
                provider = "openai",
                model = "gpt-4o",
                inputTokens = 2000,
                outputTokens = 1000,
                totalTokens = 3000,
                costUSD = 1.00,
                startTime = aug11,
                endTime = aug11 + 600_000,
                sessionId = "sess-2",
            ),
        )

        val facts = RecapFactsBuilder.build(window, usages, isPartial = false, zone = zone)

        assertEquals(1.50, facts.totalCostUSD, 0.001)
        assertEquals(4500L, facts.totalTokens)
        assertEquals(2, facts.sessionCount)
        assertEquals(2, facts.activeDayCount)
        assertEquals(2, facts.longestActiveStreak)
        assertEquals(2, facts.models.size)
        assertEquals("gpt-4o", facts.topModel?.key)
        assertEquals(1.00, facts.topModel?.costUSD ?: 0.0, 0.001)
        assertEquals(2, facts.pairings.size)
    }

    @Test
    fun testRecapRuleEngineAndRanker() {
        val window = RecapWindow(2026, 8)
        val zone = ZoneId.of("UTC")
        val aug10 = LocalDate.of(2026, 8, 10).atStartOfDay(zone).toInstant().toEpochMilli() + 10 * 3600 * 1000

        val usages = (1..10).map { i ->
            val time = aug10 + (i * 86_400_000L)
            TokenUsage(
                id = "u$i",
                provider = "anthropic",
                model = "claude-3-7-sonnet",
                inputTokens = 5000,
                outputTokens = 2000,
                cacheReadTokens = 1000,
                reasoningTokens = 500,
                totalTokens = 7000,
                costUSD = 2.50,
                startTime = time,
                endTime = time + 600_000,
                sessionId = "sess-$i",
            )
        }

        val facts = RecapFactsBuilder.build(window, usages, isPartial = false, zone = zone)
        val ctx = RecapContext(facts = facts)

        val candidates = RecapRuleEngine.generateCandidates(ctx)
        assertFalse(candidates.isEmpty())

        val cards = RecapRanker.rank(candidates)
        assertFalse(cards.isEmpty())

        val title = RecapDeterministicVoice.title(ctx, cards)
        assertNotNull(title)
        assertTrue(title.isNotEmpty())

        val closing = RecapDeterministicVoice.closing(ctx, cards)
        assertNotNull(closing)
        assertTrue(closing.isNotEmpty())
    }
}
