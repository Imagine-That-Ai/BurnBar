package com.openburnbar.ui.settings

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.theme.UIMode

/**
 * Thread-safe singleton manager for global visual settings in the Android app.
 * Automatically persists to standard SharedPreferences and provides Compose-state
 * properties that trigger UI recomposition instantly when updated.
 */
object GlobalVisualSettings {
    private const val PREFS_NAME = "global_visual_settings"
    private const val KEY_PREMIUM_SOTA_UX = "usePremiumSOTAUX"
    private const val KEY_WEBSITE_BACKGROUND = "useWebsiteBackground"
    private const val KEY_BACKGROUND_STYLE = "backgroundStyle"
    private const val KEY_SWARM_SPARKLES = "enableSwarmSparkles"
    private const val KEY_PROVIDER_GLYPHS = "providerGlyphs"
    private const val KEY_EXCLUDE_BRAND_SHAPES = "excludeBrandShapesFromSwarm"

    private var loaded = false

    private val prefs by lazy {
        BurnBarApplication.appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    // Underlying Compose mutable states to trigger reactive updates globally.
    private val _usePremiumSOTAUX = mutableStateOf(false)
    private val _backgroundStyle = mutableStateOf(BackgroundStyle.AURORA)
    // Derived flag kept for back-compat: callers across the app read this to know a
    // custom dark backdrop is active (so they flip text to white / drop solid fills).
    // Both swarm and constellation styles paint a dark, content-behind backdrop.
    private val _useWebsiteBackground = mutableStateOf(false)
    private val _enableSwarmSparkles = mutableStateOf(true)
    private val _providerGlyphs = mutableStateOf(AgentProvider.swarmGlyphProviders.toSet())
    private val _excludeBrandShapesFromSwarm = mutableStateOf(false)

    private fun ensureLoaded() {
        if (!loaded) {
            try {
                // Safely load initial persisted values if appContext is ready.
                _usePremiumSOTAUX.value = prefs.getBoolean(KEY_PREMIUM_SOTA_UX, false)
                // Migrate the legacy boolean toggle into the richer style enum: an
                // explicit style key wins, otherwise fall back to the old boolean.
                val storedStyle = prefs.getString(KEY_BACKGROUND_STYLE, null)
                val migratedStyle =
                    BackgroundStyle.fromKey(storedStyle)
                        ?: if (prefs.getBoolean(KEY_WEBSITE_BACKGROUND, false)) {
                            BackgroundStyle.SWARM
                        } else {
                            BackgroundStyle.AURORA
                        }
                _backgroundStyle.value = migratedStyle
                _useWebsiteBackground.value = migratedStyle.usesCustomBackdrop
                _enableSwarmSparkles.value = prefs.getBoolean(KEY_SWARM_SPARKLES, true)
                _excludeBrandShapesFromSwarm.value = prefs.getBoolean(KEY_EXCLUDE_BRAND_SHAPES, false)
                GlobalVisualSettingsPalette.loadFromPrefs(prefs)
                GlobalVisualSettingsUIMode.loadFromPrefs(prefs)
                _providerGlyphs.value = decodeProviderGlyphs(prefs.getString(KEY_PROVIDER_GLYPHS, null))
                GlobalVisualSettingsTabs.loadFromPrefs(prefs)
                loaded = true
            } catch (_: Throwable) {
                // If lateinit appContext is not initialized yet, swallow and retry on next access
            }
        }
    }

    /** Exposes read-only access to Premium SOTA UX setting. */
    val usePremiumSOTAUX: State<Boolean> get() {
        ensureLoaded()
        return _usePremiumSOTAUX
    }

    /**
     * Exposes read-only access to the selected background style. AURORA is the
     * classic gradient/orb backdrop; SWARM is the reconverging token-ember swarm;
     * DOT_CONSTELLATION is the calm ambient field that resolves one logo at a time.
     */
    val backgroundStyle: State<BackgroundStyle> get() {
        ensureLoaded()
        return _backgroundStyle
    }

    /**
     * Exposes read-only access to the legacy Website Background flag. Derived from
     * [backgroundStyle]: true whenever a custom dark backdrop (swarm or
     * constellation) is active, which the app's screens read to switch text/fills.
     */
    val useWebsiteBackground: State<Boolean> get() {
        ensureLoaded()
        return _useWebsiteBackground
    }

    /** Exposes read-only access to Swarm Sparkles setting. */
    val enableSwarmSparkles: State<Boolean> get() {
        ensureLoaded()
        return _enableSwarmSparkles
    }

    /** Exposes read-only access to Exclude Brand Shapes setting. */
    val excludeBrandShapesFromSwarm: State<Boolean> get() {
        ensureLoaded()
        return _excludeBrandShapesFromSwarm
    }

    /** Exposes app-wide provider glyph filters for live swarm backgrounds. */
    val providerGlyphs: State<Set<AgentProvider>> get() {
        ensureLoaded()
        return _providerGlyphs
    }

    fun setProviderGlyphs(value: Set<AgentProvider>) {
        ensureLoaded()
        val normalized = AgentProvider.swarmGlyphProviders.filter { value.contains(it) }.toSet()
        _providerGlyphs.value = normalized
        try {
            prefs.edit().putString(KEY_PROVIDER_GLYPHS, encodeProviderGlyphs(normalized)).apply()
        } catch (_: Throwable) {
        }
    }

    /** Sets the Premium SOTA UX value and persists it. */
    fun setPremiumSOTAUX(value: Boolean) {
        ensureLoaded()
        _usePremiumSOTAUX.value = value
        try {
            prefs.edit().putBoolean(KEY_PREMIUM_SOTA_UX, value).apply()
        } catch (_: Throwable) {
        }
    }

    /** Selects a background style and persists it (keeps the legacy flag in sync). */
    fun setBackgroundStyle(value: BackgroundStyle) {
        ensureLoaded()
        _backgroundStyle.value = value
        _useWebsiteBackground.value = value.usesCustomBackdrop
        try {
            prefs.edit()
                .putString(KEY_BACKGROUND_STYLE, value.key)
                // Mirror into the legacy boolean so older reads/migrations stay coherent.
                .putBoolean(KEY_WEBSITE_BACKGROUND, value.usesCustomBackdrop)
                .apply()
        } catch (_: Throwable) {
        }
    }

    /**
     * Sets the legacy Website Background value and persists it. Retained for
     * back-compat: maps the boolean onto the style enum (SWARM ↔ AURORA) while
     * preserving the constellation choice when toggling off from it.
     */
    fun setWebsiteBackground(value: Boolean) {
        ensureLoaded()
        val next =
            when {
                value -> if (_backgroundStyle.value.usesCustomBackdrop) _backgroundStyle.value else BackgroundStyle.SWARM
                else -> BackgroundStyle.AURORA
            }
        setBackgroundStyle(next)
    }

    /** Sets the Swarm Sparkles value and persists it. */
    fun setSwarmSparkles(value: Boolean) {
        ensureLoaded()
        _enableSwarmSparkles.value = value
        try {
            prefs.edit().putBoolean(KEY_SWARM_SPARKLES, value).apply()
        } catch (_: Throwable) {
        }
    }

    /** Sets the Exclude Brand Shapes value and persists it. */
    fun setExcludeBrandShapesFromSwarm(value: Boolean) {
        ensureLoaded()
        _excludeBrandShapesFromSwarm.value = value
        try {
            prefs.edit().putBoolean(KEY_EXCLUDE_BRAND_SHAPES, value).apply()
        } catch (_: Throwable) {
        }
    }

    private fun encodeProviderGlyphs(providers: Set<AgentProvider>): String = AgentProvider.swarmGlyphProviders
        .filter { providers.contains(it) }
        .joinToString(",") { it.key }

    private fun decodeProviderGlyphs(raw: String?): Set<AgentProvider> {
        if (raw == null) return AgentProvider.swarmGlyphProviders.toSet()
        if (raw.isBlank()) return emptySet()
        val selected =
            raw.split(',')
                .mapNotNull { AgentProvider.fromKey(it.trim()) }
                .toSet()
        return AgentProvider.swarmGlyphProviders.filter { selected.contains(it) }.toSet()
    }

    val primaryTabs: State<String>
        get() {
            ensureLoaded()
            return GlobalVisualSettingsTabs.primaryTabs
        }

    val secondaryTabs: State<String>
        get() {
            ensureLoaded()
            return GlobalVisualSettingsTabs.secondaryTabs
        }
}

/** Composable shorthand helper to observe global Premium SOTA UX setting. */
@Composable
fun rememberPremiumSOTAUX(): State<Boolean> = remember { GlobalVisualSettings.usePremiumSOTAUX }

/** Composable shorthand helper to observe the selected background style. */
@Composable
fun rememberBackgroundStyle(): State<BackgroundStyle> = remember { GlobalVisualSettings.backgroundStyle }

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
fun rememberThemePalette(): State<String> = remember { GlobalVisualSettingsPalette.themePalette }

@Composable
fun rememberUIMode(): State<UIMode> = remember { GlobalVisualSettingsUIMode.uiMode }

@Composable
fun rememberProviderGlyphs(): State<Set<AgentProvider>> = remember { GlobalVisualSettings.providerGlyphs }

/**
 * The selectable ambient background styles. [usesCustomBackdrop] marks the styles
 * that paint a custom dark, content-behind backdrop — the app reads this (via the
 * legacy `useWebsiteBackground` flag) to switch text/fills to high-contrast.
 */
enum class BackgroundStyle(val key: String, val displayName: String, val usesCustomBackdrop: Boolean) {
    AURORA("aurora", "Aurora", false),
    SWARM("swarm", "Swarm", true),
    DOT_CONSTELLATION("constellation", "Constellation", true),
    ;

    companion object {
        fun fromKey(key: String?): BackgroundStyle? {
            if (key.isNullOrBlank()) return null
            return entries.find { it.key == key }
        }
    }
}

enum class AppThemePalette(val displayName: String) {
    System("System"),
    AuroraTeal("Aurora"),
    Crimson("Crimson"),
    CyberpunkViolet("Cyberpunk"),
    ForestMoss("Moss"),
    SolarFlare("Solar"),
}

enum class AppDestination(val id: String, val label: String) {
    Pulse("pulse", "Pulse"),
    Burn("burn", "Burn"),
    Insights("insights", "Insights"),
    Streams("streams", "Streams"),
    Agents("agents", "Agents"),
    You("you", "You"),
    Settings("settings", "Settings"),
    Devices("devices", "Devices"),
    Providers("providers", "Providers"),
}
