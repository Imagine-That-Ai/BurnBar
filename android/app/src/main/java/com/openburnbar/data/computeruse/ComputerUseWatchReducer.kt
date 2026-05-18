package com.openburnbar.data.computeruse

import com.openburnbar.data.media.MediaFrame
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Deterministic Android reducer for the Computer Use Agent Watch overlay.
 *
 * The transport layer owns iroh bytes. This reducer owns the product state
 * rendered by Compose and is intentionally easy to unit test without a device,
 * decoder, or paired Mac.
 */
class ComputerUseWatchReducer(
    initial: ComputerUseWatchState = ComputerUseWatchState(),
) {
    private val mutableState = MutableStateFlow(initial)
    val state: StateFlow<ComputerUseWatchState> = mutableState.asStateFlow()

    fun startSession(sessionId: String, trustMode: ComputerUseTrustMode = ComputerUseTrustMode.MANUAL) {
        mutableState.update {
            it.copy(
                sessionId = sessionId,
                trustMode = trustMode,
                panicHalted = false,
                deniedReason = null,
            )
        }
    }

    fun ingestFrame(frame: MediaFrame, receivedAtMillis: Long) {
        mutableState.update {
            it.copy(currentFrame = frame, lastFrameReceivedAtMillis = receivedAtMillis)
        }
    }

    fun ingestAction(entry: ComputerUseActionLogEntry) {
        mutableState.update { current ->
            val withoutDuplicate = current.actionTimeline.filterNot { it.entryIndex == entry.entryIndex }
            current.copy(actionTimeline = (withoutDuplicate + entry).sortedBy { it.entryIndex })
        }
    }

    fun setPendingApproval(request: ComputerUseApprovalRequest?) {
        mutableState.update { it.copy(pendingApproval = request) }
    }

    fun approve(nowMillis: Long): ComputerUseApprovalResponse? {
        val request = mutableState.value.pendingApproval ?: return null
        mutableState.update { current ->
            current.copy(
                pendingApproval = null,
                actionTimeline = current.actionTimeline + ComputerUseActionLogEntry(
                    entryIndex = nextIndex(current),
                    timestampMillis = nowMillis,
                    actionKind = request.toolKind,
                    summary = "Approved: ${request.actionSummary}",
                    status = ComputerUseActionStatus.COMPLETED,
                )
            )
        }
        return ComputerUseApprovalResponse(
            approvalId = request.approvalId,
            approved = true,
            halt = false,
            respondedAtMillis = nowMillis,
        )
    }

    fun reject(halt: Boolean, nowMillis: Long): ComputerUseApprovalResponse? {
        val request = mutableState.value.pendingApproval ?: return null
        mutableState.update { current ->
            current.copy(
                pendingApproval = null,
                panicHalted = halt,
                actionTimeline = current.actionTimeline + ComputerUseActionLogEntry(
                    entryIndex = nextIndex(current),
                    timestampMillis = nowMillis,
                    actionKind = request.toolKind,
                    summary = if (halt) "Rejected and halted: ${request.actionSummary}" else "Rejected: ${request.actionSummary}",
                    status = if (halt) ComputerUseActionStatus.PANIC_HALTED else ComputerUseActionStatus.REJECTED,
                )
            )
        }
        return ComputerUseApprovalResponse(
            approvalId = request.approvalId,
            approved = false,
            halt = halt,
            respondedAtMillis = nowMillis,
        )
    }

    fun downgradeTrustMode(target: ComputerUseTrustMode) {
        mutableState.update { current ->
            if (current.trustMode.canDowngradeTo(target)) {
                current.copy(trustMode = target)
            } else {
                current
            }
        }
    }

    fun deny(reason: String) {
        mutableState.update { it.copy(deniedReason = reason) }
    }

    fun panicHalt() {
        mutableState.update {
            it.copy(
                pendingApproval = null,
                panicHalted = true,
                actionTimeline = it.actionTimeline + ComputerUseActionLogEntry(
                    entryIndex = nextIndex(it),
                    timestampMillis = System.currentTimeMillis(),
                    actionKind = "phone.panic",
                    summary = "Panic halt from Android",
                    status = ComputerUseActionStatus.PANIC_HALTED,
                )
            )
        }
    }

    fun clear() {
        mutableState.value = ComputerUseWatchState()
    }

    private fun nextIndex(state: ComputerUseWatchState): Int =
        (state.actionTimeline.maxOfOrNull { it.entryIndex } ?: -1) + 1
}

