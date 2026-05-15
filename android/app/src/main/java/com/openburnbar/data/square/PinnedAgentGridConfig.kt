package com.openburnbar.data.square

import com.openburnbar.data.hermes.AssistantRuntimeID
import org.json.JSONArray
import org.json.JSONObject

// MARK: - Pinned Agent Grid Config (Android parity)
//
// JSON-compatible mirror of the Swift `PinnedAgentGridConfig`. Persisted
// in SharedPreferences under `square.pinned_grid.v1`.

data class PinnedAgentGridConfig(
    val pinnedURIs: List<String> = defaultPinnedURIs(),
    val displayMode: DisplayMode = DisplayMode.COMFORTABLE,
    val lastRearrangedAtEpoch: Long? = null
) {
    enum class DisplayMode(val token: String, val columns: Int, val rows: Int) {
        COMFORTABLE("comfortable", 4, 3),
        COMPACT("compact", 6, 2);

        companion object {
            fun fromToken(value: String?): DisplayMode =
                values().firstOrNull { it.token == value } ?: COMFORTABLE
        }
    }

    fun sanitized(): PinnedAgentGridConfig {
        val seen = linkedSetOf<String>()
        val deduped = pinnedURIs.filter { uri -> seen.add(uri) }
        val trimmed = deduped.take(MAX_SLOTS)
        val nonEmpty = if (trimmed.isEmpty())
            defaultPinnedURIs().take(1)
        else trimmed
        return copy(pinnedURIs = nonEmpty)
    }

    fun pinning(uri: String): PinnedAgentGridConfig {
        if (uri in pinnedURIs || pinnedURIs.size >= MAX_SLOTS) return this
        return copy(
            pinnedURIs = pinnedURIs + uri,
            lastRearrangedAtEpoch = System.currentTimeMillis()
        )
    }

    fun unpinning(uri: String): PinnedAgentGridConfig =
        copy(
            pinnedURIs = pinnedURIs.filter { it != uri },
            lastRearrangedAtEpoch = System.currentTimeMillis()
        ).sanitized()

    fun moving(from: Int, to: Int): PinnedAgentGridConfig {
        if (pinnedURIs.isEmpty()) return this
        val safeFrom = from.coerceIn(0, pinnedURIs.size - 1)
        val safeTo = to.coerceIn(0, pinnedURIs.size)
        val mutable = pinnedURIs.toMutableList()
        val value = mutable.removeAt(safeFrom)
        mutable.add(safeTo.coerceAtMost(mutable.size), value)
        return copy(
            pinnedURIs = mutable,
            lastRearrangedAtEpoch = System.currentTimeMillis()
        )
    }

    fun toJsonString(): String {
        val obj = JSONObject()
        obj.put("displayMode", displayMode.token)
        obj.put("pinnedURIs", JSONArray(pinnedURIs))
        if (lastRearrangedAtEpoch != null) {
            obj.put("lastRearrangedAtEpoch", lastRearrangedAtEpoch)
        }
        return obj.toString()
    }

    companion object {
        const val MAX_SLOTS = 12
        const val SHARED_PREFS_KEY = "square.pinned_grid.v1"

        fun defaultPinnedURIs(): List<String> =
            AssistantRuntimeID.values().map { AgentIdentity.builtInURI(it) }

        val DEFAULT = PinnedAgentGridConfig()

        fun fromJsonString(raw: String?): PinnedAgentGridConfig {
            if (raw.isNullOrBlank()) return DEFAULT
            return runCatching {
                val obj = JSONObject(raw)
                val arr = obj.optJSONArray("pinnedURIs") ?: JSONArray()
                val uris = (0 until arr.length()).map { arr.optString(it) }
                val display = DisplayMode.fromToken(obj.optString("displayMode", "comfortable"))
                val ts = if (obj.has("lastRearrangedAtEpoch"))
                    obj.optLong("lastRearrangedAtEpoch")
                else null
                PinnedAgentGridConfig(
                    pinnedURIs = uris,
                    displayMode = display,
                    lastRearrangedAtEpoch = ts
                ).sanitized()
            }.getOrDefault(DEFAULT)
        }
    }
}
