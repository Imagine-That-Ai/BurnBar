package com.openburnbar.data.hermes

/**
 * Cross-platform model for "which chat tiles appear in the chat section" and
 * "which Hermes sub-providers are visible inside the Hermes model picker."
 *
 * On-disk shape mirrors Swift `ChatTilePreferences`:
 *   {
 *     "hermesSubProviders": ["codex", "claude", ...],
 *     "tiles": ["hermes", "pi", ...]
 *   }
 *
 * Persisted by the chat settings screen via SharedPreferences under
 * [USER_DEFAULTS_KEY]. The encoder/decoder is hand-rolled so it runs in plain
 * JVM unit tests (no `org.json` runtime dependency).
 */
data class ChatTilePreferences(
    val enabledTiles: Set<AssistantRuntimeID> = AssistantRuntimeID.defaultEnabledTiles,
    val enabledHermesSubProviders: Set<HermesSubProvider> = HermesSubProvider.defaultVisible,
    val selectedHermesModelOverride: String? = null
) {
    fun withTile(id: AssistantRuntimeID, enabled: Boolean): ChatTilePreferences {
        val next = if (enabled) enabledTiles + id else enabledTiles - id
        return copy(enabledTiles = next.ifEmpty { setOf(AssistantRuntimeID.HERMES) })
    }

    fun withHermesSubProvider(provider: HermesSubProvider, enabled: Boolean): ChatTilePreferences {
        val next = if (enabled) enabledHermesSubProviders + provider else enabledHermesSubProviders - provider
        return copy(enabledHermesSubProviders = next)
    }

    fun setSelectedHermesModel(id: String?): ChatTilePreferences =
        copy(selectedHermesModelOverride = id?.trim()?.takeIf { it.isNotEmpty() })

    fun sanitized(): ChatTilePreferences =
        if (enabledTiles.isEmpty()) copy(enabledTiles = setOf(AssistantRuntimeID.HERMES)) else this

    fun orderedVisibleTiles(): List<AssistantRuntimeID> =
        AssistantRuntimeID.values().filter { enabledTiles.contains(it) }

    fun orderedVisibleHermesSubProviders(): List<HermesSubProvider> =
        HermesSubProvider.values().filter { enabledHermesSubProviders.contains(it) }

    /**
     * Encodes to the deterministic JSON shape shared with iOS/macOS:
     *   {"hermesSubProviders":["claude","codex",...],"tiles":["codex","hermes"]}
     * Tokens are simple `[a-z]+` so we can serialize manually.
     */
    fun toJsonString(): String {
        val subs = enabledHermesSubProviders
            .map { "\"${it.token}\"" }
            .sorted()
            .joinToString(",")
        val tiles = enabledTiles
            .map { "\"${it.token}\"" }
            .sorted()
            .joinToString(",")
        val selected = selectedHermesModelOverride
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { ",\"selectedHermesModelOverride\":\"${escapeJsonString(it)}\"" }
            .orEmpty()
        return "{\"hermesSubProviders\":[$subs]$selected,\"tiles\":[$tiles]}"
    }

    companion object {
        /** SharedPreferences key — mirrors iOS `ChatTilePreferencesStorage.userDefaultsKey`. */
        const val USER_DEFAULTS_KEY = "chat.tile_preferences.v1"

        val DEFAULT = ChatTilePreferences()

        fun fromJsonString(raw: String?): ChatTilePreferences {
            val trimmed = raw?.trim().orEmpty()
            if (trimmed.isEmpty() || !trimmed.startsWith("{")) return DEFAULT

            val tileTokens = extractStringArray(trimmed, "tiles")
            val subTokens = extractStringArray(trimmed, "hermesSubProviders")
            val selectedModel = extractStringValue(trimmed, "selectedHermesModelOverride")

            val tiles = tileTokens
                .mapNotNull { token -> AssistantRuntimeID.values().firstOrNull { it.token == token } }
                .toSet()
            val subs = subTokens
                .mapNotNull { HermesSubProvider.fromToken(it) }
                .toSet()

            // tileTokens.isEmpty == "tiles key was absent or empty array" — fall
            // back to defaults. When tiles WERE provided but all unknown, the
            // empty result honors user intent and is then sanitized to Hermes.
            return ChatTilePreferences(
                enabledTiles = if (tileTokens.isEmpty()) AssistantRuntimeID.defaultEnabledTiles else tiles.ifEmpty { setOf(AssistantRuntimeID.HERMES) },
                enabledHermesSubProviders = if (subTokens.isEmpty()) HermesSubProvider.defaultVisible else subs,
                selectedHermesModelOverride = selectedModel?.takeIf { it.isNotBlank() }
            )
        }

        private fun escapeJsonString(value: String): String =
            value
                .replace("\\", "\\\\")
                .replace("\"", "\\\"")

        /**
         * Extracts a `["a","b","c"]` array for [key] without an `org.json`
         * dependency. Returns an empty list if the key is absent or the array
         * is empty. Robust against whitespace, but does not handle escapes —
         * acceptable because the only values we write are `[a-z]+` tokens.
         */
        private fun extractStringArray(json: String, key: String): List<String> {
            val keyPattern = "\"$key\""
            val keyIdx = json.indexOf(keyPattern)
            if (keyIdx < 0) return emptyList()
            val arrStart = json.indexOf('[', startIndex = keyIdx)
            if (arrStart < 0) return emptyList()
            val arrEnd = json.indexOf(']', startIndex = arrStart)
            if (arrEnd < 0) return emptyList()
            val inner = json.substring(arrStart + 1, arrEnd).trim()
            if (inner.isEmpty()) return emptyList()
            return inner.split(',')
                .map { it.trim().trim('"') }
                .filter { it.isNotEmpty() }
        }

        private fun extractStringValue(json: String, key: String): String? {
            val keyPattern = "\"$key\""
            val keyIdx = json.indexOf(keyPattern)
            if (keyIdx < 0) return null
            val colonIdx = json.indexOf(':', startIndex = keyIdx)
            if (colonIdx < 0) return null
            val valueStart = json.indexOf('"', startIndex = colonIdx + 1)
            if (valueStart < 0) return null
            val builder = StringBuilder()
            var escaped = false
            var idx = valueStart + 1
            while (idx < json.length) {
                val ch = json[idx]
                if (escaped) {
                    builder.append(ch)
                    escaped = false
                } else if (ch == '\\') {
                    escaped = true
                } else if (ch == '"') {
                    return builder.toString()
                } else {
                    builder.append(ch)
                }
                idx += 1
            }
            return null
        }
    }
}
