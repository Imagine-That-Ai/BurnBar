package com.openburnbar.data.hermes

import com.google.firebase.firestore.IgnoreExtraProperties
import com.google.firebase.firestore.PropertyName

enum class PiConnectionMode(val token: String) {
    LOCAL("local"),
    DIRECT_URL("directURL"),
    RELAY_LINK("relayLink");

    companion object {
        fun fromToken(value: String?): PiConnectionMode =
            values().firstOrNull { it.token == value } ?: LOCAL
    }
}

enum class PiConnectionStatus(val token: String) {
    PENDING("pending"),
    ONLINE("online"),
    OFFLINE("offline"),
    UNAUTHORIZED("unauthorized"),
    REVOKED("revoked"),
    DEGRADED("degraded");

    companion object {
        fun fromToken(value: String?): PiConnectionStatus =
            values().firstOrNull { it.token == value } ?: OFFLINE
    }
}

@IgnoreExtraProperties
data class PiAgentInstanceRecord(
    var id: String = "",
    var displayName: String = "",
    var endpointURL: String? = null,
    var status: String = PiConnectionStatus.OFFLINE.token,
    var modelName: String? = null,
    var capabilities: List<String> = emptyList(),
    var lastSeenAt: String? = null,
    var schemaVersion: Int = 1
) {
    val resolvedStatus: PiConnectionStatus
        get() = PiConnectionStatus.fromToken(status)
}

@IgnoreExtraProperties
data class PiAgentRuntimeModelOption(
    var id: String = "",
    @get:PropertyName("providerID")
    @set:PropertyName("providerID")
    var providerId: String = "pi",
    var providerName: String = "Pi",
    @get:PropertyName("modelID")
    @set:PropertyName("modelID")
    var modelId: String = "",
    var displayName: String = "",
    @get:PropertyName("instanceID")
    @set:PropertyName("instanceID")
    var instanceId: String? = null,
    var schemaVersion: Int = 1
)

@IgnoreExtraProperties
data class PiConnectionRecord(
    var id: String = "",
    var displayName: String = "",
    var mode: String = PiConnectionMode.LOCAL.token,
    var endpointURL: String? = null,
    var status: String = PiConnectionStatus.OFFLINE.token,
    @get:PropertyName("selectedInstanceID")
    @set:PropertyName("selectedInstanceID")
    var selectedInstanceId: String? = null,
    var redisURL: String? = null,
    var capabilities: List<String> = emptyList(),
    var advertisedModel: String? = null,
    var relayPublicKey: String? = null,
    var relayKeyVersion: Int? = null,
    var relayEncryption: String? = null,
    var realtimeRelayURL: String? = null,
    var realtimeRelayStatus: String? = null,
    var realtimeRelayLastSeenAt: String? = null,
    var realtimeRelayProtocolVersion: Int? = null,
    var instances: List<PiAgentInstanceRecord> = emptyList(),
    var models: List<PiAgentRuntimeModelOption> = emptyList(),
    var createdAt: String? = null,
    var updatedAt: String? = null,
    var lastSeenAt: String? = null,
    var schemaVersion: Int = 1
) {
    val resolvedMode: PiConnectionMode
        get() = PiConnectionMode.fromToken(mode)

    val resolvedStatus: PiConnectionStatus
        get() = PiConnectionStatus.fromToken(status)

    companion object {
        val localDefault = PiConnectionRecord(
            id = "local-pi",
            displayName = "Local Pi",
            mode = PiConnectionMode.LOCAL.token,
            endpointURL = "http://127.0.0.1:8765",
            status = PiConnectionStatus.OFFLINE.token,
            capabilities = listOf("chat_completions")
        )
    }
}

@IgnoreExtraProperties
data class PiPairingSessionRecord(
    var id: String = "",
    var code: String = "",
    var expiresAt: String = ""
)

