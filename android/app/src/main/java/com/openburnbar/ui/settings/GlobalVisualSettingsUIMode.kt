package com.openburnbar.ui.settings

import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import com.openburnbar.ui.theme.UIMode

internal object GlobalVisualSettingsUIMode {
    private const val KEY_UI_MODE = "appUiMode"
    private val _uiMode = mutableStateOf(UIMode.STANDARD)

    val uiMode: State<UIMode> get() = _uiMode

    fun loadFromPrefs(prefs: android.content.SharedPreferences) {
        _uiMode.value = UIMode.fromKey(prefs.getString(KEY_UI_MODE, "standard") ?: "standard")
    }

    fun setUIMode(value: UIMode) {
        _uiMode.value = value
        GlobalVisualSettingsPersistence.persistString(KEY_UI_MODE, value.key)
    }
}
