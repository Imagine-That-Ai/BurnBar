
package com.openburnbar.ui.pulse

import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Derived-state tests for `PulseViewSections`: the live-vs-recent usage feed
 * selection that drives the hero/forecast aggregation, and the demo-data
 * prompt gate that must only fire for a genuinely empty account.
 */
class PulseViewSectionsTest {
    private val liveRow = TokenUsage(id = "live-1", costUsd = 1.0)
    private val recentRow = TokenUsage(id = "recent-1", costUsd = 2.0)

    @Test
    fun `live usages win whenever the listener has data`() {
        val selected = pulseUsagesForDisplay(liveUsages = listOf(liveRow), recentUsages = listOf(recentRow))
        assertEquals(listOf(liveRow), selected)
    }

    @Test
    fun `cold start falls back to the paged recents`() {
        val recents = listOf(recentRow)
        val selected = pulseUsagesForDisplay(liveUsages = emptyList(), recentUsages = recents)
        // The exact list instance flows through — no copies on the hot path.
        assertSame(recents, selected)
        assertTrue(pulseUsagesForDisplay(emptyList(), emptyList()).isEmpty())
    }

    @Test
    fun `demo prompt shows only for a genuinely empty account`() {
        assertTrue(shouldOfferPulseDemoData(UsageRollups(), emptyList(), emptyList()))
    }

    @Test
    fun `any real signal suppresses the demo prompt`() {
        val rollups = UsageRollups(today = 0.01)
        assertFalse(shouldOfferPulseDemoData(rollups, emptyList(), emptyList()))

        val snapshot = ProviderQuotaSnapshot(id = "q1", provider = "anthropic")
        assertFalse(shouldOfferPulseDemoData(UsageRollups(), listOf(snapshot), emptyList()))

        assertFalse(shouldOfferPulseDemoData(UsageRollups(), emptyList(), listOf(liveRow)))
    }

    @Test
    fun `demo prompt gate sees the same selected feed as the hero`() {
        // The fallback feed (recents) must suppress the prompt exactly like a
        // live feed would — the gate and the hero share pulseUsagesForDisplay.
        val selected = pulseUsagesForDisplay(liveUsages = emptyList(), recentUsages = listOf(recentRow))
        assertFalse(shouldOfferPulseDemoData(UsageRollups(), emptyList(), selected))
    }
}
