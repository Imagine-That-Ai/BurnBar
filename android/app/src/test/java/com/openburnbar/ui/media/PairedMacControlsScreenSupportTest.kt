
package com.openburnbar.ui.media

import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.irohrelay.HermesRealtimeRelayCallAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Decision-logic tests for `PairedMacControlsScreenSupport`: the connection-id
 * resolution that targets the paired Mac relay, the Check-Mercury triage
 * (status copy + restart decision), and the phase/ack → user-message maps the
 * controls screen renders verbatim.
 */
class PairedMacControlsScreenSupportTest {
    private val activePair = MediaControlStreamCoordinator.ActivePair(uid = "uid-1", connectionID = "conn-live")

    // ── connection-id resolution ──

    @Test
    fun `explicit connection ids win after trimming`() {
        assertEquals("conn-7", resolveRequestedConnectionID("  conn-7  ", activePair))
    }

    @Test
    fun `blank and placeholder ids fall back to the active pair`() {
        assertEquals("conn-live", resolveRequestedConnectionID(null, activePair))
        assertEquals("conn-live", resolveRequestedConnectionID("   ", activePair))
        // Square tiles pass a synthetic "paired-mac:" id — never a dial target.
        assertEquals("conn-live", resolveRequestedConnectionID("paired-mac:relay-live", activePair))
        assertNull(resolveRequestedConnectionID("paired-mac:relay-live", null))
        assertNull(resolveRequestedConnectionID(null, null))
    }

    // ── Check Mercury triage ──

    @Test
    fun `no coordinator asks the user to open the mac app and never restarts`() {
        val result = evaluateCheckMercury(
            PairedMacControlsCheckMercuryInput(
                coordinator = null,
                phase = MediaControlStreamCoordinator.Phase.Idle,
                connectionID = "conn-7",
                activePair = activePair,
                app = null,
            ),
        )
        assertFalse(result.shouldRestartMercury)
        assertTrue(requireNotNull(result.immediateStatusMessage).contains("Open BurnBar on the Mac"))
    }

    @Test
    fun `a non live coordinator restarts only when a connection and app exist`() {
        val coordinator = mockk<MediaControlStreamCoordinator>()
        val restartable = evaluateCheckMercury(
            PairedMacControlsCheckMercuryInput(
                coordinator = coordinator,
                phase = MediaControlStreamCoordinator.Phase.Stopped,
                connectionID = "conn-7",
                activePair = activePair,
                app = mockk(),
            ),
        )
        assertTrue(restartable.shouldRestartMercury)
        assertEquals("Restarting Mercury...", restartable.immediateStatusMessage)

        // Without an Application there is nothing to restart with — surface
        // the phase copy instead of pretending a retry started.
        val stuck = evaluateCheckMercury(
            PairedMacControlsCheckMercuryInput(
                coordinator = coordinator,
                phase = MediaControlStreamCoordinator.Phase.Stopped,
                connectionID = null,
                activePair = null,
                app = null,
            ),
        )
        assertFalse(stuck.shouldRestartMercury)
        assertEquals(MediaControlStreamCoordinator.Phase.Stopped.userMessage(), stuck.immediateStatusMessage)
    }

    @Test
    fun `a live coordinator reports ready and never restarts`() {
        val result = evaluateCheckMercury(
            PairedMacControlsCheckMercuryInput(
                coordinator = mockk(),
                phase = MediaControlStreamCoordinator.Phase.Live,
                connectionID = "conn-7",
                activePair = activePair,
                app = mockk(),
            ),
        )
        assertFalse(result.shouldRestartMercury)
        assertEquals("Mercury is live. Ask to Mirror is ready.", result.immediateStatusMessage)
    }

    // ── user-message maps ──

    @Test
    fun `every coordinator phase has a user message and failures carry the reason`() {
        assertEquals("Mercury is idle. Waiting for a paired Mac.", MediaControlStreamCoordinator.Phase.Idle.userMessage())
        assertEquals("Mercury is connecting to your Mac...", MediaControlStreamCoordinator.Phase.Dialing.userMessage())
        assertEquals(
            "Mercury is reconnecting to your Mac...",
            MediaControlStreamCoordinator.Phase.Reconnecting(nextAttemptInMillis = 2_000L).userMessage(),
        )
        assertEquals("Mercury unavailable: dial timeout", MediaControlStreamCoordinator.Phase.Failed("dial timeout").userMessage())
    }

    @Test
    fun `mirror and call acks prefer the macs detail copy`() {
        val denied = HermesRealtimeRelayMirrorAck(
            requestId = "req-1",
            decision = HermesRealtimeRelayMirrorAck.Decision.DENIED,
            detail = "Declined from the menu bar.",
        )
        assertEquals("Declined from the menu bar.", denied.userMessage())

        val accepted = HermesRealtimeRelayMirrorAck(requestId = "req-1", decision = HermesRealtimeRelayMirrorAck.Decision.ACCEPTED)
        assertEquals("Mac accepted. Waiting for screen frames.", accepted.userMessage())

        val callBusy = HermesRealtimeRelayCallAck(requestId = "req-2", decision = HermesRealtimeRelayCallAck.Decision.BUSY)
        assertEquals("Mac is busy.", callBusy.userMessage())
    }

    @Test
    fun `remote unlock session contract constants stay pinned`() {
        // The Mac enforces this TTL and error token; drifting them breaks the
        // remote-unlock handshake copy.
        assertEquals(600L, REMOTE_UNLOCK_SESSION_TTL_SECONDS)
        assertEquals("remote_unlock_session_required", REMOTE_UNLOCK_SESSION_REQUIRED)
        assertEquals(20_000L, MIRROR_REQUEST_TIMEOUT_MS)
    }
}
