package com.openburnbar.data.hermes

import com.openburnbar.data.hermes.relay.HermesRelayPayload
import com.openburnbar.data.hermes.relay.HermesRelayTransporting
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class HermesAuthLifecycleRegistryTest {
    @Before
    fun resetRegistry() {
        HermesAuthLifecycleRegistry.resetForTests()
    }

    @After
    fun clearRegistry() {
        HermesAuthLifecycleRegistry.resetForTests()
    }

    @Test
    fun `auth transition closes services before transports and invalidates old registrations`() = runTest {
        val events = mutableListOf<String>()
        val transport = HermesAuthLifecycleRegistry.register(priority = 50) { events += "transport" }
        val service = HermesAuthLifecycleRegistry.register(priority = 100) { events += "service" }

        val transition = HermesAuthLifecycleRegistry.holdAuthTransitionGate()
        HermesAuthLifecycleRegistry.closeResourcesForTransition(transition)

        assertEquals(listOf("service", "transport"), events)
        assertTrue(runCatching { HermesAuthLifecycleRegistry.requireCurrent(service) }.isFailure)
        assertTrue(runCatching { HermesAuthLifecycleRegistry.requireCurrent(transport) }.isFailure)
        HermesAuthLifecycleRegistry.releaseAuthTransitionGate(transition)
    }

    @Test
    fun `service destroy unregisters and awaitably closes its transport`() = runTest {
        val transport = RecordingRelayTransport()
        val service = HermesService(relayTransport = transport)

        assertEquals(1, HermesAuthLifecycleRegistry.activeResourceCountForTests())
        service.destroyAndWait()

        assertEquals(listOf("close"), transport.events)
        assertEquals(0, HermesAuthLifecycleRegistry.activeResourceCountForTests())
    }

    private class RecordingRelayTransport : HermesRelayTransporting {
        val events = mutableListOf<String>()

        override suspend fun sendUnary(payload: HermesRelayPayload, timeoutMillis: Long): String = ""

        override suspend fun sendStreaming(payload: HermesRelayPayload, timeoutMillis: Long, onSseEvent: suspend (String) -> Unit) = Unit

        override suspend fun closeForAuthTransition() {
            events += "close"
        }
    }
}
