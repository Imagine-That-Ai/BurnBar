package com.openburnbar.analytics

import android.content.Context
import java.util.UUID

/**
 * A random, per-install anonymous device id — generated once and persisted in a
 * private prefs file. Deliberately **NOT** derived from any hardware identifier
 * (no ANDROID_ID, no advertising id, no IMEI/serial), matching the macOS
 * transport's "stable per-install UUID, not a hardware id" contract. Cleared on
 * uninstall with the rest of app storage; a fresh install gets a fresh id.
 */
object AnonymousDeviceId {
    private const val PREFS_NAME = "burnbar.analytics.identity"
    private const val KEY_DEVICE_ID = "anonymous_device_id"

    fun getOrCreate(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.getString(KEY_DEVICE_ID, null)?.let { return it }
        val generated = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_DEVICE_ID, generated).commit()
        return generated
    }
}
