package com.openburnbar

import android.content.Intent
import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalResponse
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.IrohRelayStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

internal object MainActivityE2EComputerUseApprovalActions {
    fun launchIfNeeded(intent: Intent, scope: CoroutineScope, uid: String, connectionId: String, stream: IrohRelayStream): Job? {
        if (!intent.getBooleanExtra(MainActivity.EXTRA_E2E_COMPUTER_USE_APPROVAL_PROOF, false)) return null
        return scope.launch { handleApprovalProof(uid, connectionId, stream) }
    }

    private suspend fun handleApprovalProof(uid: String, connectionId: String, stream: IrohRelayStream) {
        val approvalFrame =
            withTimeoutOrNull(MainActivityE2EConstants.COMPUTER_USE_APPROVAL_TIMEOUT_MILLIS) {
                waitForApprovalRequest(stream)
            } ?: error("timed out waiting for control approval request")
        val request =
            approvalFrame.control?.approvalRequest
                ?: error("approval request frame missing request payload")
        MainActivityE2EComputerUseLogging.computerUseProofLog(
            "approval_request_received approvalId=${request.approvalId} tool=${request.toolKind}",
        )
        stream.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_APPROVAL_RESPONSE,
                uid = uid,
                connectionId = connectionId,
                control =
                HermesRealtimeRelayControlPayload(
                    streamClass = MediaStreamClass.CONTROL_APPROVAL.raw,
                    sessionId = request.sessionId,
                    approvalResponse =
                    HermesRealtimeRelayApprovalResponse(
                        approvalId = request.approvalId,
                        decision = HermesRealtimeRelayApprovalResponse.Decision.APPROVE,
                        respondedBy = "phone",
                        respondedAt = MainActivityE2EComputerUseLogging.swiftDateReferenceSeconds(),
                        note = "Android live paired-device approval proof",
                    ),
                ),
            ),
        )
        MainActivityE2EComputerUseLogging.computerUseProofLog("approval_response_sent approvalId=${request.approvalId}")
    }

    private suspend fun waitForApprovalRequest(stream: IrohRelayStream): HermesRealtimeRelayFrame? {
        while (true) {
            val candidate = stream.receive() ?: return null
            if (candidate.type == HermesRealtimeRelayFrameType.CONTROL_APPROVAL_REQUEST &&
                candidate.control?.approvalRequest != null
            ) {
                return candidate
            }
            MainActivityE2EComputerUseLogging.computerUseProofLog("approval_wait_ignored_frame type=${candidate.type}")
        }
    }
}
