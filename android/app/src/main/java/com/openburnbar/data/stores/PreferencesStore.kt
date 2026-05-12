package com.openburnbar.data.stores

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.*
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * DataStore-based preference persistence.
 * Theme, display mode, cloud banner dismissed, and other UI preferences.
 */

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "burnbar_preferences")

class PreferencesStore(private val context: Context) {

    private val dataStore = context.dataStore

    // Keys
    companion object Keys {
        val THEME_MODE = stringPreferencesKey("theme_mode")
        val DISPLAY_MODE = stringPreferencesKey("display_mode")
        val CLOUD_BANNER_DISMISSED = booleanPreferencesKey("cloud_banner_dismissed")
        val ONBOARDING_COMPLETED = booleanPreferencesKey("onboarding_completed")
        val LAST_SYNC_TIME = longPreferencesKey("last_sync_time")
    }

    enum class ThemeMode {
        SYSTEM, LIGHT, DARK
    }

    enum class DisplayMode {
        STANDARD, COMPACT
    }

    // ── Theme Mode ──

    val themeMode: Flow<ThemeMode> = dataStore.data.map { prefs ->
        when (prefs[THEME_MODE]) {
            "light" -> ThemeMode.LIGHT
            "dark" -> ThemeMode.DARK
            else -> ThemeMode.SYSTEM
        }
    }

    suspend fun setThemeMode(mode: ThemeMode) {
        dataStore.edit { prefs ->
            prefs[THEME_MODE] = when (mode) {
                ThemeMode.LIGHT -> "light"
                ThemeMode.DARK -> "dark"
                ThemeMode.SYSTEM -> "system"
            }
        }
    }

    // ── Display Mode ──

    val displayMode: Flow<DisplayMode> = dataStore.data.map { prefs ->
        when (prefs[DISPLAY_MODE]) {
            "compact" -> DisplayMode.COMPACT
            else -> DisplayMode.STANDARD
        }
    }

    suspend fun setDisplayMode(mode: DisplayMode) {
        dataStore.edit { prefs ->
            prefs[DISPLAY_MODE] = when (mode) {
                DisplayMode.COMPACT -> "compact"
                DisplayMode.STANDARD -> "standard"
            }
        }
    }

    // ── Cloud Banner ──

    val cloudBannerDismissed: Flow<Boolean> = dataStore.data.map { prefs ->
        prefs[CLOUD_BANNER_DISMISSED] == true
    }

    suspend fun dismissCloudBanner() {
        dataStore.edit { prefs ->
            prefs[CLOUD_BANNER_DISMISSED] = true
        }
    }

    // ── Onboarding ──

    val onboardingCompleted: Flow<Boolean> = dataStore.data.map { prefs ->
        prefs[ONBOARDING_COMPLETED] == true
    }

    suspend fun setOnboardingCompleted(completed: Boolean) {
        dataStore.edit { prefs ->
            prefs[ONBOARDING_COMPLETED] = completed
        }
    }

    // ── Last Sync Time ──

    val lastSyncTime: Flow<Long> = dataStore.data.map { prefs ->
        prefs[LAST_SYNC_TIME] ?: 0L
    }

    suspend fun setLastSyncTime(time: Long) {
        dataStore.edit { prefs ->
            prefs[LAST_SYNC_TIME] = time
        }
    }

    // ── Generic helpers ──

    fun <T> flowFor(key: Preferences.Key<T>, defaultValue: T): Flow<T> =
        dataStore.data.map { it[key] ?: defaultValue }

    suspend fun <T> setValue(key: Preferences.Key<T>, value: T) {
        dataStore.edit { it[key] = value }
    }
}
