package com.openburnbar.data.media

import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.IrohDialTarget
import com.openburnbar.irohrelay.IrohEndpointIdentity
import com.openburnbar.irohrelay.IrohRelayStream
import com.openburnbar.irohrelay.IrohRelayTransport
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class RetainedIrohControlTransportPoolTest {
    @Test
    fun reusesTransportForSameRelayAcrossDials() = runTest {
        val created = mutableListOf<FakeTransport>()
        val pool = RetainedIrohControlTransportPool { relayURL ->
            FakeTransport(relayURL).also { created += it }
        }
        val target = IrohDialTarget(nodeId = "node-1", relayURL = "https://relay.example")

        val first = pool.dial(target, timeoutMillis = 1_000)
        val second = pool.dial(target, timeoutMillis = 1_000)

        assertEquals(1, created.size)
        assertSame(created.single().stream, first)
        assertSame(created.single().stream, second)
        assertEquals(2, created.single().startCalls)
        assertEquals(2, created.single().connectCalls)
        assertEquals(0, created.single().shutdownCalls)
    }

    @Test
    fun changingRelayShutsDownPreviousTransportBeforeCreatingReplacement() = runTest {
        val created = mutableListOf<FakeTransport>()
        val pool = RetainedIrohControlTransportPool { relayURL ->
            FakeTransport(relayURL).also { created += it }
        }

        pool.dial(IrohDialTarget(nodeId = "node-1", relayURL = "https://relay-a.example"), timeoutMillis = 1_000)
        pool.dial(IrohDialTarget(nodeId = "node-1", relayURL = "https://relay-b.example"), timeoutMillis = 1_000)

        assertEquals(2, created.size)
        assertEquals(1, created[0].shutdownCalls)
        assertEquals(0, created[1].shutdownCalls)
    }

    @Test
    fun shutdownReleasesTheRetainedTransport() = runTest {
        val created = mutableListOf<FakeTransport>()
        val pool = RetainedIrohControlTransportPool { relayURL ->
            FakeTransport(relayURL).also { created += it }
        }

        pool.dial(IrohDialTarget(nodeId = "node-1", relayURL = "https://relay.example"), timeoutMillis = 1_000)
        pool.shutdown()

        assertEquals(1, created.single().shutdownCalls)
    }

    private class FakeTransport(private val relayURL: String?) : IrohRelayTransport {
        val stream = FakeStream()
        var startCalls = 0
        var connectCalls = 0
        var shutdownCalls = 0

        override suspend fun start(): IrohEndpointIdentity {
            startCalls += 1
            return IrohEndpointIdentity(
                nodeId = "node-1",
                rawPublicKey = ByteArray(32),
                relayURL = relayURL,
            )
        }

        override suspend fun connect(target: IrohDialTarget, timeoutMillis: Long): IrohRelayStream {
            connectCalls += 1
            return stream
        }

        override suspend fun accept(timeoutMillis: Long): IrohRelayStream = stream

        override suspend fun shutdown() {
            shutdownCalls += 1
        }
    }

    private class FakeStream : IrohRelayStream {
        override suspend fun send(frame: HermesRealtimeRelayFrame) = Unit
        override suspend fun receive(): HermesRealtimeRelayFrame? = null
        override suspend fun close() = Unit
    }
}
