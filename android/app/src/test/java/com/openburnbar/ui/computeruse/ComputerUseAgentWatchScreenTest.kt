package com.openburnbar.ui.computeruse

import com.openburnbar.data.computeruse.ComputerUseApprovalResponse
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalResponse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ComputerUseAgentWatchScreenTest {
    @Test
    fun approveResponseMapsToRelayApprovalPayload() {
        val relayResponse =
            ComputerUseApprovalResponse(
                approvalId = "approval-1",
                approved = true,
                halt = false,
                respondedAtMillis = 978_307_200_000L + 2_500L,
            ).toRelayApprovalResponse(respondedBy = "android-phone")

        assertEquals("approval-1", relayResponse.approvalId)
        assertEquals(HermesRealtimeRelayApprovalResponse.Decision.APPROVE, relayResponse.decision)
        assertEquals("android-phone", relayResponse.respondedBy)
        assertEquals(2.5, relayResponse.respondedAt, 0.0001)
        assertNull(relayResponse.note)
    }

    @Test
    fun rejectResponseMapsToRecoverableRelayRejection() {
        val relayResponse =
            ComputerUseApprovalResponse(
                approvalId = "approval-2",
                approved = false,
                halt = false,
                respondedAtMillis = 978_307_200_000L,
            ).toRelayApprovalResponse(respondedBy = "android-phone")

        assertEquals("approval-2", relayResponse.approvalId)
        assertEquals(HermesRealtimeRelayApprovalResponse.Decision.REJECT, relayResponse.decision)
        assertEquals("android-phone", relayResponse.respondedBy)
        assertEquals(0.0, relayResponse.respondedAt, 0.0001)
        assertEquals("Rejected from Android", relayResponse.note)
    }

    @Test
    fun rejectAndHaltResponseMapsToTerminalRelayRejection() {
        val relayResponse =
            ComputerUseApprovalResponse(
                approvalId = "approval-3",
                approved = false,
                halt = true,
                respondedAtMillis = 978_307_200_000L + 1_000L,
            ).toRelayApprovalResponse(respondedBy = "android-phone")

        assertEquals("approval-3", relayResponse.approvalId)
        assertEquals(HermesRealtimeRelayApprovalResponse.Decision.REJECT_AND_HALT, relayResponse.decision)
        assertEquals("android-phone", relayResponse.respondedBy)
        assertEquals(1.0, relayResponse.respondedAt, 0.0001)
        assertEquals("Rejected from Android and halted", relayResponse.note)
    }
}
