package com.openburnbar.ui.burn

/**
 * The set of visualizations a user can pick from in the Burn tab. [CARDS] is
 * the original default layout (provider ring strip + accordion cards). The
 * other four are alternate at-a-glance reads of the same quota / burn data.
 *
 * Mirrors the iOS `BurnLayoutStyle`. The selection is persisted per-device via
 * [com.openburnbar.data.stores.QuotaPreferences].
 */
enum class BurnViewStyle(val key: String, val label: String) {
    CARDS("cards", "Cards"),
    CONSTELLATION("constellation", "Orbit"),
    GRID("grid", "Grid"),
    LEADERBOARD("leaderboard", "Ranked"),
    TIMELINE("timeline", "Trends");

    companion object {
        /** Maps a persisted raw key back to a style, defaulting to [CARDS]. */
        fun fromKey(key: String?): BurnViewStyle =
            entries.firstOrNull { it.key == key } ?: CARDS
    }
}
