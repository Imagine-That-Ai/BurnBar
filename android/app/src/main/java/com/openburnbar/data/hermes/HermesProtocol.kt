package com.openburnbar.data.hermes

import com.openburnbar.irohrelay.HermesStreamEvent
import org.json.JSONArray
import org.json.JSONObject

/**
 * Pure-Kotlin helpers for the OpenAI-compatible Hermes wire protocol.
 *
 * Lives in its own file so unit tests can exercise URL normalization, SSE
 * parsing, and tolerant content extraction without spinning up [HermesService]
 * (which depends on an Android `Context` and an `OkHttpClient`).
 *
 * Mirrors the iOS `HermesService` parser tolerance:
 *   - delta.content (string or array of {text|content})
 *   - message.content (string or array of {text|content})
 *   - choice.text
 *   - top-level content / output_text / text
 *
 * URL normalization mirrors iOS `validatedEndpointURL`:
 *   - http://localhost or http://127.0.0.1 always allowed
 *   - http:// allowed for RFC1918 LAN hosts (10/8, 172.16/12, 192.168/16)
 *   - https:// always allowed
 *   - bare host:port → wrapped as http://
 *   - ws:// / wss:// → coerced to http:// / https:// (lifelong daemon nicety)
 *   - trailing `/v1` paths and `/health` stripped so callers can append them safely
 */
object HermesProtocol {
    private const val URL_SCHEME_SUFFIX_LENGTH = 3
    private const val IPV4_OCTET_COUNT = 4
    private const val RFC1918_CLASS_A_FIRST_OCTET = 10
    private const val RFC1918_CLASS_B_FIRST_OCTET = 172
    private const val RFC1918_CLASS_C_FIRST_OCTET = 192
    private const val RFC1918_CLASS_C_SECOND_OCTET = 168
    private const val MAX_IPV4_OCTET = 255
    private const val RFC172_SUBNET_MIN = 16
    private const val RFC172_SUBNET_MAX = 31

    /** Normalize a user-entered URL into a base URL suitable for OpenAI-compatible endpoints. */
    fun normalizeBaseURL(raw: String?): String? {
        val trimmed = raw?.trim()?.trimEnd('/').orEmpty()
        if (trimmed.isBlank()) return null
        val httpURL =
            when {
                trimmed.startsWith("ws://") -> "http://" + trimmed.removePrefix("ws://")
                trimmed.startsWith("wss://") -> "https://" + trimmed.removePrefix("wss://")
                trimmed.startsWith("http://") || trimmed.startsWith("https://") -> trimmed
                else -> "http://$trimmed"
            }
        return httpURL
            .substringBefore("/v1/chat/completions")
            .substringBefore("/v1/models")
            .substringBefore("/health")
            .trimEnd('/')
    }

    /**
     * Validate that [raw] is a Hermes endpoint we will actually talk to from the
     * Android app. Returns the normalized base URL, or `null` when the input is
     * unsafe (e.g. plain HTTP to a public host, or a malformed URL).
     */
    fun validatedBaseURL(raw: String?): String? {
        val normalized = normalizeBaseURL(raw) ?: return null
        val schemeEnd = normalized.indexOf("://")
        if (schemeEnd < 0) return null
        val scheme = normalized.substring(0, schemeEnd).lowercase()
        val rest = normalized.substring(schemeEnd + URL_SCHEME_SUFFIX_LENGTH)
        val hostPart = rest.substringBefore('/').substringBefore(':').lowercase()
        if (rest.isEmpty() || hostPart.isEmpty()) return null
        return when (scheme) {
            "https" -> normalized
            "http" -> normalized.takeIf { isLocalOrPrivateHost(hostPart) }
            else -> null
        }
    }

    /** True when [host] is `localhost`, an IPv4 loopback, or an RFC1918 LAN address. */
    fun isLocalOrPrivateHost(host: String): Boolean {
        if (host == "localhost") return true
        if (host == "127.0.0.1" || host == "::1") return true
        val parts = host.split('.').mapNotNull { it.toIntOrNull() }
        if (parts.size != IPV4_OCTET_COUNT || parts.any { it !in 0..MAX_IPV4_OCTET }) return false
        return parts[0] == RFC1918_CLASS_A_FIRST_OCTET ||
            parts[0] == RFC1918_CLASS_B_FIRST_OCTET && parts[1] in RFC172_SUBNET_MIN..RFC172_SUBNET_MAX ||
            parts[0] == RFC1918_CLASS_C_FIRST_OCTET && parts[1] == RFC1918_CLASS_C_SECOND_OCTET
    }

    /**
     * Extract human-visible text from an OpenAI/Ollama streaming chunk.
     * Returns an empty string when there is no displayable content yet — caller
     * should treat that as "skip this chunk and keep listening".
     */
    fun extractStreamedText(json: JSONObject): String {
        val parser = HermesOpenAICompatibleStreamParser()
        return parser.eventsFromJson(json)
            .events
            .filterIsInstance<HermesStreamEvent.MessageChunk>()
            .joinToString(separator = "") { it.text }
    }

    /** Recursively extract text from `String`, `{text|content|value}`, or arrays of those. */
    fun extractContentValue(value: Any?): String? {
        return when (value) {
            null, JSONObject.NULL -> null
            is String -> value
            is JSONArray -> {
                val builder = StringBuilder()
                for (index in 0 until value.length()) {
                    when (val item = value.opt(index)) {
                        is String -> builder.append(item)
                        is JSONObject -> {
                            val nested =
                                extractContentValue(item.opt("text"))
                                    ?: extractContentValue(item.opt("value"))
                                    ?: extractContentValue(item.opt("content"))
                            if (nested != null) builder.append(nested)
                        }
                        else -> Unit
                    }
                }
                builder.toString().takeIf { it.isNotEmpty() }
            }
            is JSONObject ->
                extractContentValue(value.opt("text"))
                    ?: extractContentValue(value.opt("value"))
                    ?: extractContentValue(value.opt("content"))
            else -> null
        }
    }

    /** Decode a `/v1/models` response into a stable list of model options. */
    fun parseModelsResponse(rawBody: String?): List<HermesRuntimeModelOption> {
        if (rawBody.isNullOrBlank()) return emptyList()
        val json = runCatching { JSONObject(rawBody) }.getOrNull() ?: return emptyList()
        val data = json.optJSONArray("data") ?: return emptyList()
        return (0 until data.length()).mapNotNull { idx ->
            val item = data.optJSONObject(idx) ?: return@mapNotNull null
            val id = item.optString("id").takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val owner = item.optString("owned_by", "hermes").takeIf { it.isNotBlank() } ?: "hermes"
            val displayName =
                item.optString("display_name").takeIf { it.isNotBlank() }
                    ?: item.optString("name").takeIf { it.isNotBlank() }
                    ?: id
            HermesRuntimeModelOption(
                providerID = owner,
                providerName = owner.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() },
                modelID = id,
                displayName = displayName,
                sourceKind = item.optString("source_kind").takeIf { it.isNotBlank() },
            )
        }
    }
}
