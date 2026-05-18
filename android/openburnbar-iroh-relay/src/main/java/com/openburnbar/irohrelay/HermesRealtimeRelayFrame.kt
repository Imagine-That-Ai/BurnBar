package com.openburnbar.irohrelay

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * 1-to-1 Kotlin mirror of `HermesRealtimeRelayFrame` in Swift
 * (`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift`).
 *
 * Same JSON shape, same enum identifiers, same nullable semantics. Decode
 * tolerance is enabled (`ignoreUnknownKeys = true`) so an iOS sender can
 * add new optional fields without breaking Android decoders.
 *
 * The wire envelope used by iroh + the legacy Cloud Run WebSocket is
 * `[u32 big-endian length][JSON payload]` — encoded/decoded by
 * `IrohRelayFrameCodec`. This file is purely the JSON shape.
 */
@Serializable
data class HermesRealtimeRelayFrame(
    val type: HermesRealtimeRelayFrameType,
    val uid: String,
    val connectionId: String,
    val requestId: String? = null,
    @OptIn(ExperimentalSerializationApi::class)
    @EncodeDefault
    val protocolVersion: Int = HermesRealtimeRelayProtocol.VERSION,
    val runtime: String? = null,
    val payload: HermesRealtimeRelayPayload? = null,
    val media: HermesRealtimeRelayMediaPayload? = null,
    val control: HermesRealtimeRelayControlPayload? = null,
)

@Serializable
enum class HermesRealtimeRelayFrameType {
    @SerialName("host.register") HOST_REGISTER,
    @SerialName("host.ready") HOST_READY,
    @SerialName("request.start") REQUEST_START,
    @SerialName("request.cancel") REQUEST_CANCEL,
    @SerialName("response.chunk") RESPONSE_CHUNK,
    @SerialName("response.complete") RESPONSE_COMPLETE,
    @SerialName("response.error") RESPONSE_ERROR,
    @SerialName("ping") PING,
    @SerialName("pong") PONG,

    // Mercury media. Older peers skip unknown frame types on the chat
    // stream so adding cases here is forward-compatible with iOS.
    @SerialName("media.classify") MEDIA_CLASSIFY,
    @SerialName("media.blob.advertise") MEDIA_BLOB_ADVERTISE,
    @SerialName("media.blob.ack") MEDIA_BLOB_ACK,

    // Computer Use control plane. Mirrors the Swift enum so Android can
    // receive Agent Watch frames and emit signed phone-control intents.
    @SerialName("control.classify") CONTROL_CLASSIFY,
    @SerialName("control.action.log.entry") CONTROL_ACTION_LOG_ENTRY,
    @SerialName("control.input.intent") CONTROL_INPUT_INTENT,
    @SerialName("control.approval.request") CONTROL_APPROVAL_REQUEST,
    @SerialName("control.approval.response") CONTROL_APPROVAL_RESPONSE,
    @SerialName("control.denied") CONTROL_DENIED,
}

@Serializable
data class HermesRealtimeRelayPayload(
    val operation: String? = null,
    val method: String? = null,
    val payloadCiphertext: String? = null,
    val wrappedKey: String? = null,
    val relayEncryption: String? = null,
    val relayKeyVersion: Int? = null,
    val sequence: Int? = null,
    val kind: HermesRelayChunkKind? = null,
    val ciphertext: String? = null,
    val error: String? = null,
    val chunkCount: Int? = null,
    val capabilities: List<String>? = null,
)

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
    @SerialName("sse") SSE("sse"),
    /** Binary blob (currently base64 in JSON). Used by unary forwards. */
    @SerialName("data") DATA("data"),
    /** Terminal error chunk. */
    @SerialName("error") ERROR("error"),
}

@Serializable
data class HermesRealtimeRelayMediaPayload(
    val streamClass: String? = null,
    val attachment: HermesRealtimeRelayAttachmentManifest? = null,
    val blobTicket: String? = null,
    val ack: HermesRealtimeRelayMediaAck? = null,
)

