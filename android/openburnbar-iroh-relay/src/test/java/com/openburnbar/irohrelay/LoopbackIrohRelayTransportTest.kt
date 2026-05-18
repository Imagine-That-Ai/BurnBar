package com.openburnbar.irohrelay

import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Test

class LoopbackIrohRelayTransportTest {
    @Test
    fun host_and_client_exchange_round_trip() = runTest {
        val rendezvous = LoopbackIrohRelayRendezvous()
        val host = LoopbackIrohRelayTransport(rendezvous, nodeId = "host-node-1")
        val client = LoopbackIrohRelayTransport(rendezvous, nodeId = "client-node-1")

        host.start()
        client.start()

        val accepted = async {
            host.accept(timeoutMillis = 2_000)
        }
        val clientStream = client.connect(IrohDialTarget(nodeId = "host-node-1"), timeoutMillis = 2_000)
        val hostStream = accepted.await()
        assertNotNull(hostStream)

        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.HOST_REGISTER,
            uid = "uid-1",
            connectionId = "conn-1",
            payload = HermesRealtimeRelayPayload(capabilities = listOf("iroh_relay")),
        )
        clientStream.send(frame)
        val received = withTimeout(2_000) { hostStream.receive() }
        assertEquals(frame.copy(protocolVersion = IrohRelayProtocol.FRAME_PROTOCOL_VERSION), received)

        client.shutdown()
        host.shutdown()
    }

    @Test
    fun connect_times_out_when_peer_never_registers() = runTest {
        val rendezvous = LoopbackIrohRelayRendezvous()
        val client = LoopbackIrohRelayTransport(rendezvous, nodeId = "lonely-1")
        client.start()
        assertThrows(IrohRelayTransportError.TimedOut::class.java) {
            kotlinx.coroutines.runBlocking {
                client.connect(IrohDialTarget(nodeId = "nobody"), timeoutMillis = 50)
            }
        }
        client.shutdown()
    }

    @Test
    fun connect_before_start_throws_endpoint_not_ready() = runTest {
        val rendezvous = LoopbackIrohRelayRendezvous()
        val client = LoopbackIrohRelayTransport(rendezvous)
        assertThrows(IrohRelayTransportError.EndpointNotReady::class.java) {
            kotlinx.coroutines.runBlocking {
                client.connect(IrohDialTarget(nodeId = "any"), timeoutMillis = 100)
            }
        }
    }
}
