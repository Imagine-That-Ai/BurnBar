@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.hermes

import android.text.TextUtils
import com.google.firebase.FirebaseException
import com.openburnbar.data.hermes.relay.HermesRelayClient
import com.openburnbar.data.hermes.relay.HermesRelayConnectionDescriptor
import com.openburnbar.data.hermes.relay.HermesRelayException
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.io.IOException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Crash-regression tests for [HermesServiceConnectionActions.refreshRelayConnections].
 *
 * `listConnections()` reads Firestore, so rules denials (PERMISSION_DENIED),
 * App Check rejections, UNAVAILABLE, and sign-out auth races all surface as
 * exceptions here. `refreshRelayConnections` runs inside `refreshRuntime`'s
 * viewModelScope coroutine on Dispatchers.Main — any escaping exception
 * crashes the whole activity (reproduced on every Agents-tab entry with a
 * fresh account, emulator QA 2026-06-10). The original handler caught only
 * [IOException]; these tests pin that every failure class now degrades the
 * relay capability to [HermesRelayCapability.UNSUPPORTED] with a surfaced
 * error message instead of throwing.
 */
class HermesServiceConnectionActionsTest {
    /**
     * Builds a real [FirebaseException]: its constructor validates the
     * message through `android.text.TextUtils`, which is unmocked on the
     * pure JVM, so just that static call is bridged for the construction.
     */
    private fun firestoreDenial(message: String): FirebaseException {
        mockkStatic(TextUtils::class)
        try {
            every { TextUtils.isEmpty(any()) } answers { firstArg<CharSequence?>().isNullOrEmpty() }
            return FirebaseException(message)
        } finally {
            unmockkStatic(TextUtils::class)
        }
    }

    private fun relayThrowing(error: Throwable): HermesRelayClient = mockk {
        every { isUsable() } returns true
        coEvery { listConnections() } throws error
    }

    /**
     * Starts the service at READY so the assertions prove an actual READY →
     * UNSUPPORTED degrade, not just the constructor's UNSUPPORTED default.
     */
    private fun readyService(relay: HermesRelayClient): HermesService {
        val service = HermesService(relayClient = relay)
        service.relayCapabilityInternal.value = HermesRelayCapability.READY
        return service
    }

    private fun assertRefreshDegradesInsteadOfCrashing(error: Throwable) = runTest {
        val service = readyService(relayThrowing(error))
        try {
            HermesServiceConnectionActions(service).refreshRelayConnections()

            assertEquals(HermesRelayCapability.UNSUPPORTED, service.relayCapability.value)
            assertEquals(error.message, service.runtimeErrorText.value)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `an IOException from listConnections degrades to UNSUPPORTED instead of crashing`() {
        assertRefreshDegradesInsteadOfCrashing(IOException("Unable to resolve host firestore.googleapis.com"))
    }

    @Test
    fun `a FirebaseException from Firestore rules degrades to UNSUPPORTED instead of crashing`() {
        // The round-2 fix: PERMISSION_DENIED / App Check / UNAVAILABLE all
        // arrive as FirebaseException subtypes and previously escaped the
        // IOException-only catch, crashing the activity.
        assertRefreshDegradesInsteadOfCrashing(firestoreDenial("PERMISSION_DENIED: Missing or insufficient permissions."))
    }

    @Test
    fun `a HermesRelayException from a sign-out auth race degrades to UNSUPPORTED instead of crashing`() {
        assertRefreshDegradesInsteadOfCrashing(HermesRelayException("Sign in to Firebase to use Hermes relay."))
    }

    @Test
    fun `an unusable relay client degrades to UNSUPPORTED without ever touching Firestore`() = runTest {
        val relay = mockk<HermesRelayClient> {
            every { isUsable() } returns false
        }
        val service = readyService(relay)
        try {
            HermesServiceConnectionActions(service).refreshRelayConnections()

            assertEquals(HermesRelayCapability.UNSUPPORTED, service.relayCapability.value)
            coVerify(exactly = 0) { relay.listConnections() }
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `a successful listing maps descriptors and reports READY`() = runTest {
        // The happy path must stay distinguishable from the degraded one —
        // proving the catch blocks above narrow to failures only.
        val relay = mockk<HermesRelayClient> {
            every { isUsable() } returns true
            coEvery { listConnections() } returns listOf(
                HermesRelayConnectionDescriptor(
                    id = "mac-studio",
                    displayName = "Mac Studio",
                    relayPublicKey = "test-public-key",
                    status = "online",
                ),
            )
        }
        val service = HermesService(relayClient = relay)
        try {
            HermesServiceConnectionActions(service).refreshRelayConnections()

            assertEquals(HermesRelayCapability.READY, service.relayCapability.value)
            assertTrue(
                service.connections.value.any {
                    it.id == "mac-studio" &&
                        it.mode == HermesConnectionMode.RELAY_LINK &&
                        it.status == HermesConnectionStatus.ONLINE
                },
            )
        } finally {
            service.destroy()
        }
    }
}
