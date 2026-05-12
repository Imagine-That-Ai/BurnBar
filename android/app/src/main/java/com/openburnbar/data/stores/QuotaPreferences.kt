package com.openburnbar.data.stores

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.openburnbar.data.models.QuotaBucket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** Time-window classification used by the provider quota UI. */
enum class QuotaWindowKind {
    FIVE_HOUR,
    DAILY,
    SEVEN_DAY,
    MONTHLY,
    REQUEST,
    OTHER;

    val shortLabel: String
        get() = when (this) {
            FIVE_HOUR -> "5h"
            DAILY     -> "1d"
            SEVEN_DAY -> "7d"
            MONTHLY   -> "30d"
            REQUEST   -> "req"
            OTHER     -> "—"
        }

    val displayLabel: String
        get() = when (this) {
            FIVE_HOUR -> "5-hour"
            DAILY     -> "daily"
            SEVEN_DAY -> "weekly"
            MONTHLY   -> "monthly"
            REQUEST   -> "requests"
            OTHER     -> "quota"
        }

    companion object {
        /** Infer the window kind from a [QuotaBucket]'s name / window strings. */
        fun infer(bucket: QuotaBucket): QuotaWindowKind {
            val name = bucket.name.trim().lowercase()
            val window = bucket.window?.trim()?.lowercase().orEmpty()
            return when {
                (name.contains("five") || name.contains("5h") || window.contains("5h") ||
                    window.contains("5_hour") || window.contains("five")) -> FIVE_HOUR
                (name.contains("seven") || name.contains("week") ||
                    window.contains("week") || name.contains("7d") || window.contains("7d")) -> SEVEN_DAY
                (name.contains("month") || window.contains("month") || window.contains("30d")) -> MONTHLY
                (name.contains("request") || name.contains("rpm") || window.contains("request")) -> REQUEST
                (name.contains("day") || window.contains("day") || name.contains("1d")) -> DAILY
                else -> OTHER
            }
        }
    }
}

/**
 * Persists the user's preferred default bucket window for provider quota
 * cards (5-hour vs 7-day). Backed by DataStore so the choice survives across
 * launches. Reads/writes are scoped to a process-wide actor instead of any
 * single composable so the value stays sticky if YouView is rebuilt.
 */
class QuotaPreferences private constructor(private val context: Context) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val defaultWindow: StateFlow<QuotaWindowKind> = context.dataStore.data
        .map { prefs ->
            when (prefs[KEY_DEFAULT_WINDOW]) {
                QuotaWindowKind.SEVEN_DAY.name -> QuotaWindowKind.SEVEN_DAY
                else -> QuotaWindowKind.FIVE_HOUR
            }
        }
        .stateIn(scope, SharingStarted.Eagerly, QuotaWindowKind.FIVE_HOUR)

    fun setDefaultWindow(kind: QuotaWindowKind) {
        // Only FIVE_HOUR and SEVEN_DAY are user-selectable presets — anything
        // else collapses to FIVE_HOUR (the iOS default).
        val sanitized = if (kind == QuotaWindowKind.SEVEN_DAY) kind else QuotaWindowKind.FIVE_HOUR
        scope.launch {
            context.dataStore.edit { prefs ->
                prefs[KEY_DEFAULT_WINDOW] = sanitized.name
            }
        }
    }

    companion object {
        private val Context.dataStore by preferencesDataStore("burnbar.quota.prefs")
        private val KEY_DEFAULT_WINDOW = stringPreferencesKey("default_window")

        @Volatile private var instance: QuotaPreferences? = null

        fun get(context: Context): QuotaPreferences = instance ?: synchronized(this) {
            instance ?: QuotaPreferences(context.applicationContext).also { instance = it }
        }
    }
}

@Composable
fun rememberQuotaDefaultWindow(): State<QuotaWindowKind> {
    val context = LocalContext.current
    val prefs = remember(context) { QuotaPreferences.get(context) }
    return prefs.defaultWindow.collectAsState()
}
