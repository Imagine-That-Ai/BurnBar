package com.openburnbar.data.widget

import kotlinx.serialization.Serializable

/**
 * Compact, JSON-serializable snapshot read by every BurnBar widget surface
 * (home-screen + lock-screen Glance widgets). Mirrors the iOS
 * `BurnBarWidgetSnapshot` Codable struct so the two surfaces show identical
 * numbers; the main app writes this from `DashboardStore` after every rollup
 * refresh, the widget worker re-reads it on schedule.
 *
 * Stays under ~1 KB on the wire so widget hosts don't choke on the
 * persisted blob.
 */
@Serializable
data class BurnBarWidgetSnapshot(
    val heroTotalCost: Double = 0.0,
    val heroTotalTokens: Long = 0,
    val heroTotalRequests: Int = 0,
    /** Top 3 providers by token volume — display names, not raw keys. */
    val topProviders: List<String> = emptyList(),
    /** Token totals parallel to [topProviders]. */
    val topProviderTokens: List<Long> = emptyList(),
    /** Top 3 models by cost — bare model strings (`claude-3-5-sonnet`, etc.). */
    val topModels: List<String> = emptyList(),
    /** Last ~7 daily totals for the sparkline. */
    val dailyPoints: List<Double> = emptyList(),
    /** "today" | "7d" | "30d" — what window the hero metrics represent. */
    val windowKey: String = "today",
    /** Millis since epoch when this snapshot was minted. */
    val lastSyncMs: Long = 0L
) {
    companion object {
        /**
         * Placeholder snapshot used by Glance previews and the WidgetSyncWorker
         * fallback when the persisted file is missing. Shape mirrors the iOS
         * `.preview` Codable instance.
         */
        val preview: BurnBarWidgetSnapshot = BurnBarWidgetSnapshot(
            heroTotalCost = 3.42,
            heroTotalTokens = 12_400,
            heroTotalRequests = 18,
            topProviders = listOf("Claude Code", "Codex", "Cursor"),
            topProviderTokens = listOf(5_200L, 4_100L, 3_100L),
            topModels = listOf("claude-3-5-sonnet", "gpt-5", "gemini-1.5-pro"),
            dailyPoints = listOf(0.45, 0.62, 0.51, 0.78, 0.66, 0.83, 0.71),
            windowKey = "today",
            lastSyncMs = System.currentTimeMillis()
        )

        const val FILENAME = "widget_snapshot.json"
    }
}
