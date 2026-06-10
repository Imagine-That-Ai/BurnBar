@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.ui.hermes

import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ack-decision policy tests for `InlineAgentMirrorView`:
 * [inlineMirrorAckPresentation] maps the Mac's mirror decision onto the
 * inline phase + status line — ACCEPTED advances toward frames, every other
 * decision is a terminal error for the attempt, and the Mac's own detail copy
 * always wins over the canned fallback.
 */
class InlineAgentMirrorViewTest {
    @Test
    fun `accepted advances to waiting for frames`() {
        val presentation = inlineMirrorAckPresentation(HermesRealtimeRelayMirrorAck.Decision.ACCEPTED, detail = null)
        assertEquals(InlineMirrorPhase.WAITING_FOR_FRAMES, presentation.phase)
        assertEquals("Mac accepted request. Starting stream...", presentation.statusMessage)
    }

    @Test
    fun `every non accepted decision is a terminal error phase`() {
        for (decision in HermesRealtimeRelayMirrorAck.Decision.values()) {
            if (decision == HermesRealtimeRelayMirrorAck.Decision.ACCEPTED) continue
            val presentation = inlineMirrorAckPresentation(decision, detail = null)
            assertEquals("$decision must land in ERROR", InlineMirrorPhase.ERROR, presentation.phase)
            assertTrue(presentation.statusMessage.isNotBlank())
        }
    }

    @Test
    fun `the macs detail copy wins over the canned fallback`() {
        val presentation = inlineMirrorAckPresentation(
            HermesRealtimeRelayMirrorAck.Decision.DENIED,
            detail = "Screen recording is off on the Mac.",
        )
        assertEquals("Screen recording is off on the Mac.", presentation.statusMessage)
    }

    @Test
    fun `canned fallbacks are decision specific`() {
        assertEquals(
            "Request denied by Mac.",
            inlineMirrorAckPresentation(HermesRealtimeRelayMirrorAck.Decision.DENIED, null).statusMessage,
        )
        assertEquals(
            "Mac is busy.",
            inlineMirrorAckPresentation(HermesRealtimeRelayMirrorAck.Decision.BUSY, null).statusMessage,
        )
        assertEquals(
            "Mac is cooling down.",
            inlineMirrorAckPresentation(HermesRealtimeRelayMirrorAck.Decision.COOLING_DOWN, null).statusMessage,
        )
        assertEquals(
            "Mac cannot mirror right now.",
            inlineMirrorAckPresentation(HermesRealtimeRelayMirrorAck.Decision.UNSUPPORTED, null).statusMessage,
        )
    }

    @Test
    fun `the phase ladder orders connection progress before live`() {
        // The mirror lifecycle leans on ordinal progression for its ladder UI:
        // every connecting state precedes LIVE, and ERROR is terminal-last.
        assertTrue(InlineMirrorPhase.CONNECTING.ordinal < InlineMirrorPhase.WAITING_FOR_FRAMES.ordinal)
        assertTrue(InlineMirrorPhase.WAITING_FOR_FRAMES.ordinal < InlineMirrorPhase.LIVE.ordinal)
        assertEquals(InlineMirrorPhase.values().size - 1, InlineMirrorPhase.ERROR.ordinal)
    }
}
