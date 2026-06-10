@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar

import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.ui.pulse.PulseLiveMetricsStore
import com.openburnbar.ui.pulse.PulseTimelineScope
import com.openburnbar.ui.pulse.livePulseUsageQueryStartMillis
import com.openburnbar.ui.pulse.pulseWindowMetrics
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

private const val NOW = 1_768_306_400_000L

@OptIn(ExperimentalCoroutinesApi::class)
class PulseLiveMetricsStoreTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `update inputs recomputes the combined tick synchronously from one clock`() = runTest {
        val store = PulseLiveMetricsStore(clock = { NOW })
        val rollups = UsageRollups(today = 100.0, sevenDays = 700.0, todayTokens = 100_000L, sevenDayTokens = 700_000L)
        val usages =
            listOf(
                TokenUsage(id = "in-hour", costUsd = 2.5, totalTokens = 250, startTime = NOW - 30L * 60L * 1_000L),
                TokenUsage(id = "old", costUsd = 10.0, totalTokens = 1_000, startTime = NOW - 2L * 60L * 60L * 1_000L),
            )

        store.updateInputs(timelineScope = PulseTimelineScope.HOUR, rollups = rollups, usages = usages)

        val tick = store.tick.value
        assertEquals(NOW, tick.nowMillis)
        // Single clock source: re-running the aggregation with the tick's own
        // nowMillis must reproduce the emitted metrics exactly, so the hero
        // value, burn-rate text, and cost curve can never skew by a tick.
        assertEquals(pulseWindowMetrics(PulseTimelineScope.HOUR, rollups, usages, tick.nowMillis), tick.windowMetrics)
        assertEquals(livePulseUsageQueryStartMillis(tick.nowMillis), tick.liveUsageQueryStartMillis)
    }

    @Test
    fun `ticker reaggregates while subscribed and pauses without subscribers`() = runTest {
        var now = NOW
        val store = PulseLiveMetricsStore(clock = { now })
        store.updateInputs(
            timelineScope = PulseTimelineScope.MINUTE,
            rollups = UsageRollups(),
            usages = listOf(TokenUsage(id = "recent", costUsd = 1.0, totalTokens = 100, startTime = NOW - 30_000L)),
        )
        assertEquals(1, store.tick.value.windowMetrics.requestValue)

        // No subscribers: time passes without any re-aggregation.
        now = NOW + 31_000L
        advanceTimeBy(31_000L)
        runCurrent()
        assertEquals(NOW, store.tick.value.nowMillis)
        assertEquals(1, store.tick.value.windowMetrics.requestValue)

        // Subscribing starts the ticker, which catches up immediately and
        // ages the 30s-old usage out of the minute window.
        val subscription = launch { store.tick.collect {} }
        runCurrent()
        assertEquals(NOW + 31_000L, store.tick.value.nowMillis)
        assertEquals(0, store.tick.value.windowMetrics.requestValue)

        // The 1Hz tick keeps the clock advancing while subscribed.
        now = NOW + 32_000L
        advanceTimeBy(1_000L)
        runCurrent()
        assertEquals(NOW + 32_000L, store.tick.value.nowMillis)

        subscription.cancel()
        runCurrent()

        // Unsubscribed again: the ticker pauses.
        now = NOW + 60_000L
        advanceTimeBy(28_000L)
        runCurrent()
        assertEquals(NOW + 32_000L, store.tick.value.nowMillis)
    }

    @Test
    fun `missing rollups produce zeroed metrics`() = runTest {
        val store = PulseLiveMetricsStore(clock = { NOW })

        store.updateInputs(timelineScope = PulseTimelineScope.DAY, rollups = null, usages = emptyList())

        val metrics = store.tick.value.windowMetrics
        assertEquals(0.0, metrics.value, 0.0)
        assertEquals(0L, metrics.tokenValue)
        assertEquals(0, metrics.requestValue)
    }
}
