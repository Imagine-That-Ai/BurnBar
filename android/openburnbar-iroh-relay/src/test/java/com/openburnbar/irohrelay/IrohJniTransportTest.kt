package com.openburnbar.irohrelay

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class IrohJniTransportTest {
    @Test
    fun startRetriesTransientHomeRelayBootstrapFailure() =
        runTest {
            val backend = FakeBackend(failuresBeforeSuccess = 2)
            val transport =
                IrohJniTransport(
                    backend = backend,
                    secretProvider = { IrohSecretKeyMaterial(ByteArray(32) { 1 }) },
                    relayURLProvider = { "https://relay.openburnbar.test/" },
                )

            val identity = transport.start()

            assertEquals("fake-node", identity.nodeId)
            assertEquals(3, backend.bootstrapCalls)
        }

    @Test
    fun startRetriesTransientEndpointOnlineTimeout() =
        runTest {
            val backend =
                FakeBackend(
                    failuresBeforeSuccess = 2,
                    failure = IrohBackendError.RuntimeFailed("iroh endpoint did not come online within 10s"),
                )
            val transport =
                IrohJniTransport(
                    backend = backend,
                    secretProvider = { IrohSecretKeyMaterial(ByteArray(32) { 1 }) },
                )

            val identity = transport.start()

            assertEquals("fake-node", identity.nodeId)
            assertEquals(3, backend.bootstrapCalls)
        }

    @Test
    fun startDoesNotRetryNonBootstrapRuntimeFailure() =
        runTest {
            val backend =
                FakeBackend(
                    failuresBeforeSuccess = 1,
                    failure = IrohBackendError.RuntimeFailed("invalid runtime state"),
                )
            val transport =
                IrohJniTransport(
                    backend = backend,
                    secretProvider = { IrohSecretKeyMaterial(ByteArray(32) { 1 }) },
                )

            try {
                transport.start()
                fail("Expected start() to surface a stream rejection")
            } catch (_: IrohRelayTransportError.StreamRejected) {
                // expected
            }
            assertEquals(1, backend.bootstrapCalls)
        }

    @Test
    fun connectExposesAuthenticatedRemoteNodeId() =
        runTest {
            val backend = FakeBackend(failuresBeforeSuccess = 0, connectRemoteNodeId = "signed-node")
            val transport = transport(backend)
            transport.start()

            val stream = transport.connect(IrohDialTarget(nodeId = "signed-node"), timeoutMillis = 1_000)

            assertEquals("signed-node", stream.authenticatedRemoteNodeId())
        }

    @Test
    fun connectRejectsAuthenticatedRemoteNodeIdMismatchAndClosesStream() =
        runTest {
            val backend = FakeBackend(failuresBeforeSuccess = 0, connectRemoteNodeId = "other-node")
            val transport = transport(backend)
            transport.start()

            try {
                transport.connect(IrohDialTarget(nodeId = "signed-node"), timeoutMillis = 1_000)
                fail("Expected authenticated remote mismatch to fail closed")
            } catch (error: IrohRelayTransportError.StreamRejected) {
                assertTrue(error.message.orEmpty().contains("authenticated remote node id"))
            }
            assertTrue(backend.streamClosed)
        }

    private fun transport(backend: IrohEndpointBackend) =
        IrohJniTransport(
            backend = backend,
            secretProvider = { IrohSecretKeyMaterial(ByteArray(32) { 1 }) },
        )

    private class FakeBackend(
        private val failuresBeforeSuccess: Int,
        private val failure: IrohBackendError =
            IrohBackendError.RuntimeFailed("iroh endpoint did not select a home relay within 10s"),
        private val connectRemoteNodeId: String? = null,
    ) : IrohEndpointBackend {
        var bootstrapCalls = 0
        var streamClosed = false

        override suspend fun bootstrap(
            secret: ByteArray,
            relayURL: String?,
        ): IrohEndpointIdentity {
            bootstrapCalls += 1
            if (bootstrapCalls <= failuresBeforeSuccess) throw failure
            return IrohEndpointIdentity(
                nodeId = "fake-node",
                rawPublicKey = ByteArray(32) { 2 },
                relayURL = relayURL,
            )
        }

        override suspend fun identity(): IrohEndpointIdentity = IrohEndpointIdentity("fake-node", ByteArray(32) { 2 })

        override suspend fun connect(
            target: IrohDialTarget,
            timeoutMillis: Long,
        ): IrohBackendStream {
            val remoteNodeId = connectRemoteNodeId ?: throw IrohBackendError.ConnectFailed("unused")
            return object : IrohBackendStream {
                override suspend fun authenticatedRemoteNodeId(): String = remoteNodeId

                override suspend fun sendFrame(envelope: ByteArray) = Unit

                override suspend fun recvFrame(): ByteArray? = null

                override suspend fun close() {
                    streamClosed = true
                }
            }
        }

        override suspend fun acceptOne(timeoutMillis: Long): IrohBackendStream {
            throw IrohBackendError.AcceptFailed("unused")
        }

        override suspend fun shutdown() {}
    }
}
