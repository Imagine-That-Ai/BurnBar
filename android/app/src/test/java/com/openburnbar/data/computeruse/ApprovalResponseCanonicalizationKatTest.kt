package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalResponse
import com.openburnbar.ui.computeruse.toRelayApprovalResponse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * RR-7b — Swift↔Kotlin approval-response canonicalization KAT.
 *
 * The phone signs the canonical approval-response and the Mac verifier re-hashes the SAME wire
 * response; a one-byte divergence in `respondedAt` number formatting makes every phone-signed
 * approval fail `intentHashMismatch`. The Swift verifier hashes a `SignableApprovalResponse` with
 * `JSONEncoder([.sortedKeys, .withoutEscapingSlashes])` whose default `Date` strategy emits
 * `timeIntervalSinceReferenceDate` — and a WHOLE-second Date renders as a plain integer with no
 * decimal (`721692800`, not `721692800.0`). The Compose `toRelayApprovalResponse` therefore emits
 * whole Swift-reference SECONDS so `PhoneControlSignerJsonEncoding.number()` (integer form for an
 * integer-valued Double) produces the byte-identical canonical string and hash.
 *
 * Committed canonical string + SHA-256 are computed independently (see the test comment) so a
 * regression in either platform's number/JSON shape is caught here.
 */
class ApprovalResponseCanonicalizationKatTest {
    // Whole Swift-reference seconds (2001-01-01 epoch) => unix millis (978307200 + 721692800)s.
    private val respondedAtMillis = (978_307_200L + 721_692_800L) * 1_000L

    @Test
    fun toRelayApprovalResponseEmitsWholeSecondRespondedAt() {
        val response =
            ComputerUseApprovalResponse(
                approvalId = "approval-123",
                approved = true,
                halt = false,
                respondedAtMillis = respondedAtMillis,
            ).toRelayApprovalResponse(respondedBy = "android")

        // Whole-second Swift-reference value: canonicalizes to a plain integer on both platforms.
        assertEquals(721_692_800.0, response.respondedAt, 0.0)
        assertEquals("721692800", PhoneControlSignerJsonEncoding.number(response.respondedAt))
    }

    @Test
    fun canonicalApprovalResponseJsonMatchesSwiftSortedShape() {
        val response =
            HermesRealtimeRelayApprovalResponse(
                approvalId = "approval-123",
                decision = HermesRealtimeRelayApprovalResponse.Decision.APPROVE,
                respondedBy = "android",
                respondedAt = 721_692_800.0,
                requestHashBlake3 = "a".repeat(64),
            )

        // Swift JSONEncoder([.sortedKeys]) shape: keys ascending, nil `note` omitted, integer
        // respondedAt. Byte-identical to the Mac verifier's SignableApprovalResponse encoding.
        assertEquals(
            """{"approvalId":"approval-123","decision":"approve","requestHashBlake3":""" +
                """"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",""" +
                """"respondedAt":721692800,"respondedBy":"android"}""",
            PhoneControlSignerCanonicalJson.canonicalApprovalResponseJson(response),
        )
        // Committed SHA-256 of the canonical bytes — the cross-platform hash the Mac must reproduce.
        assertEquals(
            "47c2a7c190408e2bd5610bd4b3b048be5e995b25ec2c4edf6f0106d210a04dcf",
            PhoneControlSignerCanonical.approvalResponseHashHex(response),
        )
    }

    @Test
    fun ingestReceiverPopulatesPendingApprovalWithWireRequest() {
        val reducer = ComputerUseWatchReducer()
        val receiver = AgentWatchControlFrameReceiver(reducer, uid = "uid-1", connectionId = "conn-1")
        val wireRequest = sampleApprovalRequest()

        receiver.ingest(approvalRequestFrame(wireRequest, uid = "uid-1", connectionId = "conn-1"))

        val pending = reducer.state.value.pendingApproval
        assertNotNull(pending)
        assertEquals("approval-123", pending?.approvalId)
        // The load-bearing RR-7b fix: the wireRequest is carried so the response can be signed.
        assertEquals(wireRequest, pending?.wireRequest)
        assertEquals("session-1", reducer.state.value.sessionId)
    }

    @Test
    fun ingestReceiverIgnoresFramesForOtherConnections() {
        val reducer = ComputerUseWatchReducer()
        val receiver = AgentWatchControlFrameReceiver(reducer, uid = "uid-1", connectionId = "conn-1")

        receiver.ingest(approvalRequestFrame(sampleApprovalRequest(), uid = "uid-1", connectionId = "OTHER"))

        assertNull(reducer.state.value.pendingApproval)
    }

    @Test
    fun ingestReceiverClearsPendingOnMatchingResponse() {
        val reducer = ComputerUseWatchReducer()
        val receiver = AgentWatchControlFrameReceiver(reducer, uid = "uid-1", connectionId = "conn-1")
        receiver.ingest(approvalRequestFrame(sampleApprovalRequest(), uid = "uid-1", connectionId = "conn-1"))
        assertNotNull(reducer.state.value.pendingApproval)

        receiver.ingest(
            com.openburnbar.irohrelay.HermesRealtimeRelayFrame(
                type = com.openburnbar.irohrelay.HermesRealtimeRelayFrameType.CONTROL_APPROVAL_RESPONSE,
                uid = "uid-1",
                connectionId = "conn-1",
                control =
                com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload(
                    approvalResponse =
                    HermesRealtimeRelayApprovalResponse(
                        approvalId = "approval-123",
                        decision = HermesRealtimeRelayApprovalResponse.Decision.APPROVE,
                        respondedBy = "mac",
                        respondedAt = 721_692_800.0,
                    ),
                ),
            ),
        )

        assertNull(reducer.state.value.pendingApproval)
    }

    private fun sampleApprovalRequest(): HermesRealtimeRelayApprovalRequest =
        HermesRealtimeRelayApprovalRequest(
            approvalId = "approval-123",
            runId = "run-1",
            sessionId = "session-1",
            toolKind = "bash",
            title = "Run command",
            message = "rm -rf build",
            actionSummary = "delete build dir",
            requestedAt = 721_692_800.0,
        )

    private fun approvalRequestFrame(
        request: HermesRealtimeRelayApprovalRequest,
        uid: String,
        connectionId: String,
    ): com.openburnbar.irohrelay.HermesRealtimeRelayFrame =
        com.openburnbar.irohrelay.HermesRealtimeRelayFrame(
            type = com.openburnbar.irohrelay.HermesRealtimeRelayFrameType.CONTROL_APPROVAL_REQUEST,
            uid = uid,
            connectionId = connectionId,
            control = com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload(approvalRequest = request),
        )
}
