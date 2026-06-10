@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.computeruse

import android.content.Context
import android.content.SharedPreferences
import androidx.fragment.app.FragmentActivity
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fail-closed entry-gate tests for [AgentCapabilityGrantController]: every
 * grant surface must reject a signed-out user before touching biometrics,
 * device trust, Firestore, or the phone-control sender — and the surfaced
 * errors carry the exact user-facing copy the sheets render.
 */
class AgentCapabilityGrantControllerTest {
    private fun controller(): AgentCapabilityGrantController {
        val context = mockk<Context>()
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), any()) } returns mockk<SharedPreferences>(relaxed = true)
        val auth = mockk<FirebaseAuth>()
        every { auth.currentUser } returns null
        return AgentCapabilityGrantController(
            context = context,
            auth = auth,
            firestore = mockk<FirebaseFirestore>(relaxed = true),
        )
    }

    @Test
    fun `grant fails closed with NotSignedIn before any side effect`() = runTest {
        val error = runCatching {
            controller().grant(
                activity = mockk<FragmentActivity>(),
                runtime = "claude_code",
                threadId = "thread-1",
                preset = AgentPermissionPreset.LOW,
            )
        }.exceptionOrNull()

        // The activity mock is unstubbed: reaching the biometric prompt (or any
        // later stage) would have thrown a MockKException instead.
        assertTrue("expected NotSignedIn, got $error", error is AgentCapabilityGrantController.GrantError.NotSignedIn)
        assertSame(AgentCapabilityGrantController.GrantError.NotSignedIn, error)
    }

    @Test
    fun `system permission relay also requires a signed in user`() = runTest {
        val request = PhoneControlSystemPermissionRequest(
            requestId = "req-1",
            kind = PhoneControlSystemPermissionKind.SCREEN_RECORDING,
            action = PhoneControlSystemPermissionAction.PROMPT,
            requestedAtMillis = 1_700_000_000_000L,
        )

        val error = runCatching { controller().sendSystemPermissionRequest(request) }.exceptionOrNull()

        assertSame(AgentCapabilityGrantController.GrantError.NotSignedIn, error)
    }

    @Test
    fun `grant errors carry the exact user facing copy`() {
        assertEquals(
            "Sign in before granting desktop permissions.",
            AgentCapabilityGrantController.GrantError.NotSignedIn.message,
        )
        assertEquals(
            "Device authentication did not complete.",
            AgentCapabilityGrantController.GrantError.LocalAuthenticationFailed.message,
        )
        assertEquals(
            "No paired Mac is reachable. The request was queued instead.",
            AgentCapabilityGrantController.GrantError.NoPairedMac.message,
        )
        assertEquals(
            "Approve this Android in Devices & Sync before granting Mac control.",
            AgentCapabilityGrantController.GrantError.DeviceNotTrusted.message,
        )
    }
}
