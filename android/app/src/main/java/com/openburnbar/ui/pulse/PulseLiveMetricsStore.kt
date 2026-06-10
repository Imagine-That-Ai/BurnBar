package com.openburnbar.ui.pulse

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

private const val LIVE_TICK_INTERVAL_MILLIS = 1_000L

private val EMPTY_WINDOW_METRICS = PulseWindowMetrics(
    value = 0.0,
    trailingValue = 0.0,
    tokenValue = 0L,
    trailingTokenValue = 0L,
    requestValue = 0,
)

/**
 * One combined live-clock emission. `windowMetrics` is always aggregated with
 * this exact `nowMillis`, so the hero value, burn-rate text, and live cost
 * curve share a single clock source and can never skew by a tick.
 */
data class PulseLiveTick(
    val nowMillis: Long,
    val liveUsageQueryStartMillis: Long,
    val windowMetrics: PulseWindowMetrics,
)

/**
 * Owns the Pulse 1Hz live clock and the O(N) usage-window aggregation that
 * previously ran inside composition on every clock tick. The ticker only runs
 * while the UI collects [tick] (mirrors the old `LaunchedEffect` lifetime),
 * and [updateInputs] recomputes synchronously so the frame that changes the
 * timeline scope or receives new usage data renders metrics aggregated from
 * those exact inputs.
 *
 * The default-argument constructor preserves the no-arg shape `viewModel()`
 * uses; tests inject a deterministic clock.
 */
class PulseLiveMetricsStore(
    private val clock: () -> Long = System::currentTimeMillis,
) : ViewModel() {
    private data class Inputs(
        val timelineScope: PulseTimelineScope,
        val rollups: UsageRollups?,
        val usages: List<TokenUsage>,
    )

    private val inputs = MutableStateFlow(Inputs(PulseTimelineScope.DAY, rollups = null, usages = emptyList()))

    private val _tick = MutableStateFlow(tickFor(inputs.value, clock()))
    val tick: StateFlow<PulseLiveTick> = _tick.asStateFlow()

    init {
        viewModelScope.launch {
            _tick.subscriptionCount
                .map { it > 0 }
                .distinctUntilChanged()
                .collectLatest { hasSubscribers ->
                    if (!hasSubscribers) return@collectLatest
                    while (true) {
                        // Refresh first: re-subscription after a pause (tab
                        // switch) must not render a stale clock for a second.
                        refreshTick()
                        delay(LIVE_TICK_INTERVAL_MILLIS)
                    }
                }
        }
    }

    fun updateInputs(timelineScope: PulseTimelineScope, rollups: UsageRollups?, usages: List<TokenUsage>) {
        inputs.value = Inputs(timelineScope, rollups, usages)
        refreshTick()
    }

    private fun refreshTick() {
        _tick.value = tickFor(inputs.value, clock())
    }

    private fun tickFor(inputs: Inputs, nowMillis: Long): PulseLiveTick =
        PulseLiveTick(
            nowMillis = nowMillis,
            liveUsageQueryStartMillis = livePulseUsageQueryStartMillis(nowMillis),
            windowMetrics =
            inputs.rollups?.let { rollups ->
                pulseWindowMetrics(
                    scope = inputs.timelineScope,
                    rollups = rollups,
                    recentUsages = inputs.usages,
                    nowMillis = nowMillis,
                )
            } ?: EMPTY_WINDOW_METRICS,
        )
}
