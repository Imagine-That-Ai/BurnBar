package com.openburnbar.irohrelay

import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Production `IrohRelayTransport` implementation for Android. Owns the
 * secret-key lifecycle, drives an `IrohEndpointBackend` (the
 * UniFFI-generated handle at runtime, a fake during tests), and wraps
 * each backend stream in an `IrohRelayStream` that re-uses the same
 * `IrohRelayFrameCodec` the loopback transport ships.
 *
 * Mirrors `IrohXcframeworkTransport` in Swift down to the error
 * surfacing logic (timeout vs stream rejection vs decode failure).
 */
class IrohJniTransport(
    private val backend: IrohEndpointBackend,
    private val codec: IrohRelayFrameCodec = IrohRelayFrameCodec(),
    private val secretProvider: () -> IrohSecretKeyMaterial,
    private val relayURLProvider: () -> String? = { null },
) : IrohRelayTransport {
    private val stateLock = Mutex()
    private var started: Boolean = false
    @Volatile private var cachedIdentity: IrohEndpointIdentity? = null

    override suspend fun start(): IrohEndpointIdentity {
        val needsBootstrap = stateLock.withLock {
            val first = !started
            started = true
            first
        }
        if (needsBootstrap) {
            return try {
                val secret = secretProvider()
                val identity = bootstrapWithRetry(secret)
                cachedIdentity = identity
                identity
            } catch (err: IrohBackendError) {
                stateLock.withLock { started = false }
                throw surface(err)
            } catch (err: Throwable) {
                stateLock.withLock { started = false }
                throw err
            }
        }
        return cachedIdentity ?: backend.identity()
    }

    private suspend fun bootstrapWithRetry(secret: IrohSecretKeyMaterial): IrohEndpointIdentity {
        var lastError: IrohBackendError? = null
        repeat(BOOTSTRAP_ATTEMPTS) { attempt ->
            try {
                return backend.bootstrap(secret.raw, relayURLProvider())
            } catch (err: IrohBackendError) {
                lastError = err
                if (!err.isRetryableBootstrapFailure() || attempt == BOOTSTRAP_ATTEMPTS - 1) {
                    throw err
                }
                delay(BOOTSTRAP_RETRY_DELAY_MILLIS * (attempt + 1))
            }
        }
        throw lastError ?: IrohBackendError.RuntimeFailed("bootstrap failed")
    }

    override suspend fun connect(target: IrohDialTarget, timeoutMillis: Long): IrohRelayStream {
        if (!stateLock.withLock { started }) throw IrohRelayTransportError.EndpointNotReady
        return try {
            val stream = backend.connect(target, timeoutMillis)
            IrohBackendStreamAdapter(stream, codec)
        } catch (err: IrohBackendError) {
            throw surface(err)
        }
    }

    override suspend fun accept(timeoutMillis: Long): IrohRelayStream {
        if (!stateLock.withLock { started }) throw IrohRelayTransportError.EndpointNotReady
        return try {
            val stream = backend.acceptOne(timeoutMillis)
            IrohBackendStreamAdapter(stream, codec)
        } catch (err: IrohBackendError) {
            throw surface(err)
        }
    }

    override suspend fun shutdown() {
        val wasStarted = stateLock.withLock {
            val w = started
            started = false
            w
        }
        if (!wasStarted) return
        backend.shutdown()
        cachedIdentity = null
    }

    companion object {
        private const val BOOTSTRAP_ATTEMPTS = 3
        private const val BOOTSTRAP_RETRY_DELAY_MILLIS = 750L

        /**
         * Bridges backend error semantics into the public transport
         * surface. Connect timeouts collapse to `TimedOut` so the
         * Firestore fallback path in `HermesCompositeRelayTransport`
         * triggers the same way as on the Swift side.
         */
        fun surface(error: IrohBackendError): IrohRelayTransportError = when (error) {
            IrohBackendError.NotInitialized -> IrohRelayTransportError.EndpointNotReady
            IrohBackendError.InvalidSecretKey,
            IrohBackendError.InvalidNodeId -> IrohRelayTransportError.StreamRejected("iroh backend rejected request: $error")
            is IrohBackendError.RuntimeFailed -> IrohRelayTransportError.StreamRejected("iroh backend rejected request: ${error.detail}")
            is IrohBackendError.ConnectFailed -> if (error.detail.contains("timed out", ignoreCase = true))
                IrohRelayTransportError.TimedOut
            else IrohRelayTransportError.StreamRejected("iroh connect failed: ${error.detail}")
            is IrohBackendError.StreamFailed -> if (error.detail.contains("timed out", ignoreCase = true))
                IrohRelayTransportError.TimedOut
            else IrohRelayTransportError.StreamRejected("iroh stream failed: ${error.detail}")
            is IrohBackendError.AcceptFailed -> if (error.detail.contains("timed out", ignoreCase = true))
                IrohRelayTransportError.TimedOut
            else IrohRelayTransportError.StreamRejected("iroh accept failed: ${error.detail}")
            is IrohBackendError.ShutdownFailed -> IrohRelayTransportError.StreamRejected("iroh shutdown failed: ${error.detail}")
        }

        private fun IrohBackendError.isRetryableBootstrapFailure(): Boolean =
            this is IrohBackendError.RuntimeFailed &&
                detail.contains("home relay", ignoreCase = true)
    }
}

/**
 * Wraps an `IrohBackendStream` (Rust handle) in the `IrohRelayStream`
 * contract by feeding raw envelopes through `IrohRelayFrameCodec`. The
 * length prefix is decoded by the backend itself, so on this side we
 * already have one whole envelope per `recvFrame` call.
 */
class IrohBackendStreamAdapter(
    private val stream: IrohBackendStream,
    private val codec: IrohRelayFrameCodec,
) : IrohRelayStream {
    override suspend fun send(frame: HermesRealtimeRelayFrame) {
        val envelope = codec.encode(frame)
        try {
            stream.sendFrame(envelope)
        } catch (err: IrohBackendError) {
            throw IrohJniTransport.surface(err)
        }
    }

    override suspend fun receive(): HermesRealtimeRelayFrame? {
        val envelope = try {
            stream.recvFrame()
        } catch (err: IrohBackendError) {
            throw IrohJniTransport.surface(err)
        } ?: return null
        return codec.decode(envelope).frame
    }

    override suspend fun close() {
        stream.close()
    }
}
