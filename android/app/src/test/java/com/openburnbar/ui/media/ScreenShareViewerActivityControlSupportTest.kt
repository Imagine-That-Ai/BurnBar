
package com.openburnbar.ui.media

import com.openburnbar.irohrelay.HermesRealtimeRelayControlDenied
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Denial-copy tests for `ScreenShareViewerActivityControlSupport`:
 * [controlDeniedMessage] turns every Mac-side `control.denied` reason into
 * actionable user copy — security rejections (signature/replay/stale) read as
 * a retryable signature problem, the accessibility-revoked probe gets the
 * System Settings walkthrough, and raw internal reason tokens never leak.
 */
class ScreenShareViewerActivityControlSupportTest {
    // The extension never touches the activity receiver — a bare mock proves it.
    private val activity = mockk<ScreenShareViewerActivity>()

    private fun message(reason: HermesRealtimeRelayControlDenied.Reason, detail: String? = null): String =
        activity.controlDeniedMessage(HermesRealtimeRelayControlDenied(reason = reason, detail = detail))

    @Test
    fun `accessibility revoked probe gets the system settings walkthrough`() {
        val copy = message(HermesRealtimeRelayControlDenied.Reason.UNKNOWN, detail = "accessibility_revoked")
        assertTrue(copy.contains("Privacy & Security > Accessibility"))
        assertFalse("raw token must not leak", copy.contains("accessibility_revoked"))
    }

    @Test
    fun `crypto rejections read as one retryable signature problem`() {
        val expected = "Mac rejected the control signature. Try the action again."
        assertEquals(expected, message(HermesRealtimeRelayControlDenied.Reason.SIGNATURE_FAILURE))
        assertEquals(expected, message(HermesRealtimeRelayControlDenied.Reason.COUNTER_REPLAY))
        assertEquals(expected, message(HermesRealtimeRelayControlDenied.Reason.STALE_TIMESTAMP))
    }

    @Test
    fun `cap and limit reasons each get distinct actionable copy`() {
        assertEquals("Mac control is not enabled for this account.", message(HermesRealtimeRelayControlDenied.Reason.ENTITLEMENT))
        assertEquals(
            "Mac control session limit reached. Reopen the mirror to start a fresh session.",
            message(HermesRealtimeRelayControlDenied.Reason.SESSION_LIMIT),
        )
        assertEquals("Mac control hit today's Computer Use action limit.", message(HermesRealtimeRelayControlDenied.Reason.DAILY_LIMIT))
        assertEquals(
            "Mac control is limited while Computer Use is in soft-cap mode.",
            message(HermesRealtimeRelayControlDenied.Reason.SOFT_CAP),
        )
        assertEquals("Mac control is blocked by the Computer Use hard cap.", message(HermesRealtimeRelayControlDenied.Reason.HARD_CAP))
        assertEquals("Mac control is temporarily disabled.", message(HermesRealtimeRelayControlDenied.Reason.KILL_SWITCH))
    }

    @Test
    fun `scope and deny region read as mac side protections`() {
        assertEquals("The Mac blocked that control action for this screen.", message(HermesRealtimeRelayControlDenied.Reason.SCOPE))
        assertEquals("The Mac blocked control in a protected area.", message(HermesRealtimeRelayControlDenied.Reason.DENY_REGION))
        assertEquals("The target agent is not available.", message(HermesRealtimeRelayControlDenied.Reason.AGENT_UNAVAILABLE))
    }

    @Test
    fun `unknown reasons surface the macs detail or a generic fallback`() {
        assertEquals("Focus moved away.", message(HermesRealtimeRelayControlDenied.Reason.UNKNOWN, detail = "Focus moved away."))
        assertEquals("The Mac rejected that control action.", message(HermesRealtimeRelayControlDenied.Reason.UNKNOWN))
    }

    @Test
    fun `every reason resolves to non blank user copy`() {
        for (reason in HermesRealtimeRelayControlDenied.Reason.values()) {
            val copy = message(reason)
            assertTrue("$reason produced blank copy", copy.isNotBlank())
            assertFalse("$reason leaked an internal token", copy.contains("_"))
        }
    }

    @Test
    fun `terminal mirror acknowledgements preserve mac detail`() {
        val ack =
            HermesRealtimeRelayMirrorAck(
                requestId = "mirror-1",
                decision = HermesRealtimeRelayMirrorAck.Decision.UNSUPPORTED,
                detail = "Screen sharing requires an active Cloud Pro or Ultra subscription.",
            )

        assertEquals(
            "Screen sharing requires an active Cloud Pro or Ultra subscription.",
            mirrorAckFailureMessage(ack),
        )
    }

    @Test
    fun `accepted mirror acknowledgement has fallback copy`() {
        assertEquals(
            "Screen sharing approved.",
            mirrorAckFailureMessage(
                HermesRealtimeRelayMirrorAck(
                    requestId = "mirror-1",
                    decision = HermesRealtimeRelayMirrorAck.Decision.ACCEPTED,
                ),
            ),
        )
    }

