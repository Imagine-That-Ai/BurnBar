package com.openburnbar.data.hermes.relay

import com.openburnbar.irohrelay.IrohRelayTransportError
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class HermesCompositeRelayTransportTest {

    private val payload = HermesRelayPayload(
        operation = "chatCompletions",
        method = "POST",
        path = "/v1/chat/completions",
        connectionID = "conn-1",
        relayPublicKey = "Q",
    )

    @Test
    fun unary_prefers_iroh_when_flag_is_on() = runTest {
        val iroh = mockk<HermesRelayTransporting>()
        val firestore = mockk<HermesRelayTransporting>()
        coEvery { iroh.sendUnary(payload, any()) } returns "iroh-result"
        coEvery { firestore.sendUnary(payload, any()) } returns "firestore-result"

        val composite = HermesCompositeRelayTransport(
            iroh = iroh,
            firestoreFallback = firestore,
            featureFlag = { true },
        )

        assertEquals("iroh-result", composite.sendUnary(payload, 100))
        coVerify(exactly = 0) { firestore.sendUnary(any(), any()) }
    }

    @Test
    fun unary_falls_back_when_flag_is_off() = runTest {
        val iroh = mockk<HermesRelayTransporting>()
        val firestore = mockk<HermesRelayTransporting>()
        coEvery { firestore.sendUnary(payload, any()) } returns "firestore-fallback"

        val composite = HermesCompositeRelayTransport(
            iroh = iroh,
            firestoreFallback = firestore,
            featureFlag = { false },
        )

        assertEquals("firestore-fallback", composite.sendUnary(payload, 100))
        coVerify(exactly = 0) { iroh.sendUnary(any(), any()) }
    }

    @Test
    fun unary_cascades_to_firestore_on_iroh_transport_error() = runTest {
        val iroh = mockk<HermesRelayTransporting>()
        val firestore = mockk<HermesRelayTransporting>()
        coEvery { iroh.sendUnary(payload, any()) } throws IrohRelayTransportError.TimedOut
        coEvery { firestore.sendUnary(payload, any()) } returns "fallback-after-timeout"

        val composite = HermesCompositeRelayTransport(
            iroh = iroh,
            firestoreFallback = firestore,
        )
        assertEquals("fallback-after-timeout", composite.sendUnary(payload, 100))
        coVerify(exactly = 1) { iroh.sendUnary(any(), any()) }
        coVerify(exactly = 1) { firestore.sendUnary(any(), any()) }
    }

    @Test
    fun unary_propagates_non_transport_errors() = runTest {
        val iroh = mockk<HermesRelayTransporting>()
        val firestore = mockk<HermesRelayTransporting>()
        coEvery { iroh.sendUnary(payload, any()) } throws HermesRelayException("decode bug")

        val composite = HermesCompositeRelayTransport(
            iroh = iroh,
            firestoreFallback = firestore,
        )
        assertThrows(HermesRelayException::class.java) {
            kotlinx.coroutines.runBlocking { composite.sendUnary(payload, 100) }
        }
        coVerify(exactly = 0) { firestore.sendUnary(any(), any()) }
    }

    @Test
    fun streaming_cascades_then_forwards_sse_events() = runTest {
        val iroh = mockk<HermesRelayTransporting>()
        val firestore = mockk<HermesRelayTransporting>()
        coEvery { iroh.sendStreaming(payload, any(), any()) } throws IrohRelayTransportError.StreamRejected("flow")
        val captured = mutableListOf<String>()
        coEvery { firestore.sendStreaming(payload, any(), any()) } answers {
            val cb = thirdArg<suspend (String) -> Unit>()
            kotlinx.coroutines.runBlocking {
                cb("chunk-a")
                cb("chunk-b")
            }
        }

        val composite = HermesCompositeRelayTransport(
            iroh = iroh,
            firestoreFallback = firestore,
        )
        composite.sendStreaming(payload, 100) { captured.add(it) }
        assertEquals(listOf("chunk-a", "chunk-b"), captured)
    }

    @Test
    fun streaming_respects_kill_switch() = runTest {
        val iroh = mockk<HermesRelayTransporting>()
        val firestore = mockk<HermesRelayTransporting>()
        coEvery { firestore.sendStreaming(payload, any(), any()) } answers {
            val cb = thirdArg<suspend (String) -> Unit>()
            kotlinx.coroutines.runBlocking { cb("force-fallback") }
        }
        val composite = HermesCompositeRelayTransport(
            iroh = iroh,
            firestoreFallback = firestore,
            featureFlag = { false },
        )
        val received = mutableListOf<String>()
        composite.sendStreaming(payload, 100) { received.add(it) }
        assertEquals(listOf("force-fallback"), received)
        coVerify(exactly = 0) { iroh.sendStreaming(any(), any(), any()) }
    }
}
