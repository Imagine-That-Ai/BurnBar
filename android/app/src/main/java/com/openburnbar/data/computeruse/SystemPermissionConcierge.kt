package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionStatus
import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionStatusKind
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/**
 * Phase 14 — Android counterpart of `SystemPermissionInboxStore` and
 * `SystemPermissionItem` on iOS. Mirrors the same dedupe rules, the
 * same Mac-priority semantics, and the same tool-call pairing.
 */
data class SystemPermissionItem(
    val id: String,
    val threadId: String,
    val kind: PhoneControlSystemPermissionKind,
    val bundleId: String?,
    val status: SystemPermissionStatus,
    val originatingToolCallId: String?,
    val originatingToolName: String?,
    val deepLink: String?,
    val instructions: String?,
    val failureCategory: String?,
    val lastChangedAtMillis: Long,
    val source: Source,
) {
    enum class Source(val priority: Int) {
        MAC_STRUCTURED(2),
        ANDROID_HEURISTIC(1),
    }

    val dedupeKey: String
        get() = "$threadId|${kind.wireValue}|${bundleId.orEmpty()}"
}

enum class SystemPermissionStatus(val wireValue: String) {
    NEEDS_ACCESS("needs_access"),
    REQUESTING("requesting"),
    GRANTED("granted"),
    DENIED("denied"),
    TIMEOUT("timeout"),
    UNKNOWN("unknown");

    val allowsRetap: Boolean
        get() = this == NEEDS_ACCESS || this == DENIED || this == TIMEOUT || this == UNKNOWN

    companion object {
        fun from(kind: HermesRealtimeRelaySystemPermissionStatusKind): SystemPermissionStatus = when (kind) {
            HermesRealtimeRelaySystemPermissionStatusKind.NEEDS_ACCESS -> NEEDS_ACCESS
            HermesRealtimeRelaySystemPermissionStatusKind.REQUESTING -> REQUESTING
            HermesRealtimeRelaySystemPermissionStatusKind.GRANTED -> GRANTED
            HermesRealtimeRelaySystemPermissionStatusKind.DENIED -> DENIED
            HermesRealtimeRelaySystemPermissionStatusKind.TIMEOUT -> TIMEOUT
            HermesRealtimeRelaySystemPermissionStatusKind.UNKNOWN -> UNKNOWN
        }
    }
}

class SystemPermissionInboxStore {
    private val _items = MutableStateFlow<Map<String, Map<String, SystemPermissionItem>>>(emptyMap())
    val items: StateFlow<Map<String, Map<String, SystemPermissionItem>>> = _items

    var retryHandler: (suspend (SystemPermissionItem) -> Unit)? = null

    fun latestItem(threadId: String): SystemPermissionItem? =
        _items.value[threadId]?.values?.maxByOrNull { it.lastChangedAtMillis }

    fun itemsForThread(threadId: String): List<SystemPermissionItem> =
        _items.value[threadId]?.values?.sortedByDescending { it.lastChangedAtMillis }.orEmpty()

    fun clear(threadId: String) {
        _items.update { it - threadId }
    }

    fun ingest(status: HermesRealtimeRelaySystemPermissionStatus, threadId: String) {
        val item = SystemPermissionItem(
            id = java.util.UUID.randomUUID().toString(),
            threadId = threadId,
            kind = PhoneControlSystemPermissionKind.valueOf(status.kind.name),
            bundleId = status.bundleId,
            status = SystemPermissionStatus.from(status.status),
            originatingToolCallId = status.originatingToolCallId,
            originatingToolName = status.originatingToolName,
            deepLink = status.deepLink,
            instructions = status.instructions,
            failureCategory = status.failureCategory,
            lastChangedAtMillis = ((status.lastChangedAt + 978_307_200.0) * 1000.0).toLong(),
            source = SystemPermissionItem.Source.MAC_STRUCTURED,
        )
        upsert(item)
    }

    fun ingestHeuristic(
        threadId: String,
        kind: PhoneControlSystemPermissionKind,
        bundleId: String? = null,
        originatingToolCallId: String? = null,
        originatingToolName: String? = null,
        nowMillis: Long = System.currentTimeMillis(),
    ) {
        val item = SystemPermissionItem(
            id = java.util.UUID.randomUUID().toString(),
            threadId = threadId,
            kind = kind,
            bundleId = bundleId,
            status = SystemPermissionStatus.NEEDS_ACCESS,
            originatingToolCallId = originatingToolCallId,
            originatingToolName = originatingToolName,
            deepLink = systemSettingsDeepLink(kind),
            instructions = null,
            failureCategory = null,
            lastChangedAtMillis = nowMillis,
            source = SystemPermissionItem.Source.ANDROID_HEURISTIC,
        )
        upsert(item)
    }

    private fun upsert(item: SystemPermissionItem) {
        _items.update { current ->
            val bucket = current[item.threadId].orEmpty().toMutableMap()
            val existing = bucket[item.dedupeKey]
            if (existing != null) {
                if (existing.source.priority > item.source.priority) return@update current
                if (existing.status == SystemPermissionStatus.GRANTED &&
                    item.status != SystemPermissionStatus.GRANTED &&
                    item.source != SystemPermissionItem.Source.MAC_STRUCTURED
                ) return@update current
            }
            bucket[item.dedupeKey] = item
            current + (item.threadId to bucket)
        }
    }

