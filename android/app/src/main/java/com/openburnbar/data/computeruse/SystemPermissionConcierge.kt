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
    UNKNOWN("unknown"),
    ;

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

    fun latestItem(threadId: String): SystemPermissionItem? = _items.value[threadId]?.values?.maxByOrNull { it.lastChangedAtMillis }

    fun itemsForThread(threadId: String): List<SystemPermissionItem> = _items.value[threadId]?.values?.sortedByDescending { it.lastChangedAtMillis }.orEmpty()

    fun clear(threadId: String) {
        _items.update { it - threadId }
    }

    fun ingest(status: HermesRealtimeRelaySystemPermissionStatus, threadId: String) {
        val item =
            SystemPermissionItem(
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
        val item =
            SystemPermissionItem(
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
                ) {
                    return@update current
                }
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

    // / Active thread id resolved by the chat layer at startup. Allows
    // / frame ingestion to skip work when no chat surface is alive yet.
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
