package com.openburnbar.analytics

import android.content.Context

/**
 * Production [ConsentStorage] binding over a private SharedPreferences file,
 * mirroring the existing GlobalVisualSettingsPersistence idiom. Reads/writes
 * are synchronous (`commit`) so the consent decision is durable before the
 * recorder acts on it — the same posture as the macOS `UserDefaults` store,
 * which persists in `didSet`.
 */
class SharedPreferencesConsentStorage(context: Context) : ConsentStorage {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun getString(key: String): String? = prefs.getString(key, null)

    override fun putString(key: String, value: String) {
        prefs.edit().putString(key, value).commit()
    }

    companion object {
        const val PREFS_NAME = "burnbar.analytics"
    }
}
