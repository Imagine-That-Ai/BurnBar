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
    val signalSessionCiphertextB64: String? = null,
    val signalMessageType: Int? = null,
)

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
    val errorCode: String? = null,
    /** Legacy plaintext terminal error. New senders use [errorCode] only. */
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
data class HermesRealtimeRelayMediaPayload(
    val streamClass: String? = null,
    val attachment: HermesRealtimeRelayAttachmentManifest? = null,
    val blobTicket: String? = null,
    val ack: HermesRealtimeRelayMediaAck? = null,
    val mirrorRequest: HermesRealtimeRelayMirrorRequest? = null,
    val mirrorAck: HermesRealtimeRelayMirrorAck? = null,
    val mirrorStop: HermesRealtimeRelayMirrorStop? = null,
    val mirrorDisplaySelection: HermesRealtimeRelayMirrorDisplaySelection? = null,
    val presence: HermesRealtimeRelayPresenceHeartbeat? = null,
    val callInvite: HermesRealtimeRelayCallInvite? = null,
    val callAck: HermesRealtimeRelayCallAck? = null,
    val longTermReferenceAck: HermesRealtimeRelayLongTermReferenceAck? = null,
    val encodedFrameBase64: String? = null,
    val frameChunk: HermesRealtimeRelayMediaFrameChunk? = null,
    val focusContext: HermesRealtimeRelayFocusContext? = null,
)

@Serializable
enum class HermesRealtimeRelayFocusTargetKind {
    @SerialName("cursor")
    CURSOR,

    @SerialName("focused_element")
    FOCUSED_ELEMENT,

    @SerialName("focused_window")
    FOCUSED_WINDOW,

    @SerialName("agent_workspace")
    AGENT_WORKSPACE,
}

@Serializable
data class HermesRealtimeRelayNormalizedRect(
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
)

@Serializable
data class HermesRealtimeRelayNormalizedPoint(
    val x: Double,
    val y: Double,
)

@Serializable
data class HermesRealtimeRelayFocusContext(
    val appName: String,
    val bundleId: String,
    val windowTitle: String? = null,
    val windowId: Long? = null,
    /** Smart Zoom target type. Optional for backwards compat. */
    val targetKind: HermesRealtimeRelayFocusTargetKind? = null,
    /** Display id that the rect/point are relative to. */
    val displayId: String? = null,
    /** Target rectangle in display-relative normalized coordinates `[0..1]`. */
    val normalizedRect: HermesRealtimeRelayNormalizedRect? = null,
    /** Target point in display-relative normalized coordinates `[0..1]`. */
    val normalizedPoint: HermesRealtimeRelayNormalizedPoint? = null,
    /** Provider confidence in the target. */
    val confidence: Double? = null,
    /**
     * Swift JSONEncoder's default Date encoding: seconds since 2001-01-01 UTC.
     * Optional so older peers without Smart Zoom decode unchanged.
     */
    val updatedAt: Double? = null,
)

@Serializable
data class HermesRealtimeRelayMediaFrameChunk(
    val chunkId: String,
    val chunkIndex: Int,
    val chunkCount: Int,
    val totalBytes: Int,
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
        @SerialName("received")
        RECEIVED,

        @SerialName("rejected")
        REJECTED,
    }
}

@Serializable
data class HermesRealtimeRelayAgentTerminalRequest(
    val runtimeId: String,
    val workingDirectory: String? = null,
    val interactive: Boolean = true,
    val modelID: String? = null,
)

@Serializable
data class HermesRealtimeRelayMirrorRequest(
    val requestId: String,
    /** ISO-8601 string. Matches the Swift `Date` encoding via JSONEncoder default. */
    val requestedAt: String,
    val requesterDisplayName: String,
    val streamClass: String,
    val streamingCapabilities: HermesRealtimeRelayStreamingCapabilities? = null,
    val focusFollowMode: String? = null,
    val viewerId: String? = null,
    val viewerDeviceId: String? = null,
    val controlAuthorityPeerNodeId: String? = null,
    val remoteUnlockSession: HermesRealtimeRelayRemoteUnlockSession? = null,
    val agentTerminal: HermesRealtimeRelayAgentTerminalRequest? = null,
)

