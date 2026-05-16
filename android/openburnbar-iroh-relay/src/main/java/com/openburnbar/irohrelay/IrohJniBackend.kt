package com.openburnbar.irohrelay

/**
 * Backend contract that the JNI-backed Android transport calls into.
 * Mirrors the Swift `IrohEndpointBackend` protocol. The real
 * UniFFI-generated module (`uniffi.openburnbar_iroh`) provides the
 * production implementation; tests use deterministic fakes.
 *
 * Production wiring lives in `IrohJniBackendImpl` — gated behind
 * `IrohJniBackendImpl.isAvailable()` so a clean checkout without the
 * `Vendor/openburnbar-iroh.aar` still compiles. Once the AAR is
 * present, the UniFFI bindings under `uniffi.openburnbar_iroh.*` light
 * up and the transport switches from the loopback / Firestore fallback
 * to real QUIC.
 */
interface IrohEndpointBackend {
    suspend fun bootstrap(secret: ByteArray, relayURL: String?): IrohEndpointIdentity
    suspend fun identity(): IrohEndpointIdentity
    suspend fun connect(target: IrohDialTarget, timeoutMillis: Long): IrohBackendStream
    suspend fun acceptOne(timeoutMillis: Long): IrohBackendStream
    suspend fun shutdown()
}

/**
 * Backend stream handle. Length-prefixed JSON envelopes are pushed
 * through `sendFrame` and `recvFrame` exactly as the Rust crate would
 * write to QUIC.
 */
interface IrohBackendStream {
    suspend fun sendFrame(envelope: ByteArray)
    /** Returns `null` on clean stream close. */
    suspend fun recvFrame(): ByteArray?
    suspend fun close()
}

/** 32-byte secret material handed to the backend on `bootstrap`. */
@JvmInline
value class IrohSecretKeyMaterial(val raw: ByteArray) {
    init {
        require(raw.size == 32) { "iroh secret key must be 32 bytes; got ${raw.size}" }
    }

    companion object {
        fun generate(): IrohSecretKeyMaterial {
            val bytes = ByteArray(32)
            java.security.SecureRandom().nextBytes(bytes)
            return IrohSecretKeyMaterial(bytes)
        }
    }
}

sealed class IrohBackendError(message: String) : RuntimeException(message) {
    object NotInitialized : IrohBackendError("iroh backend not initialized")
    object InvalidSecretKey : IrohBackendError("invalid iroh secret key")
    object InvalidNodeId : IrohBackendError("invalid iroh node id")
    data class ConnectFailed(val detail: String) : IrohBackendError("connect failed: $detail")
    data class StreamFailed(val detail: String) : IrohBackendError("stream failed: $detail")
    data class AcceptFailed(val detail: String) : IrohBackendError("accept failed: $detail")
    data class ShutdownFailed(val detail: String) : IrohBackendError("shutdown failed: $detail")
    data class RuntimeFailed(val detail: String) : IrohBackendError("runtime failed: $detail")
}
