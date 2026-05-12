package com.openburnbar.menubar

import android.content.Context

/**
 * Persists the user's preference for whether the menu-bar simulation should
 * keep its persistent notification running. SharedPreferences-backed so the
 * service can read synchronously at startup without a DataStore coroutine.
 */
object SuppressionStore {
    private const val PREFS = "burnbar.menubar.prefs"
    private const val KEY_SUPPRESSED = "menubar.suppressed"

    fun allowed(context: Context): Boolean = !suppressed(context)

    fun suppressed(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_SUPPRESSED, false)

    fun setSuppressed(context: Context, value: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_SUPPRESSED, value)
            .apply()
        if (value) MenuBarService.stop(context) else MenuBarService.start(context)
    }
}
