package com.openburnbar.data.media

import android.content.Context

/**
 * Shared Android preference for Mercury auto keyboard on Mac text focus.
 *
 * Mirrors iOS `@AppStorage("mercury.autoKeyboardOnTextFocus")`: disabled
 * by default so IME popups stay opt-in during screen share.
 */
object MercuryAutoKeyboardPreference {
    const val PREFS_NAME = "mercury_media"
    const val ENABLED_KEY = "mercury.autoKeyboardOnTextFocus"

    fun isEnabled(context: Context): Boolean =
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(ENABLED_KEY, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(ENABLED_KEY, enabled)
            .apply()
    }
}