@Serializable
data class HermesRealtimeRelayDisplayDescriptor(
    val id: String,
    val name: String,
    val width: Int,
    val height: Int,
    val isPrimary: Boolean = false,
)

@Serializable
data class HermesRealtimeRelayMirrorAck(
    val requestId: String,
    val decision: Decision,
    val detail: String? = null,
    val cooldownSecondsRemaining: Int? = null,
    val availableDisplays: List<HermesRealtimeRelayDisplayDescriptor>? = null,
    val selectedDisplayId: String? = null,
    val sessionId: String? = null,
    val viewerId: String? = null,
    val viewerRole: String? = null,
    val viewerCount: Int? = null,
    val maxViewers: Int? = null,
    val controlOwnerViewerId: String? = null,
    val remoteUnlockState: HermesRealtimeRelayRemoteUnlockState? = null,
    val remoteUnlockCapabilities: HermesRealtimeRelayRemoteUnlockCapabilities? = null,
) {
    @Serializable
    enum class Decision {
        @SerialName("accepted")
        ACCEPTED,

        @SerialName("denied")
        DENIED,

        @SerialName("cooling_down")
        COOLING_DOWN,

        @SerialName("unsupported")
        UNSUPPORTED,

        @SerialName("busy")
        BUSY,
    }
}

@Serializable
data class HermesRealtimeRelayMirrorStop(
    val requestId: String,
    val sessionId: String? = null,
    /** Swift JSONEncoder's default Date encoding: seconds since 2001-01-01 UTC. */
    val stoppedAt: Double,
    val reason: String? = null,
)

@Serializable
data class HermesRealtimeRelayMirrorDisplaySelection(
    val requestId: String,
    val sessionId: String? = null,
    val displayId: String,
    /** Swift JSONEncoder's default Date encoding: seconds since 2001-01-01 UTC. */
    val selectedAt: Double,
)

@Serializable
data class HermesRealtimeRelayCallInvite(
    val requestId: String,
    /** ISO-8601 string. Matches the Swift `Date` encoding via JSONEncoder default. */
    val requestedAt: String,
    val requesterDisplayName: String,
    @OptIn(ExperimentalSerializationApi::class)
    @EncodeDefault
    val callKind: String = "video",
)

@Serializable
data class HermesRealtimeRelayCallAck(
    val requestId: String,
    val decision: Decision,
    val detail: String? = null,
) {
    @Serializable
    enum class Decision {
        @SerialName("accepted")
        ACCEPTED,

        @SerialName("denied")
        DENIED,

        @SerialName("unsupported")
        UNSUPPORTED,

        @SerialName("busy")
        BUSY,
    }
}

@Serializable
data class HermesRealtimeRelayLongTermReferenceAck(
    val requestId: String? = null,
    val tokenValue: Long,
    /** ISO-8601 string. Matches the Swift custom date encoder. */
    val decodedAt: String,
)

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

@Serializable
enum class HermesRealtimeRelayVideoCodec {
    @SerialName("av1")
    AV1,

    @SerialName("hevc")
    HEVC,

    @SerialName("h264")
    H264,
}

@Serializable
data class HermesRealtimeRelayVideoCodecCapability(
    val codec: HermesRealtimeRelayVideoCodec,
    val canEncode: Boolean,
    val canDecode: Boolean,
    val hardwareAccelerated: Boolean,
    val lowLatencyEncode: Boolean = false,
    val temporalLayering: Boolean = false,
    val longTermReference: Boolean = false,
    val screenContentCoding: Boolean = false,
)

@Serializable
data class HermesRealtimeRelayMediaFrameVersionSupport(
    val supportsV1: Boolean = true,
    val supportsV2: Boolean = false,
)

