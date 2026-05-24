package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantReceipt
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

enum class AgentDesktopCapability(val wireValue: String) {
    DESKTOP_BROWSER("desktop_browser"),
    DESKTOP_SYSTEM_INPUT("desktop_system_input"),
    DESKTOP_SCREENSHOT("desktop_screenshot"),
    ACCESSIBILITY_INSPECT("accessibility_inspect"),
    DESKTOP_FILE_EXPORT("desktop_file_export"),
    WORKSPACE_READ("workspace_read"),
    WORKSPACE_WRITE("workspace_write"),
    SHELL("shell"),
    SHELL_UNRESTRICTED("shell_unrestricted"),
}

enum class AgentGrantDeliveryMode(val wireValue: String) {
    LIVE("live"),
    QUEUED("queued"),
    LIVE_THEN_QUEUED("live_then_queued"),
}

enum class AgentGrantDecisionStatus(val wireValue: String) {
    APPLIED("applied"),
    QUEUED("queued"),
    REVOKED("revoked"),
    DENIED("denied"),
    EXPIRED("expired"),
}

enum class AgentPermissionPreset(
    val title: String,
    val subtitle: String,
    val capabilities: Set<AgentDesktopCapability>,
    val trustMode: String = "manual",
    val requiresDeviceAuth: Boolean = false,
) {
    OFF("Off", "No tools", emptySet()),
    LOW("Low", "Read only", setOf(AgentDesktopCapability.WORKSPACE_READ)),
    WORKSPACE(
        "Workspace",
        "Workspace files",
        setOf(AgentDesktopCapability.WORKSPACE_READ, AgentDesktopCapability.WORKSPACE_WRITE, AgentDesktopCapability.SHELL),
    ),
    DESKTOP(
        "Desktop",
        "Browser, view, export",
        setOf(
            AgentDesktopCapability.DESKTOP_BROWSER,
            AgentDesktopCapability.DESKTOP_SCREENSHOT,
            AgentDesktopCapability.ACCESSIBILITY_INSPECT,
            AgentDesktopCapability.WORKSPACE_READ,
            AgentDesktopCapability.WORKSPACE_WRITE,
            AgentDesktopCapability.DESKTOP_FILE_EXPORT,
        ),
        requiresDeviceAuth = true,
    ),
    ALL(
        "All",
        "All bounded tools",
        AgentDesktopCapability.entries.filter { it != AgentDesktopCapability.SHELL_UNRESTRICTED }.toSet(),
        requiresDeviceAuth = true,
    ),
    YOLO(
        "YOLO",
        "Trusted everything",
        AgentDesktopCapability.entries.toSet(),
        trustMode = "trusted",
        requiresDeviceAuth = true,
    );

    val wireValue: String = name.lowercase()
}

data class AgentCapabilityGrantRequest(
    val requestId: String = UUID.randomUUID().toString(),
    val runtime: String,
    val threadId: String,
    val preset: AgentPermissionPreset,
    val deliveryMode: AgentGrantDeliveryMode = AgentGrantDeliveryMode.LIVE_THEN_QUEUED,
    val requestedAtMillis: Long = System.currentTimeMillis(),
    val expiresAtMillis: Long = requestedAtMillis + 5 * 60 * 1000,
    val grantDurationSeconds: Double = 30.0 * 60.0,
    val sourceDeviceId: String,
    val clientIntentId: String = UUID.randomUUID().toString(),
    val localAuthenticationSatisfied: Boolean = false,
) {
    val requestedAtSwiftReferenceSeconds: Double
        get() = swiftReferenceSeconds(requestedAtMillis)

    val expiresAtSwiftReferenceSeconds: Double
        get() = swiftReferenceSeconds(expiresAtMillis)

    val capabilityWireValues: List<String>
        get() = preset.capabilities.map { it.wireValue }.sorted()

    fun toWire(authority: HermesRealtimeRelayAuthorityEnvelope): HermesRealtimeRelayAgentGrantRequest =
        HermesRealtimeRelayAgentGrantRequest(
            requestId = requestId,
            runtime = runtime,
            threadId = threadId,
            preset = preset.wireValue,
            capabilities = capabilityWireValues,
            trustMode = preset.trustMode,
            deliveryMode = deliveryMode.wireValue,
            requestedAt = requestedAtSwiftReferenceSeconds,
            expiresAt = expiresAtSwiftReferenceSeconds,
            grantDurationSeconds = grantDurationSeconds,
            sourceDeviceId = sourceDeviceId,
            clientIntentId = clientIntentId,
            localAuthenticationSatisfied = localAuthenticationSatisfied,
            authority = authority,
        )

    fun pendingReceipt(message: String): AgentCapabilityGrantReceipt =
        AgentCapabilityGrantReceipt(
            receiptId = UUID.randomUUID().toString(),
            requestId = requestId,
            runtime = runtime,
            threadId = threadId,
            status = AgentGrantDecisionStatus.QUEUED,
            appliedGrantId = null,
            capabilities = capabilityWireValues,
            trustMode = preset.trustMode,
            receivedAtMillis = System.currentTimeMillis(),
            grantExpiresAtMillis = System.currentTimeMillis() + grantDurationSeconds.toLong() * 1000L,
            sourceDeviceId = sourceDeviceId,
            denialReason = null,
            message = message,
        )

    companion object {
        private const val SWIFT_REFERENCE_TO_UNIX_SECONDS = 978_307_200.0

        fun swiftReferenceSeconds(unixMillis: Long): Double =
            (unixMillis.toDouble() / 1000.0) - SWIFT_REFERENCE_TO_UNIX_SECONDS

        fun unixMillisFromSwiftReferenceSeconds(value: Double): Long =
            ((value + SWIFT_REFERENCE_TO_UNIX_SECONDS) * 1000.0).toLong()
    }
}

