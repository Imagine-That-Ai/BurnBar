package com.openburnbar.irohrelay

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class IrohJniTransportTest {
    @Test
    fun startRetriesTransientHomeRelayBootstrapFailure() = runTest {
        val backend = FakeBackend(failuresBeforeSuccess = 2)
        val transport = IrohJniTransport(
            backend = backend,
            secretProvider = { IrohSecretKeyMaterial(ByteArray(32) { 1 }) },
            relayURLProvider = { "https://relay.openburnbar.test/" },
        )

        val identity = transport.start()

        assertEquals("fake-node", identity.nodeId)
        assertEquals(3, backend.bootstrapCalls)
    }

    @Test
    fun startDoesNotRetryNonBootstrapRuntimeFailure() = runTest {
        val backend = FakeBackend(
            failuresBeforeSuccess = 1,
            failure = IrohBackendError.RuntimeFailed("invalid runtime state"),
        )
        val transport = IrohJniTransport(
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

    private class FakeBackend(
        private val failuresBeforeSuccess: Int,
        private val failure: IrohBackendError =
            IrohBackendError.RuntimeFailed("iroh endpoint did not select a home relay within 10s"),
    ) : IrohEndpointBackend {
        var bootstrapCalls = 0

        override suspend fun bootstrap(secret: ByteArray, relayURL: String?): IrohEndpointIdentity {
            bootstrapCalls += 1
            if (bootstrapCalls <= failuresBeforeSuccess) throw failure
            return IrohEndpointIdentity(
                nodeId = "fake-node",
                rawPublicKey = ByteArray(32) { 2 },
                relayURL = relayURL,
            )
        }

        override suspend fun identity(): IrohEndpointIdentity =
            IrohEndpointIdentity("fake-node", ByteArray(32) { 2 })

        override suspend fun connect(target: IrohDialTarget, timeoutMillis: Long): IrohBackendStream {
            throw IrohBackendError.ConnectFailed("unused")
        }

        override suspend fun acceptOne(timeoutMillis: Long): IrohBackendStream {
            throw IrohBackendError.AcceptFailed("unused")
        }

        override suspend fun shutdown() {}
    }
}