@Serializable
data class HermesRealtimeRelayDatagramCapability(
    val maxPayloadBytes: Int? = null,
)

@Serializable
data class HermesRealtimeRelayStreamingCapabilities(
    val codecCapabilities: List<HermesRealtimeRelayVideoCodecCapability>,
    val mediaFrameVersions: HermesRealtimeRelayMediaFrameVersionSupport = HermesRealtimeRelayMediaFrameVersionSupport(),
    val videoDatagrams: HermesRealtimeRelayDatagramCapability = HermesRealtimeRelayDatagramCapability(),
    val source: String,
)

@Serializable
enum class HermesRealtimeRelayMacLockState {
    @SerialName("unlocked")
    UNLOCKED,

    @SerialName("screen_saver")
    SCREEN_SAVER,

    @SerialName("screen_locked")
    SCREEN_LOCKED,

    @SerialName("display_sleeping")
    DISPLAY_SLEEPING,

    @SerialName("login_window")
    LOGIN_WINDOW,

    @SerialName("security_agent")
    SECURITY_AGENT,

    @SerialName("fast_user_switching")
    FAST_USER_SWITCHING,

    @SerialName("remote_desktop_curtain")
    REMOTE_DESKTOP_CURTAIN,

    @SerialName("reboot_login_window")
    REBOOT_LOGIN_WINDOW,

    @SerialName("filevault_preboot")
    FILEVAULT_PREBOOT,

    @SerialName("unknown")
    UNKNOWN,
}

@Serializable
enum class HermesRealtimeRelayRemoteUnlockBackend {
    @SerialName("screen_capture_kit")
    SCREEN_CAPTURE_KIT,

    @SerialName("persistent_screen_capture_kit")
    PERSISTENT_SCREEN_CAPTURE_KIT,

    @SerialName("apple_screen_sharing_loopback")
    APPLE_SCREEN_SHARING_LOOPBACK,

    @SerialName("filevault_ssh")
    FILEVAULT_SSH,

    @SerialName("unavailable")
    UNAVAILABLE,
}

@Serializable
enum class HermesRealtimeRelayRemoteUnlockCertificationStatus {
    @SerialName("uncertified")
    UNCERTIFIED,

    @SerialName("certified")
    CERTIFIED,

    @SerialName("stale")
    STALE,

    @SerialName("blocked")
    BLOCKED,

    @SerialName("failed")
    FAILED,
}

@Serializable
data class HermesRealtimeRelayRemoteUnlockCapabilities(
    val enabled: Boolean,
    val certificationStatus: HermesRealtimeRelayRemoteUnlockCertificationStatus,
    val certifiedAt: String? = null,
    val certifiedOSBuild: String? = null,
    val activeBackend: HermesRealtimeRelayRemoteUnlockBackend,
    val supportedBackends: List<HermesRealtimeRelayRemoteUnlockBackend> = emptyList(),
    val supportedLockStates: List<HermesRealtimeRelayMacLockState> = emptyList(),
    val blockers: List<String> = emptyList(),
    val allowsCredentialPaste: Boolean = false,
    val allowsSavedCredentialUnlock: Boolean = false,
    val credentialRecipientKeyId: String? = null,
    val credentialRecipientPublicKeyBase64: String? = null,
    val credentialEnvelopeAlgorithm: String? = null,
    val fileVaultSSHSupported: Boolean = false,
)

@Serializable
data class HermesRealtimeRelayRemoteUnlockSession(
    val requestId: String,
    val sessionId: String? = null,
    val intent: Intent,
    val requesterDisplayName: String,
    val viewerDeviceId: String? = null,
    val requestedAt: String,
    val expiresAt: String,
    val localAuthenticationSatisfied: Boolean,
    val requestedLockState: HermesRealtimeRelayMacLockState? = null,
    val requestedBackend: HermesRealtimeRelayRemoteUnlockBackend? = null,
    val authority: HermesRealtimeRelayAuthorityEnvelope,
) {
    @Serializable
    enum class Intent {
        @SerialName("request")
        REQUEST,

        @SerialName("attach")
        ATTACH,

        @SerialName("cancel")
        CANCEL,
    }
}

