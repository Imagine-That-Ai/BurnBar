package com.openburnbar.ui.calendar

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
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

// MARK: - Calendar Card Kind
//
// The registry of every analytics card the Calendar surface can render for
// the current day selection. Mirrors the macOS `CalendarCardKind`: each kind
// carries its own editorial metadata, and adding a card = add an entry here,
// prepare its data in `CalendarSelectionSnapshot`, and give it a renderer arm
// in `CalendarAnalyticsPanel`.

/** Grid span in columns (the analytics grid is 3 columns wide; 3 = full
 *  width). Surfaced in the UI as S/M/L sizes. */
enum class CalendarCardSpan(val columns: Int, val shortLabel: String) {
    S(1, "S"),
    M(2, "M"),
    L(3, "L"),
    ;

    fun next(): CalendarCardSpan = entries[(ordinal + 1) % entries.size]

    companion object {
        fun fromColumns(columns: Int?): CalendarCardSpan? = when (columns) {
            1 -> S
            2 -> M
            3 -> L
            else -> null
        }
    }
}

enum class CalendarCardKind(
    val key: String,
    val title: String,
    /** One-line "why it matters" — rendered as the card's footer microcopy. */
    val whyItMatters: String,
    val defaultSpan: CalendarCardSpan,
) {
    KPIS(
        "kpis",
        "Key Numbers",
        "The selection at a glance — spend, volume, sessions, cadence.",
        CalendarCardSpan.L,
    ),
    BURN_OVER_SELECTION(
        "burnOverSelection",
        "Burn Over Selection",
        "Day-by-day spend across the selected days.",
        CalendarCardSpan.L,
    ),
    PROVIDER_MIX(
        "providerMix",
        "Provider Mix",
        "Where the money actually goes across providers.",
        CalendarCardSpan.S,
    ),
    MODEL_MIX(
        "modelMix",
        "Model Mix",
        "Which models earn their keep — and which quietly dominate.",
        CalendarCardSpan.S,
    ),
    HOUR_OF_DAY_HEATMAP(
        "hourOfDayHeatmap",
        "When You Burn",
        "Your true working rhythm inside the selection.",
        CalendarCardSpan.L,
    ),
    PROJECT_FOCUS(
        "projectFocus",
        "Project Focus",
        "Which projects the selected days actually funded.",
        CalendarCardSpan.S,
    ),
    CACHE_ROI(
        "cacheROI",
        "Cache Savings",
        "Prompt caching pays rent. This is the receipt.",
        CalendarCardSpan.S,
    ),
    REASONING_SHARE(
        "reasoningShare",
        "Reasoning Share",
        "Extended thinking is a hidden line item. Watch its share.",
        CalendarCardSpan.S,
    ),
    ;

    companion object {
        fun fromKey(key: String?): CalendarCardKind? = entries.firstOrNull { it.key == key }
    }
}

// MARK: - Card configuration & page layout

/** One card's persisted state: which card, whether shown, and how wide. */
data class CalendarCardConfig(
    val kind: CalendarCardKind,
    val isVisible: Boolean = true,
    val span: CalendarCardSpan = kind.defaultSpan,
)

/**
 * The full panel layout: an ordered list of card configs, persisted as JSON
 * under [CalendarPageLayoutStore]. Same forward-compatible contract as the
 * macOS `CalendarPageLayout` — unknown kinds are dropped, missing kinds are
 * appended with defaults, so upgrades never clobber the user's arrangement.
 *
 * Instances are immutable; every mutation returns a new layout, which keeps
 * Compose state flow obvious (the screen holds one `MutableStateFlow`).
 */
data class CalendarPageLayout private constructor(val configs: List<CalendarCardConfig>) {

    /** Cards the grid actually renders, in order. */
    val visibleConfigs: List<CalendarCardConfig>
        get() = configs.filter { it.isVisible }

    val hiddenConfigs: List<CalendarCardConfig>
        get() = configs.filter { !it.isVisible }

    // MARK: Mutations

    /** Moves [kind] one slot earlier/later in the order. */
    fun move(kind: CalendarCardKind, delta: Int): CalendarPageLayout {
        val from = configs.indexOfFirst { it.kind == kind }
        if (from < 0) return this
        val to = (from + delta).coerceIn(0, configs.lastIndex)
        if (to == from) return this
        val next = configs.toMutableList()
        val config = next.removeAt(from)
        next.add(to, config)
        return CalendarPageLayout(next)
    }

