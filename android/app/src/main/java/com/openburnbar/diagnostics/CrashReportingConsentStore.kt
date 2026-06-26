package com.openburnbar.diagnostics

import android.content.Context

interface BooleanPreferenceStorage {
    fun getBoolean(key: String, defaultValue: Boolean): Boolean
    fun putBoolean(key: String, value: Boolean)
}

class SharedPreferencesBooleanPreferenceStorage(
    context: Context,
    prefsName: String,
) : BooleanPreferenceStorage {
    private val prefs = context.applicationContext.getSharedPreferences(prefsName, Context.MODE_PRIVATE)

    override fun getBoolean(key: String, defaultValue: Boolean): Boolean = prefs.getBoolean(key, defaultValue)

    override fun putBoolean(key: String, value: Boolean) {
        prefs.edit().putBoolean(key, value).commit()
    }
}

/**
 * Android crash-reporting consent is separate from opt-in usage analytics.
 *
 * Default is false so a fresh install does not start Crashlytics before the
 * user has made an explicit diagnostics decision. The Settings toggle writes a
 * durable boolean and [com.openburnbar.BurnBarApplication] applies the same
 * gate on every launch before Crashlytics collection is enabled.
 */
class CrashReportingConsentStore(
    private val storage: BooleanPreferenceStorage,
    private val key: String = CRASH_REPORTING_ENABLED_KEY,
) {
    val isEnabled: Boolean
        get() = storage.getBoolean(key, false)

    fun setEnabled(enabled: Boolean) = storage.putBoolean(key, enabled)

    companion object {
        const val PREFS_NAME = "burnbar.diagnostics"
        const val CRASH_REPORTING_ENABLED_KEY = "crashlytics_enabled"

        fun fromContext(context: Context): CrashReportingConsentStore = CrashReportingConsentStore(
            SharedPreferencesBooleanPreferenceStorage(
                context = context,
                prefsName = PREFS_NAME,
            ),
        )
    }
}
