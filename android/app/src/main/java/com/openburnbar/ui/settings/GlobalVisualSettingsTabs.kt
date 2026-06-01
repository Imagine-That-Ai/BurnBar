package com.openburnbar.ui.settings

import com.openburnbar.BurnBarApplication
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf

internal object GlobalVisualSettingsTabs {
    private const val PREFS_NAME = "global_visual_settings"
    private const val KEY_PRIMARY_TABS = "primaryTabs"
    private const val KEY_SECONDARY_TABS = "secondaryTabs"
    private const val defaultPrimaryTabs = "pulse,burn,insights,streams,agents"
    private const val defaultSecondaryTabs = "you,providers,devices,settings"

    private val _primaryTabs = mutableStateOf(defaultPrimaryTabs)
    private val _secondaryTabs = mutableStateOf(defaultSecondaryTabs)

    val primaryTabs: State<String> get() = _primaryTabs
    val secondaryTabs: State<String> get() = _secondaryTabs

    fun loadFromPrefs(prefs: android.content.SharedPreferences) {
        _primaryTabs.value = prefs.getString(KEY_PRIMARY_TABS, defaultPrimaryTabs) ?: defaultPrimaryTabs
        _secondaryTabs.value = prefs.getString(KEY_SECONDARY_TABS, defaultSecondaryTabs) ?: defaultSecondaryTabs
    }

    fun setPrimaryTabs(value: String) {
        _primaryTabs.value = value
        persistTabPref(KEY_PRIMARY_TABS, value)
    }

    fun setSecondaryTabs(value: String) {
        _secondaryTabs.value = value
        persistTabPref(KEY_SECONDARY_TABS, value)
    }

    private fun persistTabPref(key: String, value: String) {
        try {
            BurnBarApplication.appContext
                .getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
                .edit()
                .putString(key, value)
                .apply()
        } catch (_: Throwable) {
        }
    }
}
