package com.openburnbar

import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.ui.pulse.PulseTimelineScope
import com.openburnbar.ui.pulse.pulseWindowMetrics
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Test

class PulseWindowMetricsTest {
    @Test
    fun `minute hour and day use distinct raw usage windows`() {
        val now = 1_768_306_400_000L
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
        val day = pulseWindowMetrics(PulseTimelineScope.DAY, rollups, usages, now, ZoneId.of("UTC"))

        assertEquals(1.25, minute.value, 0.001)
        assertEquals(125L, minute.tokenValue)
        assertEquals(1, minute.requestValue)

        assertEquals(3.75, hour.value, 0.001)
        assertEquals(375L, hour.tokenValue)
        assertEquals(2, hour.requestValue)

        assertEquals(13.75, day.value, 0.001)
        assertEquals(1375L, day.tokenValue)
        assertEquals(3, day.requestValue)
    }

    @Test
    fun `calendar day excludes usage before local midnight`() {
        val zone = ZoneId.of("America/Chicago")
        val now = java.time.ZonedDateTime.of(2026, 5, 13, 8, 0, 0, 0, zone)
            .toInstant()
            .toEpochMilli()
        val localMidnight = java.time.LocalDate.of(2026, 5, 13)
            .atStartOfDay(zone)
            .toInstant()
            .toEpochMilli()
        val rollups = UsageRollups(today = 100.0, sevenDays = 700.0)
        val usages = listOf(
            TokenUsage(id = "before", costUsd = 10.0, totalTokens = 1_000, startTime = localMidnight - 1),
            TokenUsage(id = "after", costUsd = 2.0, totalTokens = 200, startTime = localMidnight + 1)
        )

        val day = pulseWindowMetrics(PulseTimelineScope.DAY, rollups, usages, now, zone)

        assertEquals(2.0, day.value, 0.001)
        assertEquals(200L, day.tokenValue)
        assertEquals(1, day.requestValue)
    }

    @Test
    fun `minute window ages out as clock advances`() {
        val now = 1_768_306_400_000L
        val rollups = UsageRollups()
        val usages = listOf(
            TokenUsage(id = "recent", costUsd = 1.0, totalTokens = 100, startTime = now - 30_000L)
        )

        val current = pulseWindowMetrics(PulseTimelineScope.MINUTE, rollups, usages, now)
        val aged = pulseWindowMetrics(PulseTimelineScope.MINUTE, rollups, usages, now + 31_000L)

        assertEquals(1, current.requestValue)
        assertEquals(0, aged.requestValue)
        assertEquals(0.0, aged.value, 0.001)
    }
}
