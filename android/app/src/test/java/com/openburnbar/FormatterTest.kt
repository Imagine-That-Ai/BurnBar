
package com.openburnbar

import com.openburnbar.util.Formatting
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

class FormatterTest {
    @Test
    fun `formatCurrency formats dollars correctly`() {
        val result = Formatting.formatCurrency(12.50)
        assertEquals("$12.50", result)
    }

    @Test
    fun `formatPreciseCurrency keeps four fraction digits`() {
        assertEquals("$0.0184", Formatting.formatPreciseCurrency(0.0184))
        assertEquals("$1.5000", Formatting.formatPreciseCurrency(1.5))
    }

    @Test
    fun `formatCompactCurrency scales with magnitude`() {
        assertEquals("$1.2M", Formatting.formatCompactCurrency(1_234_567.0))
        assertEquals("$3.4k", Formatting.formatCompactCurrency(3_400.0))
        assertEquals("$123", Formatting.formatCompactCurrency(123.4))
        assertEquals("$12.34", Formatting.formatCompactCurrency(12.34))
    }

    @Test
    fun `currency output is locale-stable on comma-decimal devices`() {
        // Regression for the "$12,34" bug: a hardcoded "$" mixed with
        // default-locale number formatting on comma-decimal locales.
        val saved = Locale.getDefault()
        try {
            Locale.setDefault(Locale.GERMANY)
            assertEquals("$12.34", Formatting.formatCurrency(12.34))
            assertEquals("$1,234.56", Formatting.formatCurrency(1_234.56))
            assertEquals("$1,235", Formatting.formatShortCurrency(1_234.56))
            assertEquals("$0.0184", Formatting.formatPreciseCurrency(0.0184))
            assertEquals("$1.2k", Formatting.formatCompactCurrency(1_234.5))
            assertEquals("$2.5M", Formatting.formatCompactCurrency(2_500_000.0))
        } finally {
            Locale.setDefault(saved)
        }
    }

    @Test
    fun `formatTokens formats large numbers`() {
        assertEquals("1.50B", Formatting.formatTokens(1_500_000_000))
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
