package com.openburnbar.ui.settings

import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf

internal object GlobalVisualSettingsTabs {
    private const val KEY_PRIMARY_TABS = "primaryTabs"
    private const val KEY_SECONDARY_TABS = "secondaryTabs"
    private const val KEY_REMOVED_TABS = "removedTabs"

    // `inbox` sits third: after the two numbers surfaces the user opens on
    // purpose, and ahead of everything they browse. It is the one tab whose
    // content arrives without being asked for, so it has to be reachable
    // without a scan.
    //
    // The vocabulary is `BurnBarTab.route` strings. The stored default used to
    // say `agents` where the route is `hermes`, which silently pushed the
    // Assistants tab to the end of the tray on every install; reads now map
    // that legacy token forward (see [normalizeTabTokens]).
    private const val DEFAULT_PRIMARY_TABS = "pulse,burn,inbox,insights,streams,hermes"
    private const val DEFAULT_SECONDARY_TABS = "you,providers,devices,settings"
    private const val DEFAULT_REMOVED_TABS = ""

    /**
     * Legacy pref tokens → current `BurnBarTab.route` strings. `agents` is the
     * pre-rename Assistants token; anything else passes through unchanged (the
     * tab resolver drops tokens it does not recognize).
     */
    private val LEGACY_TOKEN_ALIASES = mapOf("agents" to "hermes")

    private val _primaryTabs = mutableStateOf(DEFAULT_PRIMARY_TABS)
    private val _secondaryTabs = mutableStateOf(DEFAULT_SECONDARY_TABS)
    private val _removedTabs = mutableStateOf(DEFAULT_REMOVED_TABS)

    val primaryTabs: State<String> get() = _primaryTabs
    val secondaryTabs: State<String> get() = _secondaryTabs

    /**
     * Comma-separated routes the user explicitly removed from the tray.
     * Tracked separately from the order strings so "removed" and "not yet
     * known" stay distinct states: a default tab absent from [primaryTabs]
     * is re-appended by the merge unless its route is listed here.
     */
    val removedTabs: State<String> get() = _removedTabs

    /** Splits a stored order string into normalized route tokens. */
    fun tabTokens(value: String): List<String> = value.split(",")
        .map { LEGACY_TOKEN_ALIASES[it.trim()] ?: it.trim() }
        .filter { it.isNotEmpty() }

    private fun normalizeTabTokens(value: String): String = tabTokens(value).joinToString(",")

    fun loadFromPrefs(prefs: android.content.SharedPreferences) {
        _primaryTabs.value =
            normalizeTabTokens(prefs.getString(KEY_PRIMARY_TABS, DEFAULT_PRIMARY_TABS) ?: DEFAULT_PRIMARY_TABS)
        _secondaryTabs.value =
            normalizeTabTokens(prefs.getString(KEY_SECONDARY_TABS, DEFAULT_SECONDARY_TABS) ?: DEFAULT_SECONDARY_TABS)
        _removedTabs.value =
            normalizeTabTokens(prefs.getString(KEY_REMOVED_TABS, DEFAULT_REMOVED_TABS) ?: DEFAULT_REMOVED_TABS)
    }

    fun setPrimaryTabs(value: String) {
        val normalized = normalizeTabTokens(value)
        _primaryTabs.value = normalized
        GlobalVisualSettingsPersistence.persistString(KEY_PRIMARY_TABS, normalized)
    }

    fun setSecondaryTabs(value: String) {
        val normalized = normalizeTabTokens(value)
        _secondaryTabs.value = normalized
        GlobalVisualSettingsPersistence.persistString(KEY_SECONDARY_TABS, normalized)
    }

    fun setRemovedTabs(routes: Collection<String>) {
        val normalized = tabTokens(routes.joinToString(",")).distinct().joinToString(",")
        _removedTabs.value = normalized
        GlobalVisualSettingsPersistence.persistString(KEY_REMOVED_TABS, normalized)
    }

    fun addRemovedTab(route: String) {
        setRemovedTabs(tabTokens(_removedTabs.value) + route)
    }

    fun clearRemovedTab(route: String) {
        setRemovedTabs(tabTokens(_removedTabs.value).filter { it != route })
    }
}
