package com.openburnbar.irohrelay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class HermesRealtimeRelayControlFrameTest {
    @Test
    fun codecRoundTripsControlInputIntentFrame() {
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT,
            uid = "uid-1",
            connectionId = "conn-1",
            control = HermesRealtimeRelayControlPayload(
                streamClass = "control.input",
                inputIntent = HermesRealtimeRelayInputIntent(
                    kind = HermesRealtimeRelayInputIntentKind.POINTER_CLICK,
                    displayId = "display-1",
                    mouseButton = 1,
                    clientIntentId = "intent-1",
                    authority = HermesRealtimeRelayAuthorityEnvelope(
                        peerNodeId = "android-phone-1",
                        counter = 42,
                        timestamp = 721_692_800.123,
                        intentHashBlake3 = "f".repeat(64),
                        signatureEd25519 = "signature",
                    ),
                ),
            ),
        )

        val codec = IrohRelayFrameCodec()
        val decoded = codec.decode(codec.encode(frame)).frame

        assertEquals(HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT, decoded.type)
        assertEquals("control.input", decoded.control?.streamClass)
        assertNotNull(decoded.control?.inputIntent)
        assertEquals(HermesRealtimeRelayInputIntentKind.POINTER_CLICK, decoded.control?.inputIntent?.kind)
        assertEquals("display-1", decoded.control?.inputIntent?.displayId)
        assertEquals(1, decoded.control?.inputIntent?.mouseButton)
        assertEquals("intent-1", decoded.control?.inputIntent?.clientIntentId)
        assertEquals(42L, decoded.control?.inputIntent?.authority?.counter)
        assertEquals("f".repeat(64), decoded.control?.inputIntent?.authority?.intentHashBlake3)
    }

    @Test
    fun codecRoundTripsControlApprovalRequestAndResponseFrames() {
        val requestFrame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.CONTROL_APPROVAL_REQUEST,
            uid = "uid-approval",
            connectionId = "conn-approval",
            control = HermesRealtimeRelayControlPayload(
                streamClass = "control.approval",
                sessionId = "session-1",
                approvalRequest = HermesRealtimeRelayApprovalRequest(
                    approvalId = "approval-1",
                    runId = "run-1",
                    sessionId = "session-1",
                    toolKind = "computer_use.mac_input.scroll",
                    title = "Scroll the active window",
                    message = "Scroll the active window",
                    actionSummary = "Scroll the active window",
                    requestedAt = 801_000_000.0,
                    trustMode = "manual",
                ),
            ),
        )
        val responseFrame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.CONTROL_APPROVAL_RESPONSE,
            uid = "uid-approval",
            connectionId = "conn-approval",
            control = HermesRealtimeRelayControlPayload(
                streamClass = "control.approval",
                sessionId = "session-1",
                approvalResponse = HermesRealtimeRelayApprovalResponse(
                    approvalId = "approval-1",
                    decision = HermesRealtimeRelayApprovalResponse.Decision.APPROVE,
                    respondedBy = "phone",
                    respondedAt = 801_000_001.0,
                ),
            ),
        )

        val codec = IrohRelayFrameCodec()
        val decodedRequest = codec.decode(codec.encode(requestFrame)).frame
        val decodedResponse = codec.decode(codec.encode(responseFrame)).frame

        assertEquals(HermesRealtimeRelayFrameType.CONTROL_APPROVAL_REQUEST, decodedRequest.type)
        assertEquals("approval-1", decodedRequest.control?.approvalRequest?.approvalId)
        assertEquals("manual", decodedRequest.control?.approvalRequest?.trustMode)
        assertEquals(HermesRealtimeRelayFrameType.CONTROL_APPROVAL_RESPONSE, decodedResponse.type)
        assertEquals("approval-1", decodedResponse.control?.approvalResponse?.approvalId)
        assertEquals(HermesRealtimeRelayApprovalResponse.Decision.APPROVE, decodedResponse.control?.approvalResponse?.decision)
        assertEquals("phone", decodedResponse.control?.approvalResponse?.respondedBy)
    }

    @Test
    fun codecRoundTripsMirrorStopFrame() {
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.MEDIA_MIRROR_STOP,
            uid = "uid-1",
            connectionId = "conn-1",
            requestId = "req-stop-1",
            media = HermesRealtimeRelayMediaPayload(
                mirrorStop = HermesRealtimeRelayMirrorStop(
                    requestId = "req-stop-1",
                    stoppedAt = 801_000_002.0,
                    reason = "viewer_closed",
                ),
            ),
        )

        val codec = IrohRelayFrameCodec()
        val decoded = codec.decode(codec.encode(frame)).frame

        assertEquals(HermesRealtimeRelayFrameType.MEDIA_MIRROR_STOP, decoded.type)
        assertEquals("req-stop-1", decoded.requestId)
        assertEquals("req-stop-1", decoded.media?.mirrorStop?.requestId)
        assertEquals(801_000_002.0, decoded.media?.mirrorStop?.stoppedAt)
        assertEquals("viewer_closed", decoded.media?.mirrorStop?.reason)
    }
}
