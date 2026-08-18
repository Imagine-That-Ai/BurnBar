package com.openburnbar.irohrelay

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
enum class HermesRealtimeRelayFrameType {
    @SerialName("host.register")
    HOST_REGISTER,

    @SerialName("host.ready")
    HOST_READY,

    @SerialName("request.start")
    REQUEST_START,

    @SerialName("request.cancel")
    REQUEST_CANCEL,

    @SerialName("response.chunk")
    RESPONSE_CHUNK,

    @SerialName("response.complete")
    RESPONSE_COMPLETE,

    @SerialName("response.error")
    RESPONSE_ERROR,

    @SerialName("ping")
    PING,

    @SerialName("pong")
    PONG,

    // Device-to-device Signal Double Ratchet ciphertext carried over the
    // existing iroh relay stream. The transport moves opaque bytes and
    // dispatches by the top-level message-type integer.
    @SerialName("signal.session.message")
    SIGNAL_SESSION_MESSAGE,

    // Mercury media. Older peers skip unknown frame types on the chat
    // stream so adding cases here is forward-compatible with iOS.
    @SerialName("media.classify")
    MEDIA_CLASSIFY,

    @SerialName("media.blob.advertise")
    MEDIA_BLOB_ADVERTISE,

    @SerialName("media.blob.ack")
    MEDIA_BLOB_ACK,

    @SerialName("media.mirror.request")
    MEDIA_MIRROR_REQUEST,

    @SerialName("media.mirror.ack")
    MEDIA_MIRROR_ACK,

    @SerialName("media.mirror.stop")
    MEDIA_MIRROR_STOP,

    @SerialName("media.mirror.display.select")
    MEDIA_MIRROR_DISPLAY_SELECT,

    @SerialName("media.presence.heartbeat")
    MEDIA_PRESENCE_HEARTBEAT,

    @SerialName("media.call.invite")
    MEDIA_CALL_INVITE,

    @SerialName("media.call.ack")
    MEDIA_CALL_ACK,

    @SerialName("media.ltr.ack")
    MEDIA_LONG_TERM_REFERENCE_ACK,

    @SerialName("media.stream.frame")
    MEDIA_STREAM_FRAME,

    // Computer Use control plane. Mirrors the Swift enum so Android can
    // receive Agent Watch frames and emit signed phone-control intents.
    @SerialName("control.classify")
    CONTROL_CLASSIFY,

    @SerialName("control.action.log.entry")
    CONTROL_ACTION_LOG_ENTRY,

    @SerialName("control.input.intent")
    CONTROL_INPUT_INTENT,

    @SerialName("control.approval.request")
    CONTROL_APPROVAL_REQUEST,

    @SerialName("control.approval.response")
    CONTROL_APPROVAL_RESPONSE,

    @SerialName("control.session.grant.challenge")
    CONTROL_SESSION_GRANT_CHALLENGE,

    @SerialName("control.agent.grant.request")
    CONTROL_AGENT_GRANT_REQUEST,

    @SerialName("control.agent.grant.receipt")
    CONTROL_AGENT_GRANT_RECEIPT,

    @SerialName("control.clipboard.request")
    CONTROL_CLIPBOARD_REQUEST,

    @SerialName("control.clipboard.response")
    CONTROL_CLIPBOARD_RESPONSE,

    @SerialName("control.agent.context.target")
    CONTROL_AGENT_CONTEXT_TARGET,

    @SerialName("control.system.permission.request")
    CONTROL_SYSTEM_PERMISSION_REQUEST,

    @SerialName("control.system.permission.status")
    CONTROL_SYSTEM_PERMISSION_STATUS,

    @SerialName("control.denied")
    CONTROL_DENIED,

    @SerialName("remote_unlock.session")
    REMOTE_UNLOCK_SESSION,

    @SerialName("remote_unlock.state")
    REMOTE_UNLOCK_STATE,

    @SerialName("remote_unlock.input")
    REMOTE_UNLOCK_INPUT,

