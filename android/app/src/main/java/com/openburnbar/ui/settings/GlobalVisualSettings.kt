package com.openburnbar.ui.settings

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import com.openburnbar.BurnBarApplication

/**
 * Thread-safe singleton manager for global visual settings in the Android app.
 * Automatically persists to standard SharedPreferences and provides Compose-state
 * properties that trigger UI recomposition instantly when updated.
 */
object GlobalVisualSettings {
    private const val PREFS_NAME = "global_visual_settings"
    private const val KEY_PREMIUM_SOTA_UX = "usePremiumSOTAUX"
    private const val KEY_WEBSITE_BACKGROUND = "useWebsiteBackground"

    private var loaded = false

    private val prefs by lazy {
        BurnBarApplication.appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    // Underlying Compose mutable states to trigger reactive updates globally.
    private val _usePremiumSOTAUX = mutableStateOf(false)
    private val _useWebsiteBackground = mutableStateOf(false)

    private fun ensureLoaded() {
        if (!loaded) {
            try {
                // Safely load initial persisted values if appContext is ready.
                _usePremiumSOTAUX.value = prefs.getBoolean(KEY_PREMIUM_SOTA_UX, false)
                _useWebsiteBackground.value = prefs.getBoolean(KEY_WEBSITE_BACKGROUND, false)
                loaded = true
            } catch (e: Throwable) {
                // If lateinit appContext is not initialized yet, swallow and retry on next access
            }
        }
    }

    /** Exposes read-only access to Premium SOTA UX setting. */
    val usePremiumSOTAUX: State<Boolean> get() { ensureLoaded(); return _usePremiumSOTAUX }

    /** Exposes read-only access to Website Background setting. */
    val useWebsiteBackground: State<Boolean> get() { ensureLoaded(); return _useWebsiteBackground }

    // Color Palette
    private val KEY_THEME_PALETTE = "appThemePalette"
    private val _themePalette = mutableStateOf("System")
    val themePalette: State<String> get() { ensureLoaded(); return _themePalette }

    fun setThemePalette(value: String) {
        ensureLoaded()
        _themePalette.value = value
        try { prefs.edit().putString(KEY_THEME_PALETTE, value).apply() } catch (e: Throwable) {}
    }

    // Tabs
    private val KEY_PRIMARY_TABS = "primaryTabs"
    private val KEY_SECONDARY_TABS = "secondaryTabs"
    private val defaultPrimaryTabs = "pulse,burn,insights,streams,agents"
    private val defaultSecondaryTabs = "you,providers,devices,settings"

    private val _primaryTabs = mutableStateOf(defaultPrimaryTabs)
    private val _secondaryTabs = mutableStateOf(defaultSecondaryTabs)

    val primaryTabs: State<String> get() { ensureLoaded(); return _primaryTabs }
    val secondaryTabs: State<String> get() { ensureLoaded(); return _secondaryTabs }

    fun setPrimaryTabs(value: String) {
        ensureLoaded()
        _primaryTabs.value = value
        try { prefs.edit().putString(KEY_PRIMARY_TABS, value).apply() } catch (e: Throwable) {}
    }

    fun setSecondaryTabs(value: String) {
        ensureLoaded()
        _secondaryTabs.value = value
        try { prefs.edit().putString(KEY_SECONDARY_TABS, value).apply() } catch (e: Throwable) {}
    }

    /** Sets the Premium SOTA UX value and persists it. */
    fun setPremiumSOTAUX(value: Boolean) {
        ensureLoaded()
        _usePremiumSOTAUX.value = value
        try { prefs.edit().putBoolean(KEY_PREMIUM_SOTA_UX, value).apply() } catch (e: Throwable) {}
    }

    /** Sets the Website Background value and persists it. */
    fun setWebsiteBackground(value: Boolean) {
        ensureLoaded()
        _useWebsiteBackground.value = value
        try { prefs.edit().putBoolean(KEY_WEBSITE_BACKGROUND, value).apply() } catch (e: Throwable) {}
    }
}

/** Composable shorthand helper to observe global Premium SOTA UX setting. */
@Composable
fun rememberPremiumSOTAUX(): State<Boolean> = remember { GlobalVisualSettings.usePremiumSOTAUX }

/** Composable shorthand helper to observe global Website Background setting. */
@Composable
fun rememberWebsiteBackground(): State<Boolean> = remember { GlobalVisualSettings.useWebsiteBackground }

@Composable
fun rememberThemePalette(): State<String> = remember { GlobalVisualSettings.themePalette }

enum class AppThemePalette(val displayName: String) {
    System("System"), AuroraTeal("Aurora"), Crimson("Crimson"),
    CyberpunkViolet("Cyberpunk"), ForestMoss("Moss"), SolarFlare("Solar")
}

enum class AppDestination(val id: String, val label: String) {
    Pulse("pulse", "Pulse"), Burn("burn", "Burn"), Insights("insights", "Insights"),
    Streams("streams", "Streams"), Agents("agents", "Agents"), You("you", "You"),
    Settings("settings", "Settings"), Devices("devices", "Devices"), Providers("providers", "Providers")
}
