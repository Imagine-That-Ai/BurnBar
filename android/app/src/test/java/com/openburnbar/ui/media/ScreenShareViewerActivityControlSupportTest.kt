@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.ui.media

import com.openburnbar.irohrelay.HermesRealtimeRelayControlDenied
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
}
