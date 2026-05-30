package com.openburnbar.ui.burn

import com.openburnbar.data.models.RollupSummary
import com.openburnbar.data.models.UsageDisplayMode

/**
 * Pure ranking/normalization helpers for the Burn leaderboard view, factored
 * out (no Compose deps) so they can be unit-tested on the JVM. Mirrors the iOS
 * `BurnLeaderboardMath`.
 */
object BurnLeaderboardMath {
    /** The spend value for a provider summary in the active display mode. */
    fun value(p: RollupSummary, displayMode: UsageDisplayMode): Double =
        if (displayMode == UsageDisplayMode.CURRENCY) p.totalCost else p.totalTokens.toDouble()

    /** Providers with non-zero spend, sorted highest-first. */
    fun ranked(summaries: List<RollupSummary>, displayMode: UsageDisplayMode): List<RollupSummary> =
        summaries
            .filter { value(it, displayMode) > 0.0 }
            .sortedByDescending { value(it, displayMode) }

    /** A 0..1 bar fraction, clamped, safe against a zero/negative max. */
    fun fraction(value: Double, max: Double): Float {
        if (max <= 0.0) return 0f
        return (value / max).toFloat().coerceIn(0f, 1f)
    }
}
