package com.openburnbar.ui.chartstudio

import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.models.UsageRollups
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChartStudioPromptSuggestionsTest {
    @Test
    fun `suggestions match the prompt engine for an empty digest`() {
        val digest = TrendDataDigest.build(rollups = UsageRollups(), recentUsages = emptyList())
        val suggestions = chartStudioSuggestedPrompts(digest)
        assertEquals(ChartStudioPromptEngine.suggestedPrompts(digest), suggestions)
        assertTrue(suggestions.isNotEmpty())
        assertTrue(suggestions.any { it.contains("Stack my spend") })
    }
}
