package com.openburnbar.ui.media

import com.openburnbar.data.media.MediaControlStreamCoordinator
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenShareViewerConnectionRecoveryTest {
    @Test
    fun `initial viewer resume does not probe the freshly accepted stream`() {
        val recovery = ScreenShareViewerConnectionRecovery()

        assertFalse(recovery.shouldProbeOnResume())
        assertTrue(recovery.shouldProbeOnResume())
        assertTrue(recovery.shouldProbeOnResume())
    }

    @Test
    fun `reconnected control stream rebinds the active mirror exactly once`() {
        val recovery = ScreenShareViewerConnectionRecovery()

        assertFalse(
            recovery.shouldRebindMirror(
                phase = MediaControlStreamCoordinator.Phase.Live,
                hasActiveMirrorRequest = true,
            ),
        )
        assertFalse(
            recovery.shouldRebindMirror(
                phase = MediaControlStreamCoordinator.Phase.Reconnecting(nextAttemptInMillis = 1_000L),
                hasActiveMirrorRequest = true,
            ),
        )
        assertFalse(
            recovery.shouldRebindMirror(
                phase = MediaControlStreamCoordinator.Phase.Dialing,
                hasActiveMirrorRequest = true,
            ),
        )
        assertTrue(
            recovery.shouldRebindMirror(
                phase = MediaControlStreamCoordinator.Phase.Live,
                hasActiveMirrorRequest = true,
            ),
        )
        assertFalse(
            recovery.shouldRebindMirror(
                phase = MediaControlStreamCoordinator.Phase.Live,
                hasActiveMirrorRequest = true,
            ),
        )
    }

    @Test
    fun `no active mirror request suppresses reconnect rebind`() {
        val recovery = ScreenShareViewerConnectionRecovery()

        recovery.shouldRebindMirror(
            phase = MediaControlStreamCoordinator.Phase.Reconnecting(nextAttemptInMillis = 1_000L),
            hasActiveMirrorRequest = true,
        )

        assertFalse(
            recovery.shouldRebindMirror(
                phase = MediaControlStreamCoordinator.Phase.Live,
                hasActiveMirrorRequest = false,
            ),
        )
        assertFalse(
            recovery.shouldRebindMirror(
                phase = MediaControlStreamCoordinator.Phase.Live,
                hasActiveMirrorRequest = true,
            ),
        )
    }
}