    fun setVisible(kind: CalendarCardKind, visible: Boolean): CalendarPageLayout {
        val index = configs.indexOfFirst { it.kind == kind }
        if (index < 0) return this
        val next = configs.toMutableList()
        next[index] = next[index].copy(isVisible = visible)
        return CalendarPageLayout(next)
    }

    fun setSpan(kind: CalendarCardKind, span: CalendarCardSpan): CalendarPageLayout {
        val index = configs.indexOfFirst { it.kind == kind }
        if (index < 0) return this
        val next = configs.toMutableList()
        next[index] = next[index].copy(span = span)
        return CalendarPageLayout(next)
    }

    fun reset(): CalendarPageLayout = DEFAULT

    // MARK: JSON

    /** Compact JSON array: `[{"kind":"kpis","isVisible":true,"span":3}, …]`. */
    fun encode(): String {
        val array = JSONArray()
        for (config in configs) {
            array.put(
                JSONObject()
                    .put("kind", config.kind.key)
                    .put("isVisible", config.isVisible)
                    .put("span", config.span.columns),
            )
        }
        return array.toString()
    }

    companion object {
        val DEFAULT = CalendarPageLayout(CalendarCardKind.entries.map { CalendarCardConfig(kind = it) })

        /** JSON round-trip tolerant of unknown kinds and malformed payloads;
         *  anything unreadable yields [DEFAULT]. See type comment. */
        fun decode(json: String?): CalendarPageLayout {
            if (json.isNullOrBlank()) return DEFAULT
            val raw =
                try {
                    JSONArray(json)
                } catch (_: Exception) {
                    return DEFAULT
                }
            val known = mutableListOf<CalendarCardConfig>()
            for (i in 0 until raw.length()) {
                raw.optJSONObject(i)?.let { obj ->
                    CalendarCardKind.fromKey(obj.optString("kind", "").ifBlank { null })?.let { kind ->
                        val isVisible = if (obj.has("isVisible")) obj.optBoolean("isVisible", true) else true
                        val span = CalendarCardSpan.fromColumns(if (obj.has("span")) obj.optInt("span") else null)
                        known.add(CalendarCardConfig(kind = kind, isVisible = isVisible, span = span ?: kind.defaultSpan))
                    }
                }
            }
            return CalendarPageLayout(reconciled(known))
        }

        /** Deduplicates and appends any kinds missing from [configs] so every
         *  registered card always has exactly one slot. */
        private fun reconciled(configs: List<CalendarCardConfig>): List<CalendarCardConfig> {
            val seen = mutableSetOf<CalendarCardKind>()
            val result = mutableListOf<CalendarCardConfig>()
            for (config in configs) {
                if (seen.add(config.kind)) result.add(config)
            }
            for (kind in CalendarCardKind.entries) {
                if (kind !in seen) result.add(CalendarCardConfig(kind = kind))
            }
            return result
        }
    }
}

// MARK: - Persistence

/**
 * Persists the Calendar panel layout as JSON in preferences DataStore so the
 * arrangement survives across launches. Follows the `QuotaPreferences`
 * pattern: a process-wide singleton with an eager `StateFlow`, so the value
 * stays sticky if the screen is rebuilt.
 */
class CalendarPageLayoutStore private constructor(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val layout: StateFlow<CalendarPageLayout> =
        context.dataStore.data
            .map { prefs -> CalendarPageLayout.decode(prefs[KEY_PAGE_LAYOUT_JSON]) }
            .stateIn(scope, SharingStarted.Eagerly, CalendarPageLayout.DEFAULT)

    fun persist(layout: CalendarPageLayout) {
        scope.launch {
            context.dataStore.edit { prefs ->
                prefs[KEY_PAGE_LAYOUT_JSON] = layout.encode()
            }
        }
    }

    companion object {
        private val Context.dataStore by preferencesDataStore("burnbar.calendar.prefs")
        private val KEY_PAGE_LAYOUT_JSON = stringPreferencesKey("calendar_page_layout_json_v1")

        @Volatile private var instance: CalendarPageLayoutStore? = null

        fun get(context: Context): CalendarPageLayoutStore = instance ?: synchronized(this) {
            instance ?: CalendarPageLayoutStore(context.applicationContext).also { instance = it }
        }
    }
}
