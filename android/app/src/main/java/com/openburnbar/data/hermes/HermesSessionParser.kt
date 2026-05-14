package com.openburnbar.data.hermes

import org.json.JSONArray
import org.json.JSONObject

/**
 * Tolerant JSON parsers for the Hermes `/api/sessions` endpoints. The
 * server schema has shifted across versions, so each field has multiple
 * fallback keys that match the iOS implementation byte-for-byte.
 */
object HermesSessionParser {

    /** One message persisted on a Hermes session detail document. */
    data class StoredMessage(
        val id: String?,
        val role: String,
        val text: String,
        val modelName: String?,
        val timestampMillis: Long?
    )

    fun parseSessions(body: String): List<HermesSessionSummary> {
        val array = parseArrayBody(body) { it.optJSONArray("sessions") ?: it.optJSONArray("data") }
            ?: return emptyList()
        return (0 until array.length()).mapNotNull { index ->
            val obj = array.optJSONObject(index) ?: return@mapNotNull null
            parseSummary(obj)
        }
    }

    fun parseSessionMessages(body: String): List<StoredMessage> {
        val array = parseArrayBody(body) { root ->
            root.optJSONArray("messages")
                ?: root.optJSONObject("session")?.optJSONArray("messages")
                ?: root.optJSONArray("data")
        } ?: return emptyList()
        return (0 until array.length()).mapNotNull { index ->
            val obj = array.optJSONObject(index) ?: return@mapNotNull null
            parseStoredMessage(obj)
        }
    }

    /**
     * Accept either a JSON object that contains the array under one of the
     * keyed paths returned by [pickFromObject], or a bare JSON array body.
     */
    private inline fun parseArrayBody(body: String, pickFromObject: (JSONObject) -> JSONArray?): JSONArray? {
        val trimmed = body.trim()
        if (trimmed.isEmpty()) return null
        return runCatching { JSONObject(trimmed) }.getOrNull()?.let(pickFromObject)
            ?: runCatching { JSONArray(trimmed) }.getOrNull()
    }

    private fun parseSummary(obj: JSONObject): HermesSessionSummary? {
        val id = (obj.optStringOrNull("id")
            ?: obj.optStringOrNull("session_id")
            ?: obj.optStringOrNull("sessionId"))
            ?: return null
        return HermesSessionSummary(
            id = id,
            title = obj.optStringOrNull("title") ?: obj.optStringOrNull("name"),
            preview = obj.optStringOrNull("preview") ?: obj.optStringOrNull("summary"),
            source = obj.optStringOrNull("source"),
            model = obj.optStringOrNull("model") ?: obj.optStringOrNull("model_id"),
            startedAt = obj.optTimestampMillis("started_at", "startedAt", "created_at", "createdAt"),
            lastActiveAt = obj.optTimestampMillis("last_active_at", "lastActiveAt", "updated_at", "updatedAt"),
            endedAt = obj.optTimestampMillis("ended_at", "endedAt"),
            isActive = obj.optBoolean("is_active", obj.optBoolean("isActive", false)),
            messageCount = obj.optInt("message_count", obj.optInt("messageCount", 0)),
            toolCallCount = obj.optInt("tool_call_count", obj.optInt("toolCallCount", 0)),
            inputTokens = obj.optInt("input_tokens", obj.optInt("inputTokens", 0)),
            outputTokens = obj.optInt("output_tokens", obj.optInt("outputTokens", 0))
        )
    }

    private fun parseStoredMessage(obj: JSONObject): StoredMessage? {
        val role = obj.optStringOrNull("role") ?: obj.optStringOrNull("author") ?: "assistant"
        val text = obj.optStringOrNull("content")
            ?: obj.optStringOrNull("text")
            ?: obj.optStringOrNull("body")
            ?: (obj.optJSONArray("content")?.let { stringifyContent(it) })
            ?: ""
        if (role.isBlank() && text.isBlank()) return null
        return StoredMessage(
            id = obj.optStringOrNull("id"),
            role = role,
            text = text,
            modelName = obj.optStringOrNull("model") ?: obj.optStringOrNull("model_id"),
            timestampMillis = obj.optTimestampMillis("timestamp", "created_at", "createdAt", "ts")
        )
    }

    private fun stringifyContent(array: JSONArray): String {
        val parts = mutableListOf<String>()
        for (i in 0 until array.length()) {
            val item = array.opt(i)
            when (item) {
                is String -> parts.add(item)
                is JSONObject -> {
                    val text = item.optStringOrNull("text") ?: item.optStringOrNull("content")
                    if (!text.isNullOrEmpty()) parts.add(text)
                }
                else -> Unit
            }
        }
        return parts.joinToString("\n")
    }
}

private fun JSONObject.optStringOrNull(key: String): String? {
    if (!has(key) || isNull(key)) return null
    val value = optString(key)
    return value.takeIf { it.isNotEmpty() }
}

/** Tolerant numeric → epoch-millis converter. */
private fun JSONObject.optTimestampMillis(vararg keys: String): Long? {
    for (key in keys) {
        if (!has(key) || isNull(key)) continue
        val raw = opt(key) ?: continue
        val millis = when (raw) {
            is Number -> {
                val n = raw.toLong()
                if (n > 10_000_000_000L) n else n * 1000L
            }
            is String -> {
                val n = raw.toDoubleOrNull() ?: continue
                if (n > 10_000_000_000.0) n.toLong() else (n * 1000).toLong()
            }
            else -> continue
        }
        return millis
    }
    return null
}
