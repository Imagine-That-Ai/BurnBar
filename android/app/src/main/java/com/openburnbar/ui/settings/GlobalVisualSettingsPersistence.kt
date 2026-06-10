package com.openburnbar.ui.settings

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.openburnbar.BurnBarApplication

/**
 * Shared persistence funnel for the global visual settings prefs file. Writes
 * issued before [BurnBarApplication.appContext] is installed are dropped (the
 * in-memory Compose state still updates); both that drop and any real write
 * failure are logged instead of being silently swallowed.
 */
internal object GlobalVisualSettingsPersistence {
    private const val TAG = "BurnBarVisualSettings"
    private const val PREFS_NAME = "global_visual_settings"

    /** True once Application.onCreate has installed the app context. */
    val isReady: Boolean get() = BurnBarApplication.isAppContextInitialized

    /** Only call when [isReady]; Android caches the instance per prefs file. */
    fun sharedPrefs(): SharedPreferences =
        BurnBarApplication.appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun persistThemePalette(value: String) {
        persistString("appThemePalette", value)
    }

    fun persistString(key: String, value: String) {
        persist(key) { putString(key, value) }
    }

    fun persistBoolean(key: String, value: Boolean) {
        persist(key) { putBoolean(key, value) }
    }

    fun persist(what: String, write: SharedPreferences.Editor.() -> Unit) {
        if (!isReady) {
            Log.w(TAG, "Android visual settings dropped persist of $what: appContext not installed yet")
            return
        }
        runCatching {
            val editor = sharedPrefs().edit()
            editor.write()
            editor.apply()
        }.onFailure { error ->
            Log.w(TAG, "Android visual settings persist of $what failed error=${error.message}", error)
        }
    }
}