@Serializable
data class HermesRealtimeRelayAttachmentManifest(
    val manifestId: String,
    val blobHash: String,
    val filename: String,
    val mime: String,
    val size: Long,
    val peerDeviceId: String? = null,
    /** ISO-8601 string. Matches the Swift `Date` encoding via JSONEncoder default. */
    val createdAt: String,
)

@Serializable
data class HermesRealtimeRelayMediaAck(
    val manifestId: String,
    val status: Status,
    val reason: String? = null,
) {
    @Serializable
    enum class Status {
        @SerialName("received") RECEIVED,
        @SerialName("rejected") REJECTED,
    }
}

@Serializable
data class HermesRealtimeRelayControlPayload(
    val streamClass: String? = null,
    val sessionId: String? = null,
    val inputIntent: HermesRealtimeRelayInputIntent? = null,
    val authorityPeerNodeId: String? = null,
    val authorityPublicKeyBase64: String? = null,
    val approvalRequest: HermesRealtimeRelayApprovalRequest? = null,
    val approvalResponse: HermesRealtimeRelayApprovalResponse? = null,
)

@Serializable
data class HermesRealtimeRelayApprovalRequest(
    val approvalId: String,
    val runId: String,
    val sessionId: String,
    val toolKind: String,
    val title: String,
    val message: String,
    val beforeScreenshotBlake3: String? = null,
    val beforeScreenshotPNGBase64: String? = null,
    val beforeScreenshotMimeType: String? = null,
    val beforeScreenshotSizeBytes: Int? = null,
    val actionSummary: String,
    /** Swift JSONEncoder's default Date encoding: seconds since 2001-01-01 UTC. */
    val requestedAt: Double,
    val trustMode: String? = null,
)

@Serializable
data class HermesRealtimeRelayApprovalResponse(
    val approvalId: String,
    val decision: Decision,
    val respondedBy: String,
    /** Swift JSONEncoder's default Date encoding: seconds since 2001-01-01 UTC. */
    val respondedAt: Double,
    val note: String? = null,
) {
    @Serializable
    enum class Decision {
        @SerialName("approve") APPROVE,
        @SerialName("reject") REJECT,
        @SerialName("reject_and_halt") REJECT_AND_HALT,
    }
}

@Serializable
data class HermesRealtimeRelayInputIntent(
    val kind: HermesRealtimeRelayInputIntentKind,
    val normalizedX: Double? = null,
    val normalizedY: Double? = null,
    val normalizedX2: Double? = null,
    val normalizedY2: Double? = null,
    val text: String? = null,
    val key: String? = null,
    val modifiers: List<String>? = null,
    val authority: HermesRealtimeRelayAuthorityEnvelope,
)

@Serializable
enum class HermesRealtimeRelayInputIntentKind {
    @SerialName("tap") TAP,
    @SerialName("drag_start") DRAG_START,
    @SerialName("drag_move") DRAG_MOVE,
    @SerialName("drag_end") DRAG_END,
    @SerialName("type") TYPE,
    @SerialName("shortcut") SHORTCUT,
    @SerialName("scroll") SCROLL,
    @SerialName("panic") PANIC,
}

@Serializable
data class HermesRealtimeRelayAuthorityEnvelope(
    val peerNodeId: String,
    val counter: Long,
    /**
     * Swift JSONEncoder's default Date encoding: seconds since
     * 2001-01-01 00:00:00 UTC. Android senders convert from Unix ms.
     */
    val timestamp: Double,
    val intentHashBlake3: String,
    val signatureEd25519: String,
)

/**
 * Shared JSON codec for the relay layer. Encodes nulls only when the
 * field exists, matching the Swift encoder defaults that drop optional
 * properties when they are `nil`.
 */
internal val HermesRealtimeRelayJson: Json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = false
    explicitNulls = false
}
