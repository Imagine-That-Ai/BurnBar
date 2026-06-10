@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; window
// fixtures are literal by design.

package com.openburnbar.ui.pulse

import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import java.time.ZoneId
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Rollup-scope tests for `PulseWindowMetrics`, complementing the raw-window
 * suite in `com.openburnbar.PulseWindowMetricsTest`: the WEEK/MONTH scopes are
 * pure rollup passthroughs (never raw-usage scans), token totals fall back to
 * the component sum, and the local-day helper anchors to midnight in the
 * requested zone.
 */
class PulseWindowMetricsTest {
    private val rollups = UsageRollups(
        today = 100.0,
        sevenDays = 700.0,
        thirtyDays = 3_000.0,
        ninetyDays = 9_000.0,
        sevenDayTokens = 700_000L,
        thirtyDayTokens = 3_000_000L,
        ninetyDayTokens = 9_000_000L,
        sevenDayRequests = 70,
        thirtyDayRequests = 300,
    )

    @Test
    fun `week scope reads seven day rollups with thirty day trailing`() {
        val now = 1_768_306_400_000L
        // Raw usage rows must be ignored entirely for rollup scopes.
        val decoys = listOf(TokenUsage(id = "decoy", costUsd = 999.0, totalTokens = 999, startTime = now - 1_000L))

        val week = pulseWindowMetrics(PulseTimelineScope.WEEK, rollups, decoys, now)

        assertEquals(700.0, week.value, 0.0)
        assertEquals(3_000.0, week.trailingValue, 0.0)
        assertEquals(700_000L, week.tokenValue)
        assertEquals(3_000_000L, week.trailingTokenValue)
        assertEquals(70, week.requestValue)
    }

    @Test
    fun `month scope reads thirty day rollups with ninety day trailing`() {
        val month = pulseWindowMetrics(PulseTimelineScope.MONTH, rollups, emptyList(), 1_768_306_400_000L)

        assertEquals(3_000.0, month.value, 0.0)
        assertEquals(9_000.0, month.trailingValue, 0.0)
        assertEquals(3_000_000L, month.tokenValue)
        assertEquals(9_000_000L, month.trailingTokenValue)
        assertEquals(300, month.requestValue)
    }

    @Test
    fun `token totals fall back to the component sum when totalTokens is unset`() {
        val now = 1_768_306_400_000L
        val usage = TokenUsage(
            id = "components",
            costUsd = 1.0,
            startTime = now - 10_000L,
            inputTokens = 100,
            outputTokens = 50,
            cacheCreationTokens = 25,
            cacheReadTokens = 10,
            reasoningTokens = 5,
        )

        val minute = pulseWindowMetrics(PulseTimelineScope.MINUTE, rollups, listOf(usage), now)

        // 100 + 50 + 25 + 10 + 5 — cache and reasoning tokens must not vanish.
        assertEquals(190L, minute.tokenValue)
        assertEquals(1, minute.requestValue)
    }

    @Test
    fun `rows without any usable event time never enter a live window`() {
        val now = 1_768_306_400_000L
        val ghost = TokenUsage(id = "ghost", costUsd = 5.0, totalTokens = 500)

        val day = pulseWindowMetrics(PulseTimelineScope.DAY, rollups, listOf(ghost), now)

        assertEquals(0.0, day.value, 0.0)
        assertEquals(0L, day.tokenValue)
        assertEquals(0, day.requestValue)
    }

    @Test
    fun `start of local pulse day is midnight in the requested zone`() {
        val zone = ZoneId.of("America/Chicago")
        val now = ZonedDateTime.of(2026, 6, 9, 15, 30, 45, 0, zone).toInstant().toEpochMilli()

        val startOfDay = startOfLocalPulseDayMillis(now, zone)

        assertEquals(
            ZonedDateTime.of(2026, 6, 9, 0, 0, 0, 0, zone).toInstant().toEpochMilli(),
            startOfDay,
        )
        // UTC midnight differs from Chicago midnight for the same instant.
        assertEquals(
            ZonedDateTime.of(2026, 6, 9, 0, 0, 0, 0, ZoneId.of("UTC")).toInstant().toEpochMilli(),
            startOfLocalPulseDayMillis(now, ZoneId.of("UTC")),
        )
    }
}