data class AgentCapabilityGrantReceipt(
    val receiptId: String,
    val requestId: String,
    val runtime: String,
    val threadId: String,
    val status: AgentGrantDecisionStatus,
    val appliedGrantId: String? = null,
    val capabilities: List<String> = emptyList(),
    val trustMode: String = "manual",
    val receivedAtMillis: Long = System.currentTimeMillis(),
    val grantExpiresAtMillis: Long? = null,
    val sourceDeviceId: String? = null,
    val denialReason: String? = null,
    val message: String? = null,
) {
    val isActive: Boolean
        get() = status != AgentGrantDecisionStatus.DENIED &&
            status != AgentGrantDecisionStatus.EXPIRED &&
            capabilities.isNotEmpty() &&
            (grantExpiresAtMillis ?: 0L) > System.currentTimeMillis()

    companion object {
        fun fromWire(wire: HermesRealtimeRelayAgentGrantReceipt): AgentCapabilityGrantReceipt =
            AgentCapabilityGrantReceipt(
                receiptId = wire.receiptId,
                requestId = wire.requestId,
                runtime = wire.runtime,
                threadId = wire.threadId,
                status = AgentGrantDecisionStatus.values()
                    .firstOrNull { it.wireValue == wire.status } ?: AgentGrantDecisionStatus.DENIED,
                appliedGrantId = wire.appliedGrantId,
                capabilities = wire.capabilities.sorted(),
                trustMode = wire.trustMode,
                receivedAtMillis = AgentCapabilityGrantRequest.unixMillisFromSwiftReferenceSeconds(wire.receivedAt),
                grantExpiresAtMillis = wire.grantExpiresAt?.let {
                    AgentCapabilityGrantRequest.unixMillisFromSwiftReferenceSeconds(it)
                },
                sourceDeviceId = wire.sourceDeviceId,
                denialReason = wire.denialReason,
                message = wire.message,
            )
    }
}

object AgentCapabilityGrantState {
    private val _receipts = MutableStateFlow<Map<String, AgentCapabilityGrantReceipt>>(emptyMap())
    val receipts: StateFlow<Map<String, AgentCapabilityGrantReceipt>> = _receipts

    fun apply(receipt: AgentCapabilityGrantReceipt) {
        _receipts.value = _receipts.value + (receiptKey(receipt.runtime, receipt.threadId) to receipt)
    }

    fun apply(wire: HermesRealtimeRelayAgentGrantReceipt) {
        apply(AgentCapabilityGrantReceipt.fromWire(wire))
    }

    fun optimisticGrant(runtime: String, threadId: String): AgentCapabilityGrantReceipt? {
        val receipt = _receipts.value[receiptKey(runtime, threadId)] ?: return null
        return receipt.takeIf { it.isActive }
    }

    fun hasCapability(runtime: String, threadId: String, capability: AgentDesktopCapability): Boolean =
        optimisticGrant(runtime, threadId)?.capabilities?.contains(capability.wireValue) == true

    private fun receiptKey(runtime: String, threadId: String): String = "$runtime|$threadId"
}
