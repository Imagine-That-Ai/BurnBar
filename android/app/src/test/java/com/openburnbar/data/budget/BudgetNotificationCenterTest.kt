package com.openburnbar.data.budget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class BudgetNotificationCenterTest {
    @Test
    fun `budget notification content is redacted by default`() {
        val content = BudgetNotificationCenter.budgetNotificationContent()
        val rendered = "${content.title}\n${content.text}"

        assertEquals("Budget alert", content.title)
        assertEquals("Open BurnBar to review budget status.", content.text)

        val sensitiveFragments =
            listOf(
                "Claude Team",
                "anthropic",
                "\$123.45",
                "\$200.00",
                "limit reached",
                "warning",
                "month",
            )

        sensitiveFragments.forEach { fragment ->
            assertFalse(
                "Budget notification content should not expose '$fragment'",
                rendered.contains(fragment, ignoreCase = true),
            )
        }
    }
}