@Serializable
data class HermesRealtimeRelayRemoteUnlockState(
    val sessionId: String? = null,
    val lockState: HermesRealtimeRelayMacLockState,
    val backend: HermesRealtimeRelayRemoteUnlockBackend,
    val capabilities: HermesRealtimeRelayRemoteUnlockCapabilities,
    val controlOwnerViewerId: String? = null,
    val observedAt: String,
)

@Serializable
enum class HermesRealtimeRelayRemoteUnlockInputAction {
    @SerialName("focus_password_field")
    FOCUS_PASSWORD_FIELD,

    @SerialName("submit")
    SUBMIT,

    @SerialName("escape")
    ESCAPE,

    @SerialName("disconnect")
    DISCONNECT,

    @SerialName("key")
    KEY,

    @SerialName("pointer_move")
    POINTER_MOVE,

    @SerialName("pointer_click")
    POINTER_CLICK,
}

@Serializable
data class HermesRealtimeRelayRemoteUnlockInput(
    val requestId: String,
    val sessionId: String,
    val action: HermesRealtimeRelayRemoteUnlockInputAction,
    val key: String? = null,
    val normalizedX: Double? = null,
    val normalizedY: Double? = null,
    val clientIntentId: String,
    val requestedAt: String,
    val authority: HermesRealtimeRelayAuthorityEnvelope,
)

@Serializable
data class HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
    val requestId: String,
    val sessionId: String,
    val clientIntentId: String,
    val credentialKind: CredentialKind,
    val recipientKeyId: String,
    val algorithm: String,
    val ciphertextBase64: String,
    val aadBase64: String,
    val redactedByteCount: Int,
    val requestedAt: String,
    val expiresAt: String,
    val authority: HermesRealtimeRelayAuthorityEnvelope,
) {
    @Serializable
    enum class CredentialKind {
        @SerialName("typed_password")
        TYPED_PASSWORD,

        @SerialName("clipboard_password")
        CLIPBOARD_PASSWORD,

        @SerialName("saved_password")
        SAVED_PASSWORD,
    }
}

