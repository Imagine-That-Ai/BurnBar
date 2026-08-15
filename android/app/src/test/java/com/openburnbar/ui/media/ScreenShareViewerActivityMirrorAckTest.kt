package com.openburnbar.ui.media

import androidx.compose.runtime.mutableStateOf
import com.openburnbar.data.media.VideoReceivePipeline
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirror-acknowledgement handling tests for
 * `ScreenShareViewerActivitySections`: [applyMirrorAck] must ignore
 * acknowledgements for a request ID other than the active one, record
 * session identity on accepted acknowledgements, and on terminal decisions
 * surface the Mac's failure copy while driving the receive pipeline into
 * `Failed` so the viewer stops waiting for frames.
 */
class ScreenShareViewerActivityMirrorAckTest {
    private val status = mutableStateOf<String?>(null)
    private val pipeline = VideoReceivePipeline()
    private val activity = mockk<ScreenShareViewerActivity>(relaxed = true)

    private fun bindActivity(activeRequestID: String = "mirror-1") {
        every { activity.mirrorRequestID } returns activeRequestID
        every { activity.controlStatus } returns status
        every { activity.controlScope } returns CoroutineScope(Dispatchers.Unconfined)
        every { activity.pipeline } returns pipeline
    }

    @Test
    fun `acknowledgements for a stale request id are ignored`() {
        bindActivity(activeRequestID = "mirror-live")
        val selectedDisplayId = mutableStateOf<String?>(null)

        activity.applyMirrorAck(
            HermesRealtimeRelayMirrorAck(
                requestId = "mirror-stale",
                decision = HermesRealtimeRelayMirrorAck.Decision.DENIED,
                sessionId = "session-9",
                selectedDisplayId = "display-9",
            ),
            selectedDisplayId,
        )

        assertNull(status.value)
        assertNull(selectedDisplayId.value)
        assertTrue(pipeline.phase.value is VideoReceivePipeline.Phase.Idle)
        verify(exactly = 0) { activity.mirrorSessionID = any() }
    }

    @Test
    fun `accepted watcher ack records session identity and watch-only copy`() {
        bindActivity()
        val selectedDisplayId = mutableStateOf<String?>(null)

        activity.applyMirrorAck(
            HermesRealtimeRelayMirrorAck(
                requestId = "mirror-1",
                decision = HermesRealtimeRelayMirrorAck.Decision.ACCEPTED,
                sessionId = "session-1",
                viewerRole = "watcher",
                selectedDisplayId = "display-1",
            ),
            selectedDisplayId,
        )

        assertEquals("Watching only. Another device controls the Mac.", status.value)
        assertEquals("display-1", selectedDisplayId.value)
        assertTrue(pipeline.phase.value is VideoReceivePipeline.Phase.Idle)
        verify { activity.mirrorSessionID = "session-1" }
        verify { activity.mirrorViewerRole = "watcher" }
    }

    @Test
    fun `accepted controller ack leaves the control status untouched`() {
        bindActivity()
        val selectedDisplayId = mutableStateOf<String?>(null)

        activity.applyMirrorAck(
            HermesRealtimeRelayMirrorAck(
                requestId = "mirror-1",
                decision = HermesRealtimeRelayMirrorAck.Decision.ACCEPTED,
                sessionId = "session-1",
                viewerRole = "controller",
            ),
            selectedDisplayId,
        )

        assertNull(status.value)
        assertTrue(pipeline.phase.value is VideoReceivePipeline.Phase.Idle)
        verify { activity.mirrorViewerRole = "controller" }
    }

    @Test
    fun `terminal ack surfaces mac detail and fails the receive pipeline`() {
        bindActivity()
        val selectedDisplayId = mutableStateOf<String?>(null)

        activity.applyMirrorAck(
            HermesRealtimeRelayMirrorAck(
                requestId = "mirror-1",
                decision = HermesRealtimeRelayMirrorAck.Decision.UNSUPPORTED,
                detail = "Screen sharing requires an active Cloud Pro or Ultra subscription.",
            ),
            selectedDisplayId,
        )

        assertEquals("Screen sharing requires an active Cloud Pro or Ultra subscription.", status.value)
        val phase = pipeline.phase.value
        check(phase is VideoReceivePipeline.Phase.Failed) { "Expected Failed phase but was $phase" }
        assertEquals("Screen sharing requires an active Cloud Pro or Ultra subscription.", phase.reason)
    }

    @Test
    fun `terminal ack without detail fails the pipeline with fallback copy`() {
        bindActivity()
        val selectedDisplayId = mutableStateOf<String?>(null)

        activity.applyMirrorAck(
            HermesRealtimeRelayMirrorAck(
                requestId = "mirror-1",
                decision = HermesRealtimeRelayMirrorAck.Decision.BUSY,
            ),
            selectedDisplayId,
        )

        assertEquals("The Mac is already handling another screen-sharing request.", status.value)
        val phase = pipeline.phase.value
        check(phase is VideoReceivePipeline.Phase.Failed) { "Expected Failed phase but was $phase" }
        assertEquals("The Mac is already handling another screen-sharing request.", phase.reason)
    }
}
