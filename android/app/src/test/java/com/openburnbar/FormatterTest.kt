package com.openburnbar

import com.openburnbar.util.Formatting
import org.junit.Assert.assertEquals
import org.junit.Test

class FormatterTest {

    @Test
    fun `formatCurrency formats dollars correctly`() {
        val result = Formatting.formatCurrency(12.50)
        assertEquals("$12.50", result)
    }

    @Test
    fun `formatTokens formats large numbers`() {
        assertEquals("1.5M", Formatting.formatTokens(1_500_000))
        assertEquals("5.0K", Formatting.formatTokens(5_000))
        assertEquals("42", Formatting.formatTokens(42))
    }

    @Test
    fun `formatDelta computes percentage change`() {
        assertEquals("+100.0%", Formatting.formatDelta(10.0, 5.0))
        assertEquals("-50.0%", Formatting.formatDelta(5.0, 10.0))
    }
}