@Serializable
data class HermesRealtimeRelayRemoteUnlockResult(
    val requestId: String,
    val sessionId: String? = null,
    val status: Status,
    val lockState: HermesRealtimeRelayMacLockState? = null,
    val backend: HermesRealtimeRelayRemoteUnlockBackend? = null,
    val detail: String? = null,
    val completedAt: String,
) {
    @Serializable
    enum class Status {
        @SerialName("accepted")
        ACCEPTED,

        @SerialName("denied")
        DENIED,

        @SerialName("failed")
        FAILED,

        @SerialName("expired")
        EXPIRED,

        @SerialName("unlocked")
        UNLOCKED,

        @SerialName("disconnected")
        DISCONNECTED,
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
    val agentGrantRequest: HermesRealtimeRelayAgentGrantRequest? = null,
    val agentGrantReceipt: HermesRealtimeRelayAgentGrantReceipt? = null,
    val clipboardRequest: HermesRealtimeRelayClipboardRequest? = null,
    val clipboardResponse: HermesRealtimeRelayClipboardResponse? = null,
    val agentContextTarget: HermesRealtimeRelayAgentContextTarget? = null,
    val remoteUnlockSession: HermesRealtimeRelayRemoteUnlockSession? = null,
    val remoteUnlockState: HermesRealtimeRelayRemoteUnlockState? = null,
    val remoteUnlockInput: HermesRealtimeRelayRemoteUnlockInput? = null,
    val remoteUnlockCredential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope? = null,
    val remoteUnlockResult: HermesRealtimeRelayRemoteUnlockResult? = null,
    val systemPermissionRequest: HermesRealtimeRelaySystemPermissionRequest? = null,
    val systemPermissionStatus: HermesRealtimeRelaySystemPermissionStatus? = null,
    val denied: HermesRealtimeRelayControlDenied? = null,
)

@Serializable
enum class HermesRealtimeRelaySystemPermissionKind {
    @SerialName("screen_recording")
    SCREEN_RECORDING,

    @SerialName("accessibility")
    ACCESSIBILITY,

    @SerialName("camera")
    CAMERA,

    @SerialName("microphone")
    MICROPHONE,

    @SerialName("full_disk_access")
    FULL_DISK_ACCESS,

    @SerialName("automation")
    AUTOMATION,
}

@Serializable
enum class HermesRealtimeRelaySystemPermissionStatusKind {
    @SerialName("needs_access")
    NEEDS_ACCESS,

    @SerialName("requesting")
    REQUESTING,

    @SerialName("granted")
    GRANTED,

    @SerialName("denied")
    DENIED,

    @SerialName("timeout")
    TIMEOUT,

    @SerialName("unknown")
    UNKNOWN,
}

@Serializable
enum class HermesRealtimeRelaySystemPermissionAction {
    @SerialName("prompt")
    PROMPT,

    @SerialName("open_settings")
    OPEN_SETTINGS,

    @SerialName("prompt_and_open_settings")
    PROMPT_AND_OPEN_SETTINGS,

    @SerialName("probe_only")
    PROBE_ONLY,

    @SerialName("retry_failed_tool")
    RETRY_FAILED_TOOL,
}

@Serializable
data class HermesRealtimeRelaySystemPermissionRequest(
    val requestId: String,
    val clientIntentId: String,
    val kind: HermesRealtimeRelaySystemPermissionKind,
    val bundleId: String? = null,
    val originatingToolCallId: String? = null,
    val originatingToolName: String? = null,
    val action: HermesRealtimeRelaySystemPermissionAction,
    /** Swift JSONEncoder's default Date encoding: seconds since 2001-01-01 UTC. */
    val requestedAt: Double,
    val authority: HermesRealtimeRelayAuthorityEnvelope,
)

@Serializable
data class HermesRealtimeRelaySystemPermissionStatus(
    val kind: HermesRealtimeRelaySystemPermissionKind,
    val bundleId: String? = null,
    val status: HermesRealtimeRelaySystemPermissionStatusKind,
    val originatingToolCallId: String? = null,
    val originatingToolName: String? = null,
    val deepLink: String? = null,
    val instructions: String? = null,
    val failureCategory: String? = null,
    /** Swift JSONEncoder's default Date encoding: seconds since 2001-01-01 UTC. */
    val lastChangedAt: Double,
)

@Serializable
data class HermesRealtimeRelayAgentContextTarget(
    val requestId: String,
    val sessionId: String? = null,
    val runtime: String,
    val threadId: String? = null,
    val displayId: String? = null,
    val normalizedX: Double,
    val normalizedY: Double,
    val normalizedRect: HermesRealtimeRelayNormalizedRect? = null,
    val instruction: String,
    val focusContext: HermesRealtimeRelayFocusContext? = null,
    val clientIntentId: String,
    val requestedAt: Double,
    val authority: HermesRealtimeRelayAuthorityEnvelope,
)

@Serializable
enum class HermesRealtimeRelayClipboardAction {
    @SerialName("paste_to_mac")
    PASTE_TO_MAC,

    @SerialName("grab_from_mac")
    GRAB_FROM_MAC,
}

@Serializable
enum class HermesRealtimeRelayClipboardStatus {
    @SerialName("accepted")
    ACCEPTED,

    @SerialName("denied")
    DENIED,

    @SerialName("empty")
    EMPTY,

    @SerialName("too_large")
    TOO_LARGE,

    @SerialName("unsupported")
    UNSUPPORTED,

    @SerialName("error")
    ERROR,
}

@Serializable
data class HermesRealtimeRelayClipboardRequest(
    val requestId: String,
    val action: HermesRealtimeRelayClipboardAction,
    val contentType: String,
    val text: String? = null,
    val maxBytes: Int,
    val clientIntentId: String,
    val authority: HermesRealtimeRelayAuthorityEnvelope,
)

@Serializable
data class HermesRealtimeRelayClipboardResponse(
    val requestId: String,
    val action: HermesRealtimeRelayClipboardAction,
    val status: HermesRealtimeRelayClipboardStatus,
    val contentType: String? = null,
    val text: String? = null,
    val byteCount: Int? = null,
    val detail: String? = null,
)

@Serializable
data class HermesRealtimeRelayControlDenied(
    val reason: Reason,
    val detail: String? = null,
) {
    @Serializable
    enum class Reason {
        @SerialName("entitlement")
        ENTITLEMENT,

        @SerialName("session_limit")
        SESSION_LIMIT,

        @SerialName("daily_limit")
        DAILY_LIMIT,

        @SerialName("soft_cap")
        SOFT_CAP,

        @SerialName("hard_cap")
        HARD_CAP,

        @SerialName("scope")
        SCOPE,

        @SerialName("deny_region")
        DENY_REGION,

        @SerialName("kill_switch")
        KILL_SWITCH,

        @SerialName("signature_failure")
        SIGNATURE_FAILURE,

        @SerialName("counter_replay")
        COUNTER_REPLAY,

        @SerialName("stale_timestamp")
        STALE_TIMESTAMP,

        @SerialName("agent_unavailable")
        AGENT_UNAVAILABLE,

        @SerialName("unknown")
        UNKNOWN,
    }
}

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
        @SerialName("approve")
        APPROVE,

        @SerialName("reject")
        REJECT,

        @SerialName("reject_and_halt")
        REJECT_AND_HALT,
    }
}

