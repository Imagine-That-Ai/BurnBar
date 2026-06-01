package com.openburnbar.data.square

import android.content.Context

/**
 * Shared Android preference for the Hermes Square "My Mac" tile.
 *
 * Mirrors iOS `@AppStorage("mercuryPinnedTileEnabled")`: enabled by
 * default so the screen-share entry point is visible before relay
 * discovery has fully hydrated.
 */
object MercuryPairedMacTilePreference {
    const val PREFS_NAME = "mercury_media"
    const val ENABLED_KEY = "mercuryPinnedTileEnabled"

    fun isEnabled(context: Context): Boolean = context.applicationContext
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        .getBoolean(ENABLED_KEY, true)

    fun setEnabled(context: Context, enabled: Boolean) {
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(ENABLED_KEY, enabled)
            .apply()
    }
}
