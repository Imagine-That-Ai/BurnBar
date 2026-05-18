package com.openburnbar.data.computeruse

import com.openburnbar.data.media.MediaFrame

enum class ComputerUseTrustMode {
    MANUAL,
    STEP,
    TRUSTED;

    fun canDowngradeTo(target: ComputerUseTrustMode): Boolean = target.ordinal <= ordinal
}

enum class ComputerUseActionStatus {
    PLANNED,
    AWAITING_APPROVAL,
    EXECUTING,
    COMPLETED,
    REJECTED,
    FAILED,
    PANIC_HALTED,
}

data class ComputerUseActionLogEntry(
    val entryIndex: Int,
    val timestampMillis: Long,
    val actionKind: String,
    val summary: String,
    val status: ComputerUseActionStatus,
    val screenshotHash: String? = null,
)

data class ComputerUseApprovalRequest(
    val approvalId: String,
    val sessionId: String,
    val toolKind: String,
    val actionSummary: String,
    val requestedAtMillis: Long,
)

data class ComputerUseApprovalResponse(
    val approvalId: String,
    val approved: Boolean,
    val halt: Boolean,
    val respondedAtMillis: Long,
)

data class ComputerUseWatchState(
    val sessionId: String? = null,
    val trustMode: ComputerUseTrustMode = ComputerUseTrustMode.MANUAL,
    val actionTimeline: List<ComputerUseActionLogEntry> = emptyList(),
    val pendingApproval: ComputerUseApprovalRequest? = null,
    val currentFrame: MediaFrame? = null,
    val lastFrameReceivedAtMillis: Long? = null,
    val deniedReason: String? = null,
    val panicHalted: Boolean = false,
) {
    val latestAction: ComputerUseActionLogEntry?
        get() = actionTimeline.maxByOrNull { it.entryIndex }
}

