package com.openburnbar.data.stores

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.QuotaBucket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/** Time-window classification used by the provider quota UI. */
enum class QuotaWindowKind {
    FIVE_HOUR,
    DAILY,
    SEVEN_DAY,
    MONTHLY,
    REQUEST,
    OTHER,
    ;

    val shortLabel: String
        get() =
            when (this) {
                FIVE_HOUR -> "5h"
                DAILY -> "1d"
                SEVEN_DAY -> "7d"
                MONTHLY -> "30d"
                REQUEST -> "req"
                OTHER -> "—"
            }

    val displayLabel: String
        get() =
            when (this) {
                FIVE_HOUR -> "5-hour"
                DAILY -> "daily"
                SEVEN_DAY -> "weekly"
                MONTHLY -> "monthly"
                REQUEST -> "requests"
                OTHER -> "quota"
            }

    companion object {
        /** Infer the window kind from a [QuotaBucket]'s name / window strings. */
        fun infer(bucket: QuotaBucket): QuotaWindowKind {
            val name = bucket.name.trim().lowercase()
            val window = bucket.window?.trim()?.lowercase().orEmpty()
            return when {
                name.contains("five") || name.contains("5h") || window.contains("5h") ||
                    window.contains("5_hour") || window.contains("five") -> FIVE_HOUR
                name.contains("seven") || name.contains("week") ||
                    window.contains("week") || name.contains("7d") || window.contains("7d") -> SEVEN_DAY
                name.contains("month") || window.contains("month") || window.contains("30d") -> MONTHLY
                name.contains("request") || name.contains("rpm") || window.contains("request") -> REQUEST
                name.contains("day") || window.contains("day") || name.contains("1d") -> DAILY
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

    val defaultWindow: StateFlow<QuotaWindowKind> =
        context.dataStore.data
            .map { prefs ->
                when (prefs[KEY_DEFAULT_WINDOW]) {
                    QuotaWindowKind.SEVEN_DAY.name -> QuotaWindowKind.SEVEN_DAY
                    else -> QuotaWindowKind.FIVE_HOUR
                }
            }
            .stateIn(scope, SharingStarted.Eagerly, QuotaWindowKind.FIVE_HOUR)

    val providerOrder: StateFlow<List<AgentProvider>> =
        context.dataStore.data
            .map { prefs ->
                parseProviderOrder(prefs[KEY_PROVIDER_ORDER_CSV])
            }
            .stateIn(scope, SharingStarted.Eagerly, defaultOrder)

    val visibleProviders: StateFlow<Set<AgentProvider>> =
        context.dataStore.data
            .map { prefs ->
                parseVisibleProviders(prefs[KEY_VISIBLE_PROVIDERS_CSV])
            }
            .stateIn(scope, SharingStarted.Eagerly, defaultOrder.toSet())

    val hiddenBuckets: StateFlow<Set<String>> =
        context.dataStore.data
            .map { prefs ->
                parseHiddenBuckets(prefs[KEY_HIDDEN_BUCKETS_JSON])
            }
            .stateIn(scope, SharingStarted.Eagerly, emptySet())

    val bucketOrders: StateFlow<Map<String, List<String>>> =
        context.dataStore.data
            .map { prefs ->
                parseBucketOrders(prefs[KEY_BUCKET_ORDERS_JSON])
            }
            .stateIn(scope, SharingStarted.Eagerly, emptyMap())

    val percentageDisplayMode: StateFlow<String> =
        context.dataStore.data
            .map { prefs ->
                prefs[KEY_PERCENTAGE_DISPLAY_MODE] ?: "remainingPercent"
            }
            .stateIn(scope, SharingStarted.Eagerly, "remainingPercent")

    // Persisted per-device Burn view style, stored as a raw key (e.g. "cards",
    // "grid") so this data layer stays decoupled from the UI `BurnViewStyle`.
    val burnViewStyle: StateFlow<String> =
        context.dataStore.data
            .map { prefs ->
                prefs[KEY_BURN_VIEW_STYLE] ?: "cards"
            }
            .stateIn(scope, SharingStarted.Eagerly, "cards")

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

    fun setProviderOrder(order: List<AgentProvider>) {
        scope.launch {
            context.dataStore.edit { prefs ->
                prefs[KEY_PROVIDER_ORDER_CSV] = order.joinToString(",") { it.key }
            }
        }
    }

    fun setVisibleProviders(visible: Set<AgentProvider>) {
        scope.launch {
            context.dataStore.edit { prefs ->
                prefs[KEY_VISIBLE_PROVIDERS_CSV] = visible.joinToString(",") { it.key }
            }
        }
    }

    fun setHiddenBuckets(hidden: Set<String>) {
        scope.launch {
            context.dataStore.edit { prefs ->
                prefs[KEY_HIDDEN_BUCKETS_JSON] = serializeHiddenBuckets(hidden)
            }
        }
    }

    fun setBucketOrders(orders: Map<String, List<String>>) {
        scope.launch {
            context.dataStore.edit { prefs ->
                prefs[KEY_BUCKET_ORDERS_JSON] = serializeBucketOrders(orders)
            }
        }
    }

    fun setPercentageDisplayMode(mode: String) {
        scope.launch {
            context.dataStore.edit { prefs ->
                prefs[KEY_PERCENTAGE_DISPLAY_MODE] = mode
            }
        }
    }

    fun setBurnViewStyle(key: String) {
        scope.launch {
            context.dataStore.edit { prefs ->
                prefs[KEY_BURN_VIEW_STYLE] = key
            }
        }
    }

    private fun parseProviderOrder(csv: String?): List<AgentProvider> {
        if (csv.isNullOrBlank()) return defaultOrder
        val parsed = csv.split(",").map { it.trim().lowercase() }.mapNotNull { AgentProvider.fromKey(it) }
        if (parsed.isEmpty()) return defaultOrder
        val deduped = parsed.distinct().toMutableList()
        for (provider in defaultOrder) {
            if (provider !in deduped) {
                deduped.add(provider)
            }
        }
        return deduped
    }

    private fun parseVisibleProviders(csv: String?): Set<AgentProvider> {
        if (csv.isNullOrBlank()) return defaultOrder.toSet()
        val parsed = csv.split(",").map { it.trim().lowercase() }.mapNotNull { AgentProvider.fromKey(it) }
        if (parsed.isEmpty()) return defaultOrder.toSet()
        return parsed.toSet()
    }

    private fun parseHiddenBuckets(json: String?): Set<String> {
        if (json.isNullOrBlank()) return emptySet()
        return try {
            val array = JSONArray(json)
            val result = mutableSetOf<String>()
            for (i in 0 until array.length()) {
                result.add(array.getString(i))
            }
            result
        } catch (_: IllegalStateException) {
            emptySet()
        }
    }

    private fun serializeHiddenBuckets(set: Set<String>): String {
        val array = JSONArray()
        set.forEach { array.put(it) }
        return array.toString()
    }

    private fun parseBucketOrders(json: String?): Map<String, List<String>> {
        if (json.isNullOrBlank()) return emptyMap()
        return try {
            val obj = JSONObject(json)
            val result = mutableMapOf<String, List<String>>()
            val keys = obj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                val array = obj.getJSONArray(key)
                val list = mutableListOf<String>()
                for (i in 0 until array.length()) {
                    list.add(array.getString(i))
                }
                result[key] = list
            }
            result
        } catch (_: IllegalStateException) {
            emptyMap()
        }
    }

    private fun serializeBucketOrders(map: Map<String, List<String>>): String {
        val obj = JSONObject()
        map.forEach { (key, list) ->
            val array = JSONArray()
            list.forEach { array.put(it) }
            obj.put(key, array)
        }
        return obj.toString()
    }

    companion object {
        private val Context.dataStore by preferencesDataStore("burnbar.quota.prefs")
        private val KEY_DEFAULT_WINDOW = stringPreferencesKey("default_window")

        private val KEY_PROVIDER_ORDER_CSV = stringPreferencesKey("quota_providerOrderCSV")
        private val KEY_VISIBLE_PROVIDERS_CSV = stringPreferencesKey("quota_visibleProvidersCSV")
        private val KEY_HIDDEN_BUCKETS_JSON = stringPreferencesKey("quota_hiddenBucketsJSON")
        private val KEY_BUCKET_ORDERS_JSON = stringPreferencesKey("quota_bucketOrdersJSON")
        private val KEY_PERCENTAGE_DISPLAY_MODE = stringPreferencesKey("quota_percentageDisplayMode")
        private val KEY_BURN_VIEW_STYLE = stringPreferencesKey("quota_burnViewStyle")

        val defaultOrder =
            listOf(
                AgentProvider.CODEX,
                AgentProvider.OPENCODE,
                AgentProvider.CLAUDE_CODE,
                AgentProvider.OPEN_AI,
                AgentProvider.DEEP_SEEK,
                AgentProvider.COPILOT,
                AgentProvider.MINIMAX,
                AgentProvider.ZAI,
                AgentProvider.FACTORY,
                AgentProvider.CURSOR,
                AgentProvider.WARP,
                AgentProvider.OLLAMA,
                AgentProvider.KIMI,
                AgentProvider.ANTIGRAVITY,
                AgentProvider.XAI,
                AgentProvider.MIMO,
            )

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
