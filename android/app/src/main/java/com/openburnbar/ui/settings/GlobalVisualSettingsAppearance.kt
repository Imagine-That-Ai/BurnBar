package com.openburnbar.ui.settings

import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import com.openburnbar.ui.theme.AppAppearance

/**
 * Persists the app *skin* ([AppAppearance]) — Aurora (default) vs. the Editorial
 * paper console skin. Mirrors [GlobalVisualSettingsUIMode]: a reactive
 * `mutableStateOf` backed by a single `SharedPreferences` string key.
 */
internal object GlobalVisualSettingsAppearance {
    private const val KEY_APPEARANCE = "appAppearance"
    private val _appearance = mutableStateOf(AppAppearance.AURORA)

    val appearance: State<AppAppearance> get() = _appearance

    fun loadFromPrefs(prefs: android.content.SharedPreferences) {
        _appearance.value = AppAppearance.fromKey(prefs.getString(KEY_APPEARANCE, "aurora") ?: "aurora")
    }

    fun setAppearance(value: AppAppearance) {
        _appearance.value = value
        GlobalVisualSettingsPersistence.persistString(KEY_APPEARANCE, value.key)
    }
}
