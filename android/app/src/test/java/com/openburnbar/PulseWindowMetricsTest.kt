package com.openburnbar

import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.ui.pulse.PulseTimelineScope
import com.openburnbar.ui.pulse.pulseWindowMetrics
import org.junit.Assert.assertEquals
import org.junit.Test

class PulseWindowMetricsTest {
    @Test
    fun `minute hour and day use distinct sources`() {
        val now = 1_000_000_000L
        val rollups = UsageRollups(
            today = 100.0,
            sevenDays = 700.0,
            todayTokens = 100_000L,
            sevenDayTokens = 700_000L,
            todayRequests = 100
        )
        val usages = listOf(
            TokenUsage(id = "in-minute", costUsd = 1.25, totalTokens = 125, startTime = now - 30_000L),
            TokenUsage(id = "in-hour", costUsd = 2.50, totalTokens = 250, startTime = now - 30L * 60L * 1_000L),
            TokenUsage(id = "old", costUsd = 10.0, totalTokens = 1_000, startTime = now - 2L * 60L * 60L * 1_000L)
        )

        val minute = pulseWindowMetrics(PulseTimelineScope.MINUTE, rollups, usages, now)
        val hour = pulseWindowMetrics(PulseTimelineScope.HOUR, rollups, usages, now)
        val day = pulseWindowMetrics(PulseTimelineScope.DAY, rollups, usages, now)

        assertEquals(1.25, minute.value, 0.001)
        assertEquals(125L, minute.tokenValue)
        assertEquals(1, minute.requestValue)

        assertEquals(3.75, hour.value, 0.001)
        assertEquals(375L, hour.tokenValue)
        assertEquals(2, hour.requestValue)

        assertEquals(100.0, day.value, 0.001)
        assertEquals(100_000L, day.tokenValue)
        assertEquals(100, day.requestValue)
    }
}