    private fun systemSettingsDeepLink(kind: PhoneControlSystemPermissionKind): String? = when (kind) {
        PhoneControlSystemPermissionKind.SCREEN_RECORDING -> "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        PhoneControlSystemPermissionKind.ACCESSIBILITY -> "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        PhoneControlSystemPermissionKind.CAMERA -> "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        PhoneControlSystemPermissionKind.MICROPHONE -> "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        PhoneControlSystemPermissionKind.FULL_DISK_ACCESS -> "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        PhoneControlSystemPermissionKind.AUTOMATION -> "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    }
}

/**
 * Phase 14 — Process-wide singleton so the Hermes service, the iroh
 * control coordinator, and the Compose chat surface all read from the
 * same store. Mirrors `SystemPermissionInboxStore.shared` on iOS.
 */
object SystemPermissionInboxStoreHolder {
    val store = SystemPermissionInboxStore()

    /// Active thread id resolved by the chat layer at startup. Allows
    /// frame ingestion to skip work when no chat surface is alive yet.
    @Volatile
    var activeThreadId: String? = null

    fun ingest(status: HermesRealtimeRelaySystemPermissionStatus, threadId: String?) {
        val resolved = threadId ?: activeThreadId ?: return
        store.ingest(status, resolved)
    }

    fun ingestHeuristic(
        kind: PhoneControlSystemPermissionKind,
        bundleId: String? = null,
        threadId: String? = null,
        originatingToolCallId: String? = null,
        originatingToolName: String? = null,
    ) {
        val resolved = threadId ?: activeThreadId ?: return
        store.ingestHeuristic(
            threadId = resolved,
            kind = kind,
            bundleId = bundleId,
            originatingToolCallId = originatingToolCallId,
            originatingToolName = originatingToolName,
        )
    }
}

/**
 * Phase 14 — Heuristic classifier port. Same anchors as
 * `SystemPermissionToolFailureClassifier` on iOS so the Android phone
 * surfaces an inline pill when the Mac side never gets a chance to
 * report the bucket.
 */
object SystemPermissionTextClassifier {
    data class Match(
        val kind: PhoneControlSystemPermissionKind,
        val bundleId: String? = null,
        val category: String,
    )

    fun classifyToolResult(body: String): Match? = classify(body)
    fun classifyAssistantText(text: String): Match? {
        val lowered = text.lowercase()
        if (!containsPermissionTrigger(lowered)) return null
        return classify(text)
    }

    private fun classify(raw: String): Match? {
        val body = raw.lowercase()
        if (matchesScreenRecording(body)) return Match(PhoneControlSystemPermissionKind.SCREEN_RECORDING, null, "tccd_screen_recording")
        if (matchesAccessibility(body)) return Match(PhoneControlSystemPermissionKind.ACCESSIBILITY, null, "ax_trust")
        val automationBundle = automationBundleId(body)
        if (automationBundle != null) return Match(PhoneControlSystemPermissionKind.AUTOMATION, automationBundle, "apple_events")
        if (body.contains("not allowed to send apple events") ||
            body.contains("not authorized to send apple events") ||
            body.contains("-1743") ||
            (body.contains("apple events") && body.contains("not permitted"))
        ) return Match(PhoneControlSystemPermissionKind.AUTOMATION, null, "apple_events")
        if (matchesMicrophone(body)) return Match(PhoneControlSystemPermissionKind.MICROPHONE, null, "av_audio")
        if (matchesCamera(body)) return Match(PhoneControlSystemPermissionKind.CAMERA, null, "av_video")
        if (matchesFullDiskAccess(body)) return Match(PhoneControlSystemPermissionKind.FULL_DISK_ACCESS, null, "sandbox_fda")
        return null
    }

    private fun matchesScreenRecording(body: String): Boolean {
        val anchors = listOf("screen recording", "screen capture", "screencapturekit", "scstream", "cgdisplay")
        val denials = listOf("permission", "not allowed", "denied", "is required", "requires")
        if (anchors.any { body.contains(it) } && denials.any { body.contains(it) }) return true
        if (body.contains("screencapture") && body.contains("cannot")) return true
        return false
    }

    private fun matchesAccessibility(body: String): Boolean = listOf(
        "axisprocesstrusted",
        "accessibility access",
        "accessibility permission",
        "accessibility is required",
        "not trusted to use accessibility",
        "kaxerrorpermission",
        "accessibility api",
    ).any { body.contains(it) }

    private fun matchesMicrophone(body: String): Boolean = listOf(
        "microphone permission",
        "microphone access",
        "microphone is denied",
        "no permission to access the microphone",
        "audio capture is not allowed",
    ).any { body.contains(it) }

    private fun matchesCamera(body: String): Boolean = listOf(
        "camera permission",
        "camera access",
        "camera is denied",
        "no permission to access the camera",
        "video capture is not allowed",
    ).any { body.contains(it) }

    private fun matchesFullDiskAccess(body: String): Boolean {
        val pathHints = listOf("~/library/", "/library/safari", "/library/mail", "tcc.db")
        val phraseHints = listOf("full disk access", "fda", "full-disk access", "operation not permitted")
        return pathHints.any { body.contains(it) } && phraseHints.any { body.contains(it) }
    }

    private fun automationBundleId(body: String): String? {
        if (!(body.contains("apple events") || body.contains("automation") || body.contains("scripting bridge"))) return null
        val regex = Regex("(com|app|org)\\.[a-z0-9_\\-\\.]+")
        val match = regex.find(body) ?: return null
        return match.value.trim('.', ',', ';', ':', ')', '"')
    }

    private fun containsPermissionTrigger(body: String): Boolean = listOf(
        "permission",
        "not allowed",
        "denied",
        "is required",
        "requires",
        "system settings",
        "privacy & security",
        "privacy and security",
    ).any { body.contains(it) }
}