@Serializable
data class HermesRealtimeRelayAgentGrantRequest(
    val requestId: String,
    val runtime: String,
    val threadId: String,
    val preset: String,
    val capabilities: List<String>,
    val trustMode: String,
    val deliveryMode: String,
    /** Swift JSONEncoder's default Date encoding: seconds since 2001-01-01 UTC. */
    val requestedAt: Double,
    /** Swift JSONEncoder's default Date encoding: seconds since 2001-01-01 UTC. */
    val expiresAt: Double,
    val grantDurationSeconds: Double,
    val sourceDeviceId: String,
    val clientIntentId: String,
    val localAuthenticationSatisfied: Boolean,
    val authority: HermesRealtimeRelayAuthorityEnvelope,
)

@Serializable
data class HermesRealtimeRelayAgentGrantReceipt(
    val receiptId: String,
    val requestId: String,
    val runtime: String,
    val threadId: String,
    val status: String,
    val appliedGrantId: String? = null,
    val capabilities: List<String>,
    val trustMode: String,
    /** Swift JSONEncoder's default Date encoding: seconds since 2001-01-01 UTC. */
    val receivedAt: Double,
    /** Swift JSONEncoder's default Date encoding: seconds since 2001-01-01 UTC. */
    val grantExpiresAt: Double? = null,
    val sourceDeviceId: String? = null,
    val denialReason: String? = null,
    val message: String? = null,
)

@Serializable
data class HermesRealtimeRelayInputIntent(
    val kind: HermesRealtimeRelayInputIntentKind,
    val displayId: String? = null,
    val normalizedX: Double? = null,
    val normalizedY: Double? = null,
    val normalizedX2: Double? = null,
    val normalizedY2: Double? = null,
    val text: String? = null,
    val key: String? = null,
    val modifiers: List<String>? = null,
    val mouseButton: Int? = null,
    val clientIntentId: String? = null,
    val authority: HermesRealtimeRelayAuthorityEnvelope,
)

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
internal val HermesRealtimeRelayJson: Json =
    Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
        explicitNulls = false
    }
