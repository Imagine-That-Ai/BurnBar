package com.openburnbar.irohrelay

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
    val protocolVersion: Int = HermesRealtimeRelayProtocol.VERSION,
    val runtime: String? = null,
    val payload: HermesRealtimeRelayPayload? = null,
    val media: HermesRealtimeRelayMediaPayload? = null,
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
