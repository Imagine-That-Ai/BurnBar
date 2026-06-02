@file:Suppress("MagicNumber")
// detekt: test fixtures use literal wire-format / timeout values.

package com.openburnbar

import com.openburnbar.data.models.RollupSummary
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.ui.burn.BurnLeaderboardMath
import com.openburnbar.ui.burn.BurnViewStyle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class BurnViewStyleTest {
    @Test
    fun hasTwoStylesWithStableKeys() {
        assertEquals(2, BurnViewStyle.entries.size)
        assertEquals(
            listOf("cards", "list"),
            BurnViewStyle.entries.map { it.key },
        )
    }

    @Test
    fun everyStyleHasLabel() {
        BurnViewStyle.entries.forEach { assertFalse(it.label.isBlank()) }
    }

    @Test
    fun fromKeyFallsBackToCards() {
        assertEquals(BurnViewStyle.LIST, BurnViewStyle.fromKey("list"))
        assertEquals(BurnViewStyle.CARDS, BurnViewStyle.fromKey("nonsense"))
        assertEquals(BurnViewStyle.CARDS, BurnViewStyle.fromKey(null))
    }

    private fun summary(provider: String, cost: Double, tokens: Long) = RollupSummary(
        provider = provider,
        totalCost = cost,
        totalTokens = tokens,
    )

    @Test
    fun leaderboardRanksByCostAndTokens() {
        val a = summary("anthropic", cost = 5.0, tokens = 100)
        val b = summary("openai", cost = 2.0, tokens = 300)
        val zero = summary("google", cost = 0.0, tokens = 0)

        assertEquals(
            listOf("anthropic", "openai"),
            BurnLeaderboardMath.ranked(listOf(a, b, zero), UsageDisplayMode.CURRENCY).map { it.provider },
        )
        assertEquals(
            listOf("openai", "anthropic"),
            BurnLeaderboardMath.ranked(listOf(a, b, zero), UsageDisplayMode.TOKENS).map { it.provider },
        )
    }

    @Test
    fun leaderboardFractionClampsAndGuardsZero() {
        assertEquals(0.5f, BurnLeaderboardMath.fraction(5.0, 10.0), 0.0001f)
        assertEquals(1.0f, BurnLeaderboardMath.fraction(20.0, 10.0), 0.0001f) // clamped
        assertEquals(0.0f, BurnLeaderboardMath.fraction(5.0, 0.0), 0.0001f) // zero-guard
    }
}
