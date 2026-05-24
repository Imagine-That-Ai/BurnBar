package com.openburnbar.ui.settings

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.models.AgentProvider

/**
 * Thread-safe singleton manager for global visual settings in the Android app.
 * Automatically persists to standard SharedPreferences and provides Compose-state
 * properties that trigger UI recomposition instantly when updated.
 */
object GlobalVisualSettings {
    private const val PREFS_NAME = "global_visual_settings"
    private const val KEY_PREMIUM_SOTA_UX = "usePremiumSOTAUX"
    private const val KEY_WEBSITE_BACKGROUND = "useWebsiteBackground"
    private const val KEY_SWARM_SPARKLES = "enableSwarmSparkles"
    private const val KEY_PROVIDER_GLYPHS = "providerGlyphs"
    private const val KEY_EXCLUDE_BRAND_SHAPES = "excludeBrandShapesFromSwarm"

    private var loaded = false

    private val prefs by lazy {
        BurnBarApplication.appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    // Underlying Compose mutable states to trigger reactive updates globally.
    private val _usePremiumSOTAUX = mutableStateOf(false)
    private val _useWebsiteBackground = mutableStateOf(false)
    private val _enableSwarmSparkles = mutableStateOf(true)
    private val _providerGlyphs = mutableStateOf(AgentProvider.swarmGlyphProviders.toSet())
    private val _excludeBrandShapesFromSwarm = mutableStateOf(false)

    private fun ensureLoaded() {
        if (!loaded) {
            try {
                // Safely load initial persisted values if appContext is ready.
                _usePremiumSOTAUX.value = prefs.getBoolean(KEY_PREMIUM_SOTA_UX, false)
                _useWebsiteBackground.value = prefs.getBoolean(KEY_WEBSITE_BACKGROUND, false)
                _enableSwarmSparkles.value = prefs.getBoolean(KEY_SWARM_SPARKLES, true)
                _excludeBrandShapesFromSwarm.value = prefs.getBoolean(KEY_EXCLUDE_BRAND_SHAPES, false)
                _themePalette.value = prefs.getString(KEY_THEME_PALETTE, "System") ?: "System"
                _providerGlyphs.value = decodeProviderGlyphs(prefs.getString(KEY_PROVIDER_GLYPHS, null))
                _primaryTabs.value = prefs.getString(KEY_PRIMARY_TABS, defaultPrimaryTabs) ?: defaultPrimaryTabs
                _secondaryTabs.value = prefs.getString(KEY_SECONDARY_TABS, defaultSecondaryTabs) ?: defaultSecondaryTabs
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

    /** Exposes read-only access to Swarm Sparkles setting. */
    val enableSwarmSparkles: State<Boolean> get() { ensureLoaded(); return _enableSwarmSparkles }

    /** Exposes read-only access to Exclude Brand Shapes setting. */
    val excludeBrandShapesFromSwarm: State<Boolean> get() { ensureLoaded(); return _excludeBrandShapesFromSwarm }

    /** Exposes app-wide provider glyph filters for live swarm backgrounds. */
    val providerGlyphs: State<Set<AgentProvider>> get() { ensureLoaded(); return _providerGlyphs }

    // Color Palette
    private val KEY_THEME_PALETTE = "appThemePalette"
    private val _themePalette = mutableStateOf("System")
    val themePalette: State<String> get() { ensureLoaded(); return _themePalette }

    fun setThemePalette(value: String) {
        ensureLoaded()
        _themePalette.value = value
        try { prefs.edit().putString(KEY_THEME_PALETTE, value).apply() } catch (e: Throwable) {}
    }

    fun setProviderGlyphs(value: Set<AgentProvider>) {
        ensureLoaded()
        val normalized = AgentProvider.swarmGlyphProviders.filter { value.contains(it) }.toSet()
        _providerGlyphs.value = normalized
        try { prefs.edit().putString(KEY_PROVIDER_GLYPHS, encodeProviderGlyphs(normalized)).apply() } catch (e: Throwable) {}
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

    /** Sets the Swarm Sparkles value and persists it. */
    fun setSwarmSparkles(value: Boolean) {
        ensureLoaded()
        _enableSwarmSparkles.value = value
        try { prefs.edit().putBoolean(KEY_SWARM_SPARKLES, value).apply() } catch (e: Throwable) {}
    }

    /** Sets the Exclude Brand Shapes value and persists it. */
    fun setExcludeBrandShapesFromSwarm(value: Boolean) {
        ensureLoaded()
        _excludeBrandShapesFromSwarm.value = value
        try { prefs.edit().putBoolean(KEY_EXCLUDE_BRAND_SHAPES, value).apply() } catch (e: Throwable) {}
    }

    private fun encodeProviderGlyphs(providers: Set<AgentProvider>): String =
        AgentProvider.swarmGlyphProviders
            .filter { providers.contains(it) }
            .joinToString(",") { it.key }

    private fun decodeProviderGlyphs(raw: String?): Set<AgentProvider> {
        if (raw == null) return AgentProvider.swarmGlyphProviders.toSet()
        if (raw.isBlank()) return emptySet()
        val selected = raw.split(',')
            .mapNotNull { AgentProvider.fromKey(it.trim()) }
            .toSet()
        return AgentProvider.swarmGlyphProviders.filter { selected.contains(it) }.toSet()
    }
}

/** Composable shorthand helper to observe global Premium SOTA UX setting. */
@Composable
fun rememberPremiumSOTAUX(): State<Boolean> = remember { GlobalVisualSettings.usePremiumSOTAUX }

/** Composable shorthand helper to observe global Website Background setting. */
@Composable
fun rememberWebsiteBackground(): State<Boolean> = remember { GlobalVisualSettings.useWebsiteBackground }

/** Composable shorthand helper to observe global Swarm Sparkles setting. */
@Composable
fun rememberSwarmSparkles(): State<Boolean> = remember { GlobalVisualSettings.enableSwarmSparkles }

/** Composable shorthand helper to observe global Exclude Brand Shapes setting. */
@Composable
fun rememberExcludeBrandShapesFromSwarm(): State<Boolean> = remember { GlobalVisualSettings.excludeBrandShapesFromSwarm }

@Composable
fun rememberThemePalette(): State<String> = remember { GlobalVisualSettings.themePalette }

@Composable
fun rememberProviderGlyphs(): State<Set<AgentProvider>> = remember { GlobalVisualSettings.providerGlyphs }

enum class AppThemePalette(val displayName: String) {
    System("System"), AuroraTeal("Aurora"), Crimson("Crimson"),
    CyberpunkViolet("Cyberpunk"), ForestMoss("Moss"), SolarFlare("Solar")
}

enum class AppDestination(val id: String, val label: String) {
    Pulse("pulse", "Pulse"), Burn("burn", "Burn"), Insights("insights", "Insights"),
    Streams("streams", "Streams"), Agents("agents", "Agents"), You("you", "You"),
    Settings("settings", "Settings"), Devices("devices", "Devices"), Providers("providers", "Providers")
}
