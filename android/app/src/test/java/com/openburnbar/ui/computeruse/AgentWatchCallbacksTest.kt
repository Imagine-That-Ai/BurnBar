package com.openburnbar.ui.computeruse

import com.openburnbar.data.computeruse.ComputerUseApprovalResponse
import com.openburnbar.data.computeruse.ComputerUseTrustMode
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalResponse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AgentWatchCallbacksTest {
    @Test
    fun callbackSurfaceInvokesEveryAgentWatchAction() {
        val calls = mutableListOf<String>()
        val callbacks =
            AgentWatchCallbacks(
                onApprove = { calls += "approve" },
                onReject = { calls += "reject" },
                onRejectAndHalt = { calls += "reject_halt" },
                onDowngrade = { calls += "downgrade:${it.name}" },
                onPanic = { calls += "panic" },
                onOpenHermes = { calls += "open_hermes" },
                onUseSuggestedRelay = { calls += "use_relay" },
                onOpenSettings = { calls += "open_settings" },
            )

        callbacks.onApprove()
        callbacks.onReject()
        callbacks.onRejectAndHalt()
        callbacks.onDowngrade(ComputerUseTrustMode.MANUAL)
        callbacks.onPanic()
        callbacks.onOpenHermes()
        callbacks.onUseSuggestedRelay()
        callbacks.onOpenSettings()

        assertEquals(
            listOf(
                "approve",
                "reject",
                "reject_halt",
                "downgrade:MANUAL",
                "panic",
                "open_hermes",
                "use_relay",
                "open_settings",
            ),
            calls,
        )
    }

    @Test
    fun relayApprovalMappingPreservesApproveRejectAndHaltDecisions() {
        val approve =
            ComputerUseApprovalResponse(
                approvalId = "approval-1",
                approved = true,
                halt = false,
                respondedAtMillis = 978_308_700_000L,
            ).toRelayApprovalResponse(respondedBy = "android-phone")
        val reject =
            ComputerUseApprovalResponse(
                approvalId = "approval-2",
                approved = false,
                halt = false,
                respondedAtMillis = 978_308_701_000L,
            ).toRelayApprovalResponse(respondedBy = "android-phone")
        val halt =
            ComputerUseApprovalResponse(
                approvalId = "approval-3",
                approved = false,
                halt = true,
                respondedAtMillis = 978_308_702_000L,
            ).toRelayApprovalResponse(respondedBy = "android-phone")

        assertEquals(HermesRealtimeRelayApprovalResponse.Decision.APPROVE, approve.decision)
        assertEquals(HermesRealtimeRelayApprovalResponse.Decision.REJECT, reject.decision)
        assertEquals(HermesRealtimeRelayApprovalResponse.Decision.REJECT_AND_HALT, halt.decision)
        assertEquals("android-phone", approve.respondedBy)
        assertEquals(1_500.0, approve.respondedAt, 0.0001)
        assertNull(approve.note)
        assertEquals("Rejected from Android", reject.note)
        assertEquals("Rejected from Android and halted", halt.note)
    }
}
