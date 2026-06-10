@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.ui.pulse

import com.openburnbar.MainDispatcherRule
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

/**
 * Single-clock contract tests for [PulseLiveMetricsStore], complementing the
 * ticker-lifecycle suite in `com.openburnbar.PulseLiveMetricsStoreTest`: the
 * initial tick is computed eagerly from the injected clock, every tick keeps
 * `nowMillis`/query-start/metrics on the same clock reading, and switching
 * the timeline scope re-aggregates synchronously.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class PulseLiveMetricsStoreTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val nowMillis = 1_768_306_400_000L

    @Test
    fun `the initial tick is available immediately from the injected clock`() = runTest {
        val store = PulseLiveMetricsStore(clock = { nowMillis })

        val tick = store.tick.value

        assertEquals(nowMillis, tick.nowMillis)
        assertEquals(livePulseUsageQueryStartMillis(nowMillis), tick.liveUsageQueryStartMillis)
        // No rollups yet → zeroed metrics, never a crash or stale aggregate.
        assertEquals(0.0, tick.windowMetrics.value, 0.0)
        assertEquals(0, tick.windowMetrics.requestValue)
    }

    @Test
    fun `every tick field shares one clock reading`() = runTest {
        var clock = nowMillis
        val store = PulseLiveMetricsStore(clock = { clock })
        clock += 5_000L

        store.updateInputs(PulseTimelineScope.DAY, UsageRollups(sevenDays = 7.0), emptyList())

        val tick = store.tick.value
        assertEquals(clock, tick.nowMillis)
        assertEquals(livePulseUsageQueryStartMillis(clock), tick.liveUsageQueryStartMillis)
    }

    @Test
    fun `scope changes re-aggregate synchronously with the new scope`() = runTest {
        val store = PulseLiveMetricsStore(clock = { nowMillis })
        val rollups = UsageRollups(
            sevenDays = 700.0,
            thirtyDays = 3_000.0,
            sevenDayTokens = 700_000L,
            thirtyDayTokens = 3_000_000L,
            sevenDayRequests = 70,
        )
        val usages = listOf(
            TokenUsage(id = "u1", costUsd = 1.5, totalTokens = 150, startTime = nowMillis - 30_000L),
        )

        store.updateInputs(PulseTimelineScope.MINUTE, rollups, usages)
        assertEquals(1.5, store.tick.value.windowMetrics.value, 0.0)
        assertEquals(700.0, store.tick.value.windowMetrics.trailingValue, 0.0)

        // Same inputs, WEEK scope: the frame that switches scope must already
        // render rollup passthrough values, not last tick's raw-window sums.
        store.updateInputs(PulseTimelineScope.WEEK, rollups, usages)
        assertEquals(700.0, store.tick.value.windowMetrics.value, 0.0)
        assertEquals(3_000.0, store.tick.value.windowMetrics.trailingValue, 0.0)
        assertEquals(70, store.tick.value.windowMetrics.requestValue)
    }

    @Test
    fun `clearing rollups returns the zeroed empty metrics`() = runTest {
        val store = PulseLiveMetricsStore(clock = { nowMillis })
        store.updateInputs(PulseTimelineScope.WEEK, UsageRollups(sevenDays = 700.0), emptyList())
        assertEquals(700.0, store.tick.value.windowMetrics.value, 0.0)

        store.updateInputs(PulseTimelineScope.WEEK, null, emptyList())

        val metrics = store.tick.value.windowMetrics
        assertEquals(0.0, metrics.value, 0.0)
        assertEquals(0L, metrics.tokenValue)
        assertEquals(0, metrics.requestValue)
    }
}
