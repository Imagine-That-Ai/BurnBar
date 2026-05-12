package com.openburnbar

import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.data.models.TimelineScope
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
}