    @SerialName("remote_unlock.credential")
    REMOTE_UNLOCK_CREDENTIAL,

    @SerialName("remote_unlock.result")
    REMOTE_UNLOCK_RESULT,

    @SerialName("remote_unlock.denied")
    REMOTE_UNLOCK_DENIED,

    // War Room — the Wire. The encrypted Mac⇄Mac lane
    // (plans/2026-08-17-war-room-master-plan.md). Mac-to-Mac only; Android
    // carries the cases so the shared decoder never drops a frame it can see.
    @SerialName("war.hello")
    WAR_HELLO,

    @SerialName("war.hello.ack")
    WAR_HELLO_ACK,

    @SerialName("war.fleet.snapshot")
    WAR_FLEET_SNAPSHOT,

    @SerialName("war.dispatch")
    WAR_DISPATCH,

    @SerialName("war.dispatch.ack")
    WAR_DISPATCH_ACK,

    @SerialName("war.stream.chunk")
    WAR_STREAM_CHUNK,

    @SerialName("war.stream.complete")
    WAR_STREAM_COMPLETE,

    @SerialName("war.denied")
    WAR_DENIED,
}

/**
 * Wire-form chunk kind for `HermesRealtimeRelayPayload.kind`.
 *
 * Matches the Swift `HermesRelayChunkKind` declared in
 * `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesConnectionTypes.swift`
 * — three cases, lower-case raw values, no aliases. Adding cases here
 * without also adding them on Swift will silently drop incoming chunks
 * because Mac decodes `nil` for unknown kinds.
 */
@Serializable
enum class HermesRelayChunkKind(val wireValue: String) {
    /** Server-Sent Events fragment (text token). Used by streaming chat. */
    @SerialName("sse")
    SSE("sse"),

    /** Binary blob (currently base64 in JSON). Used by unary forwards. */
    @SerialName("data")
    DATA("data"),

    /** Terminal error chunk. */
    @SerialName("error")
    ERROR("error"),
}

@Serializable
data class HermesTokenUsageStats(
    val promptTokens: Int? = null,
    val outputTokens: Int? = null,
    val totalTokens: Int? = null,
    val generationDurationSeconds: Double? = null,
    val totalDurationSeconds: Double? = null,
)

@Serializable
enum class HermesChatMessageOutcome(val rawValue: String) {
    @SerialName("normal")
    NORMAL("normal"),

    @SerialName("refusal")
    REFUSAL("refusal"),

    @SerialName("reasoningFallback")
    REASONING_FALLBACK("reasoningFallback"),

    @SerialName("lengthCap")
    LENGTH_CAP("lengthCap"),

    @SerialName("contentFilter")
    CONTENT_FILTER("contentFilter"),

    @SerialName("toolCallNoFollowUp")
    TOOL_CALL_NO_FOLLOW_UP("toolCallNoFollowUp"),

    @SerialName("empty")
    EMPTY("empty"),
}

@OptIn(ExperimentalSerializationApi::class)
@Serializable
sealed class HermesStreamEvent {
    @Serializable
    @SerialName("messageChunk")
    data class MessageChunk(val text: String) : HermesStreamEvent()

    @Serializable
    @SerialName("reasoningChunk")
    data class ReasoningChunk(val text: String) : HermesStreamEvent()

    @Serializable
    @SerialName("refusalChunk")
    data class RefusalChunk(val text: String) : HermesStreamEvent()

    @Serializable
    @SerialName("toolCallChunk")
    data class ToolCallChunk(
        val id: String,
        val index: Int,
        val name: String? = null,
        val argumentsDelta: String,
    ) : HermesStreamEvent()

    @Serializable
    @SerialName("toolCallFinished")
    data class ToolCallFinished(
        val id: String,
        val name: String,
        val arguments: String,
    ) : HermesStreamEvent()

    @Serializable
    @SerialName("toolResult")
    data class ToolResult(
        val id: String? = null,
        val name: String,
        val detail: String? = null,
    ) : HermesStreamEvent()

