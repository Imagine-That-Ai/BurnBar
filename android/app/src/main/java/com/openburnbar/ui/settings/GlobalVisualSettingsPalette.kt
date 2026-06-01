package com.openburnbar.ui.settings

import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf

internal object GlobalVisualSettingsPalette {
    private const val KEY_THEME_PALETTE = "appThemePalette"
    private val _themePalette = mutableStateOf("System")

    val themePalette: State<String> get() = _themePalette

    fun loadFromPrefs(prefs: android.content.SharedPreferences) {
        _themePalette.value = prefs.getString(KEY_THEME_PALETTE, "System") ?: "System"
    }

    fun setThemePalette(value: String) {
        _themePalette.value = value
        GlobalVisualSettingsPersistence.persistThemePalette(value)
    }
}
