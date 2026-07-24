package com.openburnbar

import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.stores.CalendarStore
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class CalendarStoreTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val zone: ZoneId = ZoneId.of("America/New_York")

    // Fixed "now": 2026-07-15 12:00 local.
    private val nowMillis: Long =
        LocalDate.of(2026, 7, 15).atTime(12, 0).atZone(zone).toInstant().toEpochMilli()

    private fun at(day: LocalDate, hour: Int): Long = day.atTime(hour, 0).atZone(zone).toInstant().toEpochMilli()

    private fun usage(startMillis: Long, cost: Double, provider: String = "codex", sessionId: String = "s1") = TokenUsage(
        provider = provider,
        model = "gpt-5",
        sessionId = sessionId,
        costUsd = cost,
        totalTokens = 1000,
        startTime = startMillis,
        endTime = startMillis + 60_000L,
    )

    @Test
    fun `startListening publishes month heat from events alone, ignoring rollup dailyPoints`() = runTest {
        val july10 = LocalDate.of(2026, 7, 10)
        val july11 = LocalDate.of(2026, 7, 11)
        // `dailyPoints` is a UTC-keyed TOKEN series, not local-day cost. It must
        // never reach the heatmap — token counts rendered as dollars is exactly
        // the bug this asserts against.
        val rollups = UsageRollups(dailyPoints = mapOf("2026-07-10" to 4.0, "2026-07-11" to 6.0))
        val events = listOf(usage(startMillis = at(july10, 9), cost = 2.0))
        val repo = mockk<FirestoreRepository>()
        every { repo.listenToRollups() } returns flowOf(rollups)
        every { repo.listenToUsageSince(any()) } returns flowOf(events)

        val store = CalendarStore(repo = repo, zoneId = zone, clock = { nowMillis })
        store.startListening()
        advanceUntilIdle()

        val month = store.monthSnapshot.value
        assertEquals(YearMonth.of(2026, 7), month.month)
        assertEquals(2.0, month.dayCosts[july10] ?: 0.0, 1e-9)
        // The rollup-only day contributes nothing — an empty day, not a $6 day.
        assertNull(month.dayCosts[july11])
        assertEquals(2.0, month.peakDayCost, 1e-9)
        assertEquals(2.0, month.monthTotalCost, 1e-9)
        // Provider dots come from the events feed.
        assertEquals(1, month.dayProviders[july10]?.size)
        assertNull(store.error.value)

        store.stopListening()
    }

    @Test
    fun `setSelection re-aggregates the loaded events without new fetches`() = runTest {
        val july14 = LocalDate.of(2026, 7, 14)
        val july15 = LocalDate.of(2026, 7, 15)
        val events =
            listOf(
                usage(startMillis = at(july14, 9), cost = 2.0, sessionId = "a"),
                usage(startMillis = at(july15, 10), cost = 3.0, sessionId = "b"),
            )
        val repo = mockk<FirestoreRepository>()
        every { repo.listenToRollups() } returns flowOf(UsageRollups())
        every { repo.listenToUsageSince(any()) } returns flowOf(events)

        val store = CalendarStore(repo = repo, zoneId = zone, clock = { nowMillis })
        store.startListening()
        advanceUntilIdle()

        store.setSelection(setOf(july14, july15))
        advanceUntilIdle()

        val snapshot = store.selectionSnapshot.value
        assertEquals(listOf(july14, july15), snapshot.selectedDays)
        assertEquals(5.0, snapshot.totalCost, 1e-9)
        assertEquals(2, snapshot.sessionCount)
        assertEquals(2, snapshot.activeDays)
        assertEquals(2.5, snapshot.averageCostPerDay, 1e-9)
        assertEquals(
            listOf(
                com.openburnbar.data.stores.CalendarDayCost(july14, 2.0),
                com.openburnbar.data.stores.CalendarDayCost(july15, 3.0),
            ),
            snapshot.dailyBurn,
        )

        // Selection changes re-aggregate in memory — no additional subscriptions.
        verify(exactly = 1) { repo.listenToUsageSince(any()) }
        store.stopListening()
    }

    @Test
    fun `setVisibleMonth restarts the usage listener on the new window`() = runTest {
        val repo = mockk<FirestoreRepository>()
        every { repo.listenToRollups() } returns flowOf(UsageRollups())
        every { repo.listenToUsageSince(any()) } returns flowOf(emptyList())

        val store = CalendarStore(repo = repo, zoneId = zone, clock = { nowMillis })
        store.startListening()
        advanceUntilIdle()

        store.shiftMonth(-1)
        advanceUntilIdle()

        assertEquals(YearMonth.of(2026, 6), store.visibleMonth.value)
        // Once for the initial month, once for the shifted month.
        verify(exactly = 2) { repo.listenToUsageSince(any()) }
        assertEquals(YearMonth.of(2026, 6), store.monthSnapshot.value.month)

        store.stopListening()
    }

    @Test
    fun `listener errors surface on the error flow instead of crashing`() = runTest {
        val repo = mockk<FirestoreRepository>()
        every { repo.listenToRollups() } returns kotlinx.coroutines.flow.flow { throw FirestoreRepository.NotSignedInException() }
        every { repo.listenToUsageSince(any()) } returns flowOf(emptyList())

        val store = CalendarStore(repo = repo, zoneId = zone, clock = { nowMillis })
        store.startListening()
        advanceUntilIdle()

        assertEquals("Sign in required to load your dashboard.", store.error.value)
        store.stopListening()
    }
}
