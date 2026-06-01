package com.openburnbar.ui.settings

import android.content.Context
import com.openburnbar.BurnBarApplication

internal object GlobalVisualSettingsPersistence {
    private const val PREFS_NAME = "global_visual_settings"

    private val prefs by lazy {
        BurnBarApplication.appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun persistThemePalette(value: String) {
        persistString("appThemePalette", value)
    }

    fun persistString(key: String, value: String) {
        try {
            prefs.edit().putString(key, value).apply()
        } catch (_: Throwable) {
        }
    }
}