@IgnoreExtraProperties
data class PiAgentSessionSummary(
    var id: String = "",
    var title: String? = null,
    var preview: String? = null,
    var source: String? = null,
    var model: String? = null,
    @get:PropertyName("instanceID")
    @set:PropertyName("instanceID")
    var instanceId: String? = null,
    var startedAt: String? = null,
    var lastActiveAt: String? = null,
    var endedAt: String? = null,
    var isActive: Boolean = false,
    var messageCount: Int = 0,
    var toolCallCount: Int = 0,
    var inputTokens: Int = 0,
    var outputTokens: Int = 0,
    var schemaVersion: Int = 1
)

enum class RuntimeConnectionPreferenceKind(val token: String) {
    HERMES("hermes"),
    PI_AGENT("piAgent");

    companion object {
        fun fromToken(value: String?): RuntimeConnectionPreferenceKind =
            values().firstOrNull { it.token == value } ?: HERMES
    }
}

@IgnoreExtraProperties
data class RuntimeConnectionPreferenceRecord(
    var id: String = "",
    @get:PropertyName("deviceID")
    @set:PropertyName("deviceID")
    var deviceId: String = "",
    var runtimeKind: String = RuntimeConnectionPreferenceKind.HERMES.token,
    @get:PropertyName("selectedConnectionID")
    @set:PropertyName("selectedConnectionID")
    var selectedConnectionId: String = "",
    @get:PropertyName("selectedInstanceID")
    @set:PropertyName("selectedInstanceID")
    var selectedInstanceId: String? = null,
    @get:PropertyName("selectedModelID")
    @set:PropertyName("selectedModelID")
    var selectedModelId: String? = null,
    var createdAt: String? = null,
    var updatedAt: String? = null,
    var schemaVersion: Int = 1
) {
    val resolvedRuntimeKind: RuntimeConnectionPreferenceKind
        get() = RuntimeConnectionPreferenceKind.fromToken(runtimeKind)
}

enum class PiAgentRelayOperation(val token: String) {
    CHAT_COMPLETIONS("chatCompletions"),
    MODELS("models"),
    SESSIONS("sessions"),
    SESSION_DETAIL("sessionDetail")
}

enum class PiAgentRelayRequestStatus(val token: String) {
    PENDING("pending"),
    CLAIMED("claimed"),
    STREAMING("streaming"),
    COMPLETED("completed"),
    FAILED("failed"),
    CANCELLED("cancelled"),
    EXPIRED("expired")
}

enum class PiAgentRelayChunkKind(val token: String) {
    SSE("sse"),
    DATA("data"),
    ERROR("error")
}

enum class AssistantRuntimeID(val token: String, val displayName: String, val glyph: String) {
    HERMES("hermes", "Hermes", "\u263F"),
    PI("pi", "Pi", "\u03C0"),
    CODEX("codex", "Codex", "\u21BB"),
    CLAUDE("claude", "Claude", "\u2726"),
    OPEN_CLAW("openclaw", "OpenClaw", "\u26A1");

    /** True for runtimes that have a first-class Android surface today. */
    val hasMobileChatSurface: Boolean get() = true

    companion object {
        fun fromToken(value: String?): AssistantRuntimeID =
            values().firstOrNull { it.token == value } ?: HERMES

        /** Default-visible tiles for a fresh install. */
        val defaultEnabledTiles: Set<AssistantRuntimeID> = values().toSet()
    }
}

/**
 * The six Hermes sub-providers surfaced inside the Hermes model picker.
 * Matches the Swift `HermesSubProvider` enum in `OpenBurnBarCore`.
 */
enum class HermesSubProvider(val token: String, val displayName: String, val defaultModelHint: String, val glyph: String) {
    CODEX("codex", "Codex", "codex", "\u21BB"),
    CLAUDE("claude", "Claude", "claude", "\u2726"),
    ZAI("zai", "Z.ai", "glm-4.6", "Z"),
    KIMI("kimi", "Kimi", "kimi-k2", "K"),
    MINIMAX("minimax", "MiniMax", "minimax-m1", "M"),
    OLLAMA("ollama", "Ollama", "llama3", "\u2299");

    companion object {
        fun fromToken(value: String?): HermesSubProvider? {
            val normalized = value?.lowercase()?.replace(" ", "") ?: return null
            return values().firstOrNull { it.token == normalized }
        }

        val defaultVisible: Set<HermesSubProvider> = values().toSet()
    }
}
