package com.openburnbar

import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.stores.CalendarAggregation
import com.openburnbar.data.stores.CalendarDayCost
import com.openburnbar.ui.calendar.CalendarCardConfig
import com.openburnbar.ui.calendar.CalendarCardKind
import com.openburnbar.ui.calendar.CalendarCardSpan
import com.openburnbar.ui.calendar.gridDateResolver
import com.openburnbar.ui.calendar.monthGridDates
import com.openburnbar.ui.calendar.packCalendarRows
import com.openburnbar.ui.calendar.weekdayLabels
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CalendarAggregationTest {
    private val zone: ZoneId = ZoneId.of("America/New_York")

    private fun at(day: LocalDate, hour: Int, minute: Int = 0): Long = day.atTime(hour, minute).atZone(zone).toInstant().toEpochMilli()

    private fun usage(
        startMillis: Long,
        cost: Double,
        provider: String = "codex",
        providerId: String? = null,
        model: String? = "gpt-5",
        sessionId: String? = "s1",
        projectName: String? = "burnbar",
        totalTokens: Int = 1000,
        inputTokens: Int = 400,
        cacheCreationTokens: Int = 100,
        cacheReadTokens: Int = 300,
        reasoningTokens: Int = 0,
    ) = TokenUsage(
        provider = provider,
        providerId = providerId,
        model = model,
        sessionId = sessionId,
        projectName = projectName,
        costUsd = cost,
        totalTokens = totalTokens,
        inputTokens = inputTokens,
        cacheCreationTokens = cacheCreationTokens,
        cacheReadTokens = cacheReadTokens,
        reasoningTokens = reasoningTokens,
        startTime = startMillis,
        endTime = startMillis + 60_000L,
    )

    // ── Day bucketing ──

    @Test
    fun `localDay buckets by the local timezone, not UTC`() {
        // 2026-07-15 02:00 UTC is still 2026-07-14 22:00 in New York (EDT).
        val utcInstant = java.time.Instant.parse("2026-07-15T02:00:00Z").toEpochMilli()
        assertEquals(LocalDate.of(2026, 7, 14), CalendarAggregation.localDay(utcInstant, zone))
        assertEquals(
            LocalDate.of(2026, 7, 15),
            CalendarAggregation.localDay(utcInstant, ZoneId.of("UTC")),
        )
    }

    @Test
    fun `selection attributes cross-midnight sessions to the start day`() {
        val startDay = LocalDate.of(2026, 7, 14)
        val event = usage(startMillis = at(startDay, 23, 30), cost = 4.0)
        val snapshot =
            CalendarAggregation.buildSelection(
                events = listOf(event),
                selectedDays = setOf(startDay),
                zoneId = zone,
            )
        assertEquals(4.0, snapshot.totalCost, 1e-9)
        assertEquals(1, snapshot.activeDays)
        assertEquals(listOf(CalendarDayCost(startDay, 4.0)), snapshot.dailyBurn)
    }

    @Test
    fun `dailyBurn is gap-filled across the span, including month boundaries`() {
        val jan31 = LocalDate.of(2026, 1, 31)
        val feb2 = LocalDate.of(2026, 2, 2)
        val events =
            listOf(
                usage(startMillis = at(jan31, 10), cost = 2.0),
                usage(startMillis = at(feb2, 10), cost = 6.0),
            )
        val snapshot =
            CalendarAggregation.buildSelection(
                events = events,
                selectedDays = setOf(jan31, feb2),
                zoneId = zone,
            )
        assertEquals(
            listOf(
                CalendarDayCost(jan31, 2.0),
                CalendarDayCost(LocalDate.of(2026, 2, 1), 0.0),
                CalendarDayCost(feb2, 6.0),
            ),
            snapshot.dailyBurn,
        )
        // Average is over every selected day, silent gaps in the span excluded
        // (only the two explicitly selected days count).
        assertEquals(4.0, snapshot.averageCostPerDay, 1e-9)
    }

    @Test
    fun `gapFilledDays is empty when the range is reversed`() {
        val day = LocalDate.of(2026, 7, 1)
        assertTrue(CalendarAggregation.gapFilledDays(day.plusDays(1), day).isEmpty())
    }

    // ── Month heat ──

    @Test
    fun `buildMonth sums event cost per local day and scales heat to the grid peak`() {
        val month = YearMonth.of(2026, 7)
        val july10 = LocalDate.of(2026, 7, 10)
        val july12 = LocalDate.of(2026, 7, 12)
        val events =
            listOf(
                usage(startMillis = at(july10, 9), cost = 4.0),
                usage(startMillis = at(july10, 10), cost = 4.0),
                usage(startMillis = at(july12, 9), cost = 2.0),
            )
        val snapshot = CalendarAggregation.buildMonth(events, month, zone)

        assertEquals(8.0, snapshot.dayCosts[july10] ?: 0.0, 1e-9)
        assertEquals(2.0, snapshot.dayCosts[july12] ?: 0.0, 1e-9)
        assertEquals(8.0, snapshot.peakDayCost, 1e-9)
        assertEquals(10.0, snapshot.monthTotalCost, 1e-9)
        assertEquals(1.0f, snapshot.heat(july10))
        assertEquals(0.25f, snapshot.heat(july12))
        // A day with no usage carries no heat at all.
        assertEquals(0f, snapshot.heat(LocalDate.of(2026, 7, 11)))
    }

    @Test
    fun `buildMonth lets an overflow day claim the peak but keeps it out of the month total`() {
        // Grid overflow cells paint alongside the month, so they scale the
        // heat ramp (CalendarDataService.swift:71) — but the header subtitle
        // describes the visible month alone.
        val month = YearMonth.of(2026, 7)
        val june29 = LocalDate.of(2026, 6, 29)
        val july2 = LocalDate.of(2026, 7, 2)
        val events =
            listOf(
                usage(startMillis = at(june29, 9), cost = 10.0),
                usage(startMillis = at(july2, 9), cost = 5.0),
            )
        val snapshot = CalendarAggregation.buildMonth(events, month, zone)

        assertEquals(10.0, snapshot.peakDayCost, 1e-9)
        assertEquals(5.0, snapshot.monthTotalCost, 1e-9)
        assertEquals(1.0f, snapshot.heat(june29))
        assertEquals(0.5f, snapshot.heat(july2))
    }

    @Test
    fun `buildMonth reads an empty month as empty rather than borrowing server rollups`() {
        // `dailyPoints` is a UTC-keyed TOKEN series (rollupCompute.ts:82,
        // rollupCounters.toUtcDate). Seeding cost from it renders token counts
        // as dollars, so an out-of-window month must simply read empty.
        val snapshot = CalendarAggregation.buildMonth(emptyList(), YearMonth.of(2026, 1), zone)
        assertTrue(snapshot.dayCosts.isEmpty())
        assertEquals(0.0, snapshot.peakDayCost, 1e-9)
        assertEquals(0.0, snapshot.monthTotalCost, 1e-9)
    }

    @Test
    fun `buildMonth ranks the top three providers per day by cost`() {
        val month = YearMonth.of(2026, 7)
        val day = LocalDate.of(2026, 7, 3)
        val events =
            listOf(
                usage(startMillis = at(day, 9), cost = 1.0, provider = "ollama"),
                usage(startMillis = at(day, 10), cost = 5.0, provider = "codex"),
                usage(startMillis = at(day, 11), cost = 3.0, provider = "claude-code"),
                usage(startMillis = at(day, 12), cost = 2.0, provider = "gemini-cli"),
            )
        val snapshot = CalendarAggregation.buildMonth(events, month, zone)
        assertEquals(
            listOf(AgentProvider.CODEX, AgentProvider.CLAUDE_CODE, AgentProvider.GEMINI_CLI),
            snapshot.dayProviders[day],
        )
    }

    // ── Selection KPIs and breakdowns ──

    @Test
    fun `buildSelection computes KPIs, distinct sessions, and shares`() {
        val day = LocalDate.of(2026, 7, 14)
        val events =
            listOf(
                usage(startMillis = at(day, 9), cost = 2.0, provider = "codex", model = "gpt-5", sessionId = "a", projectName = "alpha"),
                usage(startMillis = at(day, 10), cost = 3.0, provider = "codex", model = "gpt-5", sessionId = "a", projectName = "alpha"),
                usage(startMillis = at(day, 11), cost = 5.0, provider = "claude-code", model = "claude-opus", sessionId = "b", projectName = "beta"),
                usage(startMillis = at(day, 12), cost = 1.0, provider = "unknown-vendor", model = null, sessionId = null, projectName = null),
            )
        val snapshot =
            CalendarAggregation.buildSelection(events = events, selectedDays = setOf(day), zoneId = zone)

        assertEquals(11.0, snapshot.totalCost, 1e-9)
        assertEquals(4000L, snapshot.totalTokens)
        // Sessions a, b, plus one synthetic bucket for the row with no id —
        // unattributed rows collapse together instead of disappearing.
        assertEquals(3, snapshot.sessionCount)
        assertEquals(1, snapshot.activeDays)
        assertFalse(snapshot.isEmpty)

        assertEquals(listOf("codex", "claude-code", "unknown-vendor"), snapshot.providerShares.map { it.key })
        // Tie on cost (5.0 each) — broken deterministically by key.
        assertEquals(5.0, snapshot.providerShares[0].cost, 1e-9)
        assertEquals("Codex", snapshot.providerShares[0].displayName)
        assertEquals("unknown-vendor", snapshot.providerShares[2].displayName) // unresolved key renders raw
        assertNull(snapshot.providerShares[2].provider)

        // gpt-5 (2+3) and claude-opus (5) tie at $5.00 — the tie breaks
        // alphabetically so ordering is stable across runs and platforms.
        assertEquals(listOf("claude-opus", "gpt-5"), snapshot.topModels.map { it.model })
        assertEquals(5.0, snapshot.topModels[0].cost, 1e-9)
        // alpha (2+3) and beta (5) tie at $5.00 → alphabetical. The $1
        // project-less row surfaces as "Unattributed" rather than being dropped.
        assertEquals(listOf("alpha", "beta", "Unattributed"), snapshot.projectShares.map { it.name })
        assertEquals(1.0, snapshot.projectShares[2].cost, 1e-9)
    }

    @Test
    fun `buildSelection keeps unattributed spend visible and counts blank sessions once`() {
        val day = LocalDate.of(2026, 7, 14)
        val events =
            listOf(
                usage(startMillis = at(day, 9), cost = 4.0, sessionId = null, projectName = null),
                usage(startMillis = at(day, 10), cost = 6.0, sessionId = "", projectName = ""),
                usage(startMillis = at(day, 11), cost = 1.0, sessionId = "s", projectName = "named"),
            )
        val snapshot =
            CalendarAggregation.buildSelection(events = events, selectedDays = setOf(day), zoneId = zone)

        // null and "" are the same synthetic bucket → 2 sessions, not 3 or 1.
        assertEquals(2, snapshot.sessionCount)
        // $10 of unattributed spend outranks the $1 named project.
        assertEquals(listOf("Unattributed", "named"), snapshot.projectShares.map { it.name })
        assertEquals(10.0, snapshot.projectShares[0].cost, 1e-9)
    }

    @Test
    fun `buildSelection on an empty selection is the empty snapshot`() {
        val snapshot =
            CalendarAggregation.buildSelection(
                events = listOf(usage(startMillis = at(LocalDate.of(2026, 7, 14), 9), cost = 2.0)),
                selectedDays = emptySet(),
                zoneId = zone,
            )
        assertTrue(snapshot.isEmpty)
        assertTrue(snapshot.dailyBurn.isEmpty())
        assertEquals(0.0, snapshot.totalCost, 1e-9)
    }

    @Test
    fun `buildSelection fills the hour-of-day matrix and finds the peak`() {
        val day = LocalDate.of(2026, 7, 14) // a Tuesday (row 2, Sunday-first)
        val events =
            listOf(
                usage(startMillis = at(day, 14, 30), cost = 2.0),
                usage(startMillis = at(day, 14, 45), cost = 3.0),
                usage(startMillis = at(day, 9), cost = 1.0),
            )
        val snapshot =
            CalendarAggregation.buildSelection(events = events, selectedDays = setOf(day), zoneId = zone)

        assertEquals(5.0, snapshot.hourWeekdayCost[2][14], 1e-9)
        assertEquals(1.0, snapshot.hourWeekdayCost[2][9], 1e-9)
        assertEquals(2, snapshot.peakWeekdayIndex)
        assertEquals(14, snapshot.peakHour)
        // Sunday row stays zero for a Tuesday-only selection.
        assertEquals(0.0, snapshot.hourWeekdayCost[0].sum(), 1e-9)
    }

    @Test
    fun `buildSelection computes cache hit rate, savings estimate, and reasoning share`() {
        val day = LocalDate.of(2026, 7, 14)
        val event =
            usage(
                startMillis = at(day, 9),
                cost = 2.0,
                totalTokens = 1000,
                inputTokens = 400,
                cacheCreationTokens = 100,
                cacheReadTokens = 300,
                reasoningTokens = 250,
            )
        val snapshot =
            CalendarAggregation.buildSelection(events = listOf(event), selectedDays = setOf(day), zoneId = zone)

        // hit rate = cacheRead / (input + cacheCreation + cacheRead) = 300/800
        assertEquals(0.375, snapshot.cacheHitRate, 1e-9)
        // savings = 0.9 * cacheRead * (cost / tokens) = 0.9 * 300 * 0.002
        assertEquals(0.54, snapshot.cacheSavingsEstimate, 1e-9)
        assertEquals(300L, snapshot.cacheReadTokens)
        assertEquals(0.25, snapshot.reasoningShare, 1e-9)
        assertEquals(250L, snapshot.reasoningTokens)
    }

    // ── Grid math ──

    @Test
    fun `monthGridDates starts on the locale first day of week and covers the month`() {
        val july2026 = YearMonth.of(2026, 7) // July 1, 2026 is a Wednesday.
        val sundayFirst = monthGridDates(july2026, DayOfWeek.SUNDAY)
        assertEquals(42, sundayFirst.size)
        assertEquals(LocalDate.of(2026, 6, 28), sundayFirst.first())
        assertEquals(LocalDate.of(2026, 8, 8), sundayFirst.last())
        assertTrue(sundayFirst.containsAll((1..31).map { july2026.atDay(it) }))

        val mondayFirst = monthGridDates(july2026, DayOfWeek.MONDAY)
        assertEquals(LocalDate.of(2026, 6, 29), mondayFirst.first())
    }

    @Test
    fun `weekdayLabels are locale-ordered single letters`() {
        assertEquals(
            listOf("S", "M", "T", "W", "T", "F", "S"),
            weekdayLabels(DayOfWeek.SUNDAY, Locale.US),
        )
        assertEquals(
            listOf("M", "T", "W", "T", "F", "S", "S"),
            weekdayLabels(DayOfWeek.MONDAY, Locale.US),
        )
    }

    @Test
    fun `gridDateResolver maps offsets to cells and rejects out-of-grid points`() {
        val dates = monthGridDates(YearMonth.of(2026, 7), DayOfWeek.SUNDAY)
        val resolve = gridDateResolver(dates) { androidx.compose.ui.unit.IntSize(700, 600) }
        // 700×600 grid → 100×100 cells; (150, 250) = column 1, row 2 → index 15.
        assertEquals(dates[15], resolve(androidx.compose.ui.geometry.Offset(150f, 250f)))
        assertEquals(dates[0], resolve(androidx.compose.ui.geometry.Offset(1f, 1f)))
        assertNull(resolve(androidx.compose.ui.geometry.Offset(701f, 10f)))
        assertNull(resolve(androidx.compose.ui.geometry.Offset(10f, 601f)))

        val zero = gridDateResolver(dates) { androidx.compose.ui.unit.IntSize.Zero }
        assertNull(zero(androidx.compose.ui.geometry.Offset(10f, 10f)))
    }

    // ── Panel row packing ──

    @Test
    fun `packCalendarRows packs spans into rows of at most three columns`() {
        fun config(kind: CalendarCardKind, span: CalendarCardSpan) = CalendarCardConfig(kind = kind, span = span)
        val rows =
            packCalendarRows(
                listOf(
                    config(CalendarCardKind.KPIS, CalendarCardSpan.L),
                    config(CalendarCardKind.PROVIDER_MIX, CalendarCardSpan.S),
                    config(CalendarCardKind.MODEL_MIX, CalendarCardSpan.M),
                    config(CalendarCardKind.PROJECT_FOCUS, CalendarCardSpan.S),
                    config(CalendarCardKind.BURN_OVER_SELECTION, CalendarCardSpan.L),
                ),
            )
        assertEquals(
            listOf(
                listOf(CalendarCardKind.KPIS),
                listOf(CalendarCardKind.PROVIDER_MIX, CalendarCardKind.MODEL_MIX),
                listOf(CalendarCardKind.PROJECT_FOCUS),
                listOf(CalendarCardKind.BURN_OVER_SELECTION),
            ),
            rows.map { row -> row.map { it.kind } },
        )
        // No row exceeds the 3-column budget.
        assertTrue(rows.all { row -> row.sumOf { it.span.columns } <= 3 })
    }

    @Test
    fun `packCalendarRows of nothing is nothing`() {
        assertTrue(packCalendarRows(emptyList()).isEmpty())
    }
}