    @Serializable
    @SerialName("longToolHint")
    data class LongToolHint(
        val toolName: String,
        val message: String,
    ) : HermesStreamEvent()

    @Serializable
    @SerialName("notice")
    data class Notice(
        val level: String,
        val text: String,
    ) : HermesStreamEvent()

    @Serializable
    @SerialName("messageStop")
    data class MessageStop(
        val finishReason: String? = null,
        val outcome: HermesChatMessageOutcome,
        val usage: HermesTokenUsageStats? = null,
    ) : HermesStreamEvent()

    companion object {
        @OptIn(ExperimentalSerializationApi::class)
        val json: Json =
            Json {
                ignoreUnknownKeys = true
                classDiscriminator = "type"
                encodeDefaults = false
                explicitNulls = false
            }
    }
}

@Serializable
data class HermesRealtimeRelayPresenceHeartbeat(
    val peerDeviceId: String? = null,
    val displayName: String? = null,
    val deviceDisplayName: String? = null,
    val capabilities: List<String> = emptyList(),
    val blurredWallpaperBase64: String? = null,
    val streamingCapabilities: HermesRealtimeRelayStreamingCapabilities? = null,
    val remoteUnlockCapabilities: HermesRealtimeRelayRemoteUnlockCapabilities? = null,
    /** ISO-8601 string. Matches the Swift `Date` encoding via JSONEncoder default. */
    val sentAt: String,
)

/**
 * The dotted Swift raw value of a frame type (`"control.input.intent"`, ...),
 * exactly as it appears in the `type` field on the wire. The F10 control seal
 * binds this string into its AAD, so it MUST match `frame.type.rawValue` on
 * the Swift opener byte-for-byte — sourced from the `@SerialName` the codec
 * itself emits so the two can never drift.
 */
@OptIn(ExperimentalSerializationApi::class)
val HermesRealtimeRelayFrameType.wireValue: String
    get() = HermesRealtimeRelayFrameType.serializer().descriptor.getElementName(ordinal)

/**
 * F10 — JSON codec for the INNER control payload that rides inside a
 * `ControlFrameSeal` envelope. Uses the exact relay wire `Json` configuration
 * (`HermesRealtimeRelayJson`) so inner payloads keep the same field/date wire
 * shapes as unsealed frames — the Kotlin twin of the Swift
 * `ControlFrameSealSession` canonical encoder/decoder (ISO8601-fractional
 * dates are already plain `String`/`Double` fields on the Kotlin models).
 */
object HermesRealtimeRelayControlPayloadCodec {
    fun encodeToBytes(payload: HermesRealtimeRelayControlPayload): ByteArray =
        HermesRealtimeRelayJson
            .encodeToString(HermesRealtimeRelayControlPayload.serializer(), payload)
            .toByteArray(Charsets.UTF_8)

    fun decodeFromBytes(bytes: ByteArray): HermesRealtimeRelayControlPayload =
        HermesRealtimeRelayJson.decodeFromString(
            HermesRealtimeRelayControlPayload.serializer(),
            bytes.toString(Charsets.UTF_8),
        )
}

@Serializable
enum class HermesRealtimeRelayInputIntentKind {
    @SerialName("tap")
    TAP,

    @SerialName("drag_start")
    DRAG_START,

    @SerialName("drag_move")
    DRAG_MOVE,

    @SerialName("drag_end")
    DRAG_END,

    @SerialName("type")
    TYPE,

    @SerialName("shortcut")
    SHORTCUT,

    @SerialName("scroll")
    SCROLL,

    @SerialName("pointer_move")
    POINTER_MOVE,

    @SerialName("pointer_click")
    POINTER_CLICK,

    @SerialName("panic")
    PANIC,
}

/**
 * Shared JSON codec for the relay layer. Encodes nulls only when the
 * field exists, matching the Swift encoder defaults that drop optional
 * properties when they are `nil`.
 */
internal val HermesRealtimeRelayJson: Json =
    Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
        explicitNulls = false
    }
