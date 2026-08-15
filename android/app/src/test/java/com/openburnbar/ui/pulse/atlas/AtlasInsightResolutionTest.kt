package com.openburnbar.ui.pulse.atlas

import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.derived.TrendInsight
import com.openburnbar.data.derived.TrendInsightEngine
import com.openburnbar.data.derived.TrendInsightTone
import com.openburnbar.data.models.UsageRollups
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class AtlasInsightResolutionTest {
    private val digest = TrendDataDigest.build(rollups = UsageRollups(), recentUsages = emptyList())

    @Test
    fun `null insights compute from the digest engine`() {
        assertEquals(TrendInsightEngine.insights(digest), resolvedAtlasInsights(digest, null))
    }

    @Test
    fun `supplied insights win including an empty list`() {
        val supplied = listOf(
            TrendInsight(
                id = "supplied",
                title = "Caller insight",
                detail = "Do not recompute.",
                tone = TrendInsightTone.NEUTRAL,
                symbolName = "Bolt",
                rank = 1,
            ),
        )
        assertSame(supplied, resolvedAtlasInsights(digest, supplied))
        assertEquals(emptyList<TrendInsight>(), resolvedAtlasInsights(digest, emptyList()))
    }
}
