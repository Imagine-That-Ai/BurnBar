
package com.openburnbar.ui.media

import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.irohrelay.HermesRealtimeRelayCallAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import io.mockk.mockk
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
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

    @Test
    fun `mirror waits for peer readiness before sending`() = runTest {
        val events = mutableListOf<String>()

        val requestID =
            requestMirrorAfterPeerReady(
                awaitLocalReady = {
                    events += "local-live"
                    true
                },
                ensurePeerReady = {
                    events += "peer-ready"
                    true
                },
                sendMirror = {
                    events += "mirror-sent"
                    "request-1"
                },
            )

        assertEquals("request-1", requestID)
        assertEquals(listOf("local-live", "peer-ready", "mirror-sent"), events)
    }

    @Test
    fun `mirror preparation preserves the currently live control lease`() = runTest {
        val coordinator = mockk<MediaControlStreamCoordinator>()
        val calls = mutableListOf<Pair<String, Boolean>>()

        val prepared =
            prepareCoordinatorForMirrorRequest(
                connectionID = "conn-live",
                ensureStream = { connectionID, forceRestart ->
                    calls += connectionID to forceRestart
                },
                currentCoordinator = { coordinator },
            )

        assertEquals(coordinator, prepared)
        assertEquals(listOf("conn-live" to false), calls)
    }

    @Test
    fun `mirror preparation fails closed when no coordinator is available`() = runTest {
        var forceRestart: Boolean? = null

        val error =
            runCatching {
                prepareCoordinatorForMirrorRequest(
                    connectionID = "conn-live",
                    ensureStream = { _, requestedRestart -> forceRestart = requestedRestart },
                    currentCoordinator = { null },
                )
            }.exceptionOrNull()

        assertEquals(false, forceRestart)
        assertTrue(error is IllegalStateException)
        assertEquals("Mercury did not create a control coordinator.", error?.message)
    }

    @Test
    fun `mirror does not probe or send before the local stream is live`() = runTest {
        val events = mutableListOf<String>()

        val error =
            runCatching {
                requestMirrorAfterPeerReady(
                    awaitLocalReady = {
                        events += "local-not-ready"
                        false
                    },
                    ensurePeerReady = {
                        events += "peer-ready"
                        true
                    },
                    sendMirror = {
                        events += "mirror-sent"
                        "request-should-not-send"
                    },
                )
            }.exceptionOrNull()

        assertEquals(listOf("local-not-ready"), events)
        assertTrue(error is IllegalStateException)
        assertEquals(MIRROR_LOCAL_NOT_READY_MESSAGE, error?.message)
    }

    @Test
    fun `mirror is not sent before the mac confirms peer readiness`() = runTest {
        var mirrorSent = false

        val error =
            runCatching {
                requestMirrorAfterPeerReady(
                    awaitLocalReady = { true },
                    ensurePeerReady = { false },
                    sendMirror = {
                        mirrorSent = true
                        "request-should-not-send"
                    },
                )
            }.exceptionOrNull()

        assertFalse(mirrorSent)
        assertTrue(error is IllegalStateException)
        assertEquals(MIRROR_PEER_NOT_READY_MESSAGE, error?.message)
    }

    @Test
    fun `mirror timeout includes a coordinator rebuild that never returns`() = runTest {
        val events = mutableListOf<String>()

        val error =
            runCatching {
                withMirrorRequestTimeout(timeoutMillis = 100L) {
                    events += "rebuild-started"
                    delay(Long.MAX_VALUE)
                    events += "request-sent"
                }
            }.exceptionOrNull()

        assertTrue(error is TimeoutCancellationException)
        assertEquals(listOf("rebuild-started"), events)
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
        assertEquals(5_000L, MIRROR_PEER_READY_TIMEOUT_MS)
        assertEquals(25_000L, MIRROR_ACK_TIMEOUT_MS)
        assertTrue(MIRROR_ACK_TIMEOUT_MS > MIRROR_REQUEST_TIMEOUT_MS)
    }

    @Test
    fun `ready and timeout copy describe Mercury accurately`() {
        assertEquals("MERCURY READY", MERCURY_READY_PREVIEW_LABEL)
        assertFalse(MERCURY_READY_PREVIEW_LABEL.contains("MIRRORING"))

        assertEquals("No response from the Mac. Open BurnBar on the Mac, then try again.", MIRROR_NO_RESPONSE_MESSAGE)
        assertEquals("No call response from the Mac. Open BurnBar on the Mac, then try again.", CALL_NO_RESPONSE_MESSAGE)
        assertFalse(MIRROR_NO_RESPONSE_MESSAGE.contains("Local Network"))
        assertFalse(CALL_NO_RESPONSE_MESSAGE.contains("Local Network"))
    }
}
