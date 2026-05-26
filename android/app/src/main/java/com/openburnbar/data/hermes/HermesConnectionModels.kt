package com.openburnbar.data.hermes

import com.openburnbar.data.models.AgentProvider

enum class HermesConnectionMode {
    LOCAL, DIRECT_URL, RELAY_LINK
}

enum class HermesConnectionStatus {
    ONLINE, OFFLINE, PENDING, UNAUTHORIZED, REVOKED, DEGRADED
}

data class HermesConnectionRecord(
    val id: String,
    val displayName: String,
    val mode: HermesConnectionMode = HermesConnectionMode.LOCAL,
    val endpointURL: String? = null,
    val status: HermesConnectionStatus = HermesConnectionStatus.OFFLINE,
    val capabilities: List<String> = emptyList(),
    val advertisedModel: String? = null,
    val relayPublicKey: String? = null,
    val relayKeyVersion: Int? = null,
    val relayEncryption: String? = null,
    val realtimeRelayURL: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    val lastSeenAt: Long? = null
) {
    companion object {
        val localDefault = HermesConnectionRecord(
            id = "local-default",
            displayName = "Local Hermes",
            mode = HermesConnectionMode.LOCAL,
            endpointURL = "http://127.0.0.1:8642"
        )
    }
}

data class HermesRuntimeModelOption(
    val providerID: String,
    val providerName: String,
    val modelID: String,
    val displayName: String,
    val modelCapabilities: ModelIOCapabilities? = null
)

data class ModelIOCapabilities(
    val schemaVersion: Int = 1,
    val inputModalities: List<String> = listOf("text"),
    val outputModalities: List<String> = listOf("text"),
    val supportedParameters: List<String> = emptyList(),
    val contextWindowTokens: Int? = null,
    val maxOutputTokens: Int? = null,
    val acceptedInputMimeTypes: List<String> = emptyList(),
    val imageMaxBytes: Int? = null,
    val audioMaxBytes: Int? = null,
    val videoMaxBytes: Int? = null
) {
    val supportsImageInput: Boolean
        get() = inputModalities.any { it.equals("image", ignoreCase = true) }

    fun acceptsInputMimeType(mimeType: String?): Boolean {
        val normalized = mimeType?.substringBefore(";")?.trim()?.lowercase()?.takeIf { it.isNotBlank() }
            ?: return false
        if (acceptedInputMimeTypes.isEmpty()) {
            return normalized.startsWith("image/") && supportsImageInput
        }
        return acceptedInputMimeTypes.any { accepted ->
            val value = accepted.trim().lowercase()
            if (value.endsWith("/*")) {
                normalized.startsWith(value.dropLast(1))
            } else {
                normalized == value
            }
        }
    }
}

data class HermesRuntimeProfile(
    val name: String,
    val model: String? = null,
    val provider: String? = null,
    val skillCount: Int = 0
)

data class HermesRuntimeJob(
    val id: String,
    val name: String? = null,
    val prompt: String = "Hermes job",
    val scheduleDisplay: String? = null,
    val state: String = "unknown",
    val enabled: Boolean = true,
    val lastRunAt: Long? = null,
    val nextRunAt: Long? = null,
    val lastError: String? = null
)

data class HermesSessionSummary(
    val id: String,
    val title: String? = null,
    val preview: String? = null,
    val source: String? = null,
    val model: String? = null,
    val startedAt: Long? = null,
    val lastActiveAt: Long? = null,
    val endedAt: Long? = null,
    val isActive: Boolean = false,
    val messageCount: Int = 0,
    val toolCallCount: Int = 0,
    val inputTokens: Int = 0,
    val outputTokens: Int = 0
)

enum class HermesRelayOperation {
    CHAT_COMPLETIONS, CLI_AGENT_CHAT, CLI_AGENT_MODEL_CATALOG, MODELS, SESSIONS, PROFILES, JOBS, SESSION_DETAIL
}
