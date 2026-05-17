package com.openburnbar

import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.ui.pulse.PulseTimelineScope
import com.openburnbar.ui.pulse.livePulseUsageQueryStartMillis
import com.openburnbar.ui.pulse.pulseWindowMetrics
import java.time.ZoneId
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
    fun `day window is rolling twenty four hours across local midnight`() {
        val zone = ZoneId.of("America/Chicago")
        val now = ZonedDateTime.of(2026, 5, 13, 0, 20, 0, 0, zone)
            .toInstant()
            .toEpochMilli()
        val rollups = UsageRollups(today = 100.0, sevenDays = 700.0)
        val usages = listOf(
            TokenUsage(id = "outside", costUsd = 10.0, totalTokens = 1_000, startTime = now - 24L * 60L * 60L * 1_000L - 1L),
            TokenUsage(id = "inside", costUsd = 2.0, totalTokens = 200, startTime = now - 7L * 60L * 60L * 1_000L)
        )

        val day = pulseWindowMetrics(PulseTimelineScope.DAY, rollups, usages, now, zone)

        assertEquals(2.0, day.value, 0.001)
        assertEquals(200L, day.tokenValue)
        assertEquals(1, day.requestValue)
    }

    @Test
    fun `live query start covers rolling day without restarting every second`() {
        val zone = ZoneId.of("America/Chicago")
        val now = ZonedDateTime.of(2026, 5, 13, 0, 20, 30, 0, zone)
            .toInstant()
            .toEpochMilli()

        val start = livePulseUsageQueryStartMillis(now, zone)

        assertTrue(start <= now - 24L * 60L * 60L * 1_000L)
        assertTrue(start > now - 25L * 60L * 60L * 1_000L)
        assertEquals(0, ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(start), zone).minute)
        assertEquals(0, ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(start), zone).second)
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

    @Test
    fun `live windows use session end time for advancing rows`() {
        val now = 1_768_306_400_000L
        val rollups = UsageRollups()
        val usages = listOf(
            TokenUsage(
                id = "advancing-session",
                costUsd = 4.0,
                totalTokens = 400,
                startTime = now - 90L * 60L * 1_000L,
                endTime = now - 30_000L
            )
        )

        val minute = pulseWindowMetrics(PulseTimelineScope.MINUTE, rollups, usages, now)
        val hour = pulseWindowMetrics(PulseTimelineScope.HOUR, rollups, usages, now)

        assertEquals(1, minute.requestValue)
        assertEquals(400L, minute.tokenValue)
        assertEquals(1, hour.requestValue)
    }

    @Test
    fun `sync update timestamps do not make old events look live`() {
        val now = 1_768_306_400_000L
        val rollups = UsageRollups()
        val usages = listOf(
            TokenUsage(
                id = "old-event-fresh-sync",
                costUsd = 4.0,
                totalTokens = 400,
                startTime = now - 2L * 60L * 60L * 1_000L,
                endTime = now - 2L * 60L * 60L * 1_000L,
                updatedAt = now - 30_000L
            )
        )

        val minute = pulseWindowMetrics(PulseTimelineScope.MINUTE, rollups, usages, now)

        assertEquals(0, minute.requestValue)
        assertEquals(0L, minute.tokenValue)
    }
}