    @Test
    fun `terminal mirror acknowledgements have useful fallback copy`() {
        val expected =
            mapOf(
                HermesRealtimeRelayMirrorAck.Decision.DENIED to "The Mac declined screen sharing.",
                HermesRealtimeRelayMirrorAck.Decision.COOLING_DOWN to
                    "The Mac is cooling down before another screen-sharing request.",
                HermesRealtimeRelayMirrorAck.Decision.UNSUPPORTED to
                    "The Mac could not start screen sharing.",
                HermesRealtimeRelayMirrorAck.Decision.BUSY to
                    "The Mac is already handling another screen-sharing request.",
            )

        for ((decision, copy) in expected) {
            assertEquals(
                copy,
                mirrorAckFailureMessage(
                    HermesRealtimeRelayMirrorAck(
                        requestId = "mirror-1",
                        decision = decision,
                    ),
                ),
            )
        }
    }

    @Test
    fun `active mirror request prefers reconnect over launch intent`() {
        assertEquals("retry-2", activeMirrorRequestID("retry-2", "launch-1"))
        assertEquals("launch-1", activeMirrorRequestID(null, "launch-1"))
        assertNull(activeMirrorRequestID(null, null))
    }

    @Test
    fun `fresh launch clears the reconnect request id`() {
        val viewer = mockk<ScreenShareViewerActivity>(relaxed = true)

        viewer.acceptFreshMirrorIntent()

        verify { viewer.reconnectedMirrorRequestID = null }
    }

    @Test
    fun `reconnect state adopts the new request and clears the old session`() {
        val viewer = mockk<ScreenShareViewerActivity>(relaxed = true)

        viewer.applyReconnectedMirrorRequest("retry-2")

        verify {
            viewer.reconnectedMirrorRequestID = "retry-2"
            viewer.mirrorSessionID = null
            viewer.mirrorViewerRole = null
            viewer.mirrorStopSent = false
        }
    }

    @Test
    fun `stale mirror acknowledgement is ignored`() {
        val viewer = mockk<ScreenShareViewerActivity>(relaxed = true)
        every { viewer.mirrorRequestID } returns "retry-2"
        val selectedDisplayID = androidx.compose.runtime.mutableStateOf<String?>(null)

        viewer.applyMirrorAck(
            HermesRealtimeRelayMirrorAck(
                requestId = "launch-1",
                decision = HermesRealtimeRelayMirrorAck.Decision.ACCEPTED,
                sessionId = "stale-session",
                selectedDisplayId = "display-2",
            ),
            selectedDisplayID,
        )

        verify(exactly = 0) { viewer.mirrorSessionID = any() }
        assertNull(selectedDisplayID.value)
    }

    @Test
    fun `accepted watcher acknowledgement applies the active session`() {
        val viewer = mockk<ScreenShareViewerActivity>(relaxed = true)
        val status = androidx.compose.runtime.mutableStateOf<String?>(null)
        val selectedDisplayID = androidx.compose.runtime.mutableStateOf<String?>(null)
        every { viewer.mirrorRequestID } returns "retry-2"
        every { viewer.controlStatus } returns status

        viewer.applyMirrorAck(
            HermesRealtimeRelayMirrorAck(
                requestId = "retry-2",
                decision = HermesRealtimeRelayMirrorAck.Decision.ACCEPTED,
                sessionId = "session-2",
                viewerRole = "watcher",
                selectedDisplayId = "display-2",
            ),
            selectedDisplayID,
        )

        verify {
            viewer.mirrorSessionID = "session-2"
            viewer.mirrorViewerRole = "watcher"
        }
        assertEquals("display-2", selectedDisplayID.value)
        assertEquals("Watching only. Another device controls the Mac.", status.value)
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test
    fun `terminal acknowledgement fails the video pipeline`() = runTest {
        val viewer = mockk<ScreenShareViewerActivity>(relaxed = true)
        val pipeline = com.openburnbar.data.media.VideoReceivePipeline()
        val status = androidx.compose.runtime.mutableStateOf<String?>(null)
        every { viewer.mirrorRequestID } returns "retry-2"
        every { viewer.controlStatus } returns status
        every { viewer.controlScope } returns this
        every { viewer.pipeline } returns pipeline

        viewer.applyMirrorAck(
            HermesRealtimeRelayMirrorAck(
                requestId = "retry-2",
                decision = HermesRealtimeRelayMirrorAck.Decision.BUSY,
            ),
            androidx.compose.runtime.mutableStateOf(null),
        )
        advanceUntilIdle()

        val phase = pipeline.phase.value
        check(phase is com.openburnbar.data.media.VideoReceivePipeline.Phase.Failed)
        assertEquals("The Mac is already handling another screen-sharing request.", phase.reason)
        assertEquals(phase.reason, status.value)
    }
}
