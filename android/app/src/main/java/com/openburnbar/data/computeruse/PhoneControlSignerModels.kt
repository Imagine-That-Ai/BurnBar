package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardAction
import com.openburnbar.irohrelay.HermesRealtimeRelayFocusContext
import com.openburnbar.irohrelay.HermesRealtimeRelayNormalizedRect

enum class PhoneControlIntentKind(val wireValue: String) {
    TAP("tap"),
    DRAG_START("drag_start"),
    DRAG_MOVE("drag_move"),
    DRAG_END("drag_end"),
    TYPE("type"),
    SHORTCUT("shortcut"),
    SCROLL("scroll"),
    POINTER_MOVE("pointer_move"),
    POINTER_CLICK("pointer_click"),
    PANIC("panic"),
}

data class PhoneControlIntent(
    val kind: PhoneControlIntentKind,
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
)

enum class PhoneControlClipboardAction(val wireValue: String) {
    PASTE_TO_MAC("paste_to_mac"),
    GRAB_FROM_MAC("grab_from_mac"),
}

data class PhoneControlClipboardRequest(
    val requestId: String,
    val action: PhoneControlClipboardAction,
    val contentType: String = "text/plain",
    val text: String? = null,
    val maxBytes: Int = 65_536,
    val clientIntentId: String? = null,
) {
    fun toRelayAction(): HermesRealtimeRelayClipboardAction = when (action) {
        PhoneControlClipboardAction.PASTE_TO_MAC -> HermesRealtimeRelayClipboardAction.PASTE_TO_MAC
        PhoneControlClipboardAction.GRAB_FROM_MAC -> HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC
    }
}

data class PhoneControlAgentContextTarget(
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
)

enum class PhoneControlSystemPermissionKind(val wireValue: String) {
    SCREEN_RECORDING("screen_recording"),
    ACCESSIBILITY("accessibility"),
    CAMERA("camera"),
    MICROPHONE("microphone"),
    FULL_DISK_ACCESS("full_disk_access"),
    AUTOMATION("automation"),
    ;

    fun toRelayKind(): com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind = when (this) {
        SCREEN_RECORDING -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind.SCREEN_RECORDING
        ACCESSIBILITY -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind.ACCESSIBILITY
        CAMERA -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind.CAMERA
        MICROPHONE -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind.MICROPHONE
        FULL_DISK_ACCESS -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind.FULL_DISK_ACCESS
        AUTOMATION -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind.AUTOMATION
    }
}

enum class PhoneControlSystemPermissionAction(val wireValue: String) {
    PROMPT("prompt"),
    OPEN_SETTINGS("open_settings"),
    PROMPT_AND_OPEN_SETTINGS("prompt_and_open_settings"),
    PROBE_ONLY("probe_only"),
    RETRY_FAILED_TOOL("retry_failed_tool"),
    ;

    fun toRelayAction(): com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction = when (this) {
        PROMPT -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction.PROMPT
        OPEN_SETTINGS -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction.OPEN_SETTINGS
        PROMPT_AND_OPEN_SETTINGS -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction.PROMPT_AND_OPEN_SETTINGS
        PROBE_ONLY -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction.PROBE_ONLY
        RETRY_FAILED_TOOL -> com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction.RETRY_FAILED_TOOL
    }
}

data class PhoneControlSystemPermissionRequest(
    val requestId: String,
    val kind: PhoneControlSystemPermissionKind,
    val action: PhoneControlSystemPermissionAction,
    val bundleId: String? = null,
    val originatingToolCallId: String? = null,
    val originatingToolName: String? = null,
    val clientIntentId: String? = null,
    val requestedAtMillis: Long,
) {
    val requestedAtSwiftReferenceSeconds: Double
        get() = requestedAtMillis.toDouble() / 1000.0 - 978_307_200.0
}

data class PhoneControlAuthorityEnvelope(
    val peerNodeId: String,
    val counter: Long,
    val timestampMillis: Long,
    val intentHashBlake3: String,
    val signatureEd25519: String,
) {
    val swiftDateReferenceSeconds: Double
        get() = timestampMillis.toDouble() / 1000.0 - SWIFT_REFERENCE_TO_UNIX_SECONDS

    companion object {
        private const val SWIFT_REFERENCE_TO_UNIX_SECONDS = 978_307_200.0
    }
}

sealed class PhoneControlVerifyError(message: String) : RuntimeException(message) {
    object InvalidPublicKey : PhoneControlVerifyError("invalid public key")

    object InvalidSignature : PhoneControlVerifyError("invalid signature")

    object IntentHashMismatch : PhoneControlVerifyError("intent hash mismatch")

    data class StaleTimestamp(val skewMillis: Long) :
        PhoneControlVerifyError("stale timestamp: ${skewMillis}ms")

    data class CounterReplay(val lastSeen: Long, val attempted: Long) :
        PhoneControlVerifyError("counter replay: lastSeen=$lastSeen attempted=$attempted")
}
