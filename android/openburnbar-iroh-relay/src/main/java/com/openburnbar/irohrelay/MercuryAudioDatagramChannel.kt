package com.openburnbar.irohrelay

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Mercury audio datagram channel. Wraps a UniFFI `IrohDatagramChannel`
 * (Rust-side `src/datagrams.rs`) exposed via reflection so this module
 * stays compilable on hosts without the AAR.
 *
 * Mac, iOS, and Android all dial / accept this channel on the
 * `openburnbar/mercury/audio/1` ALPN; the iroh `Endpoint` is reused
 * with the chat one, so discovery + relay state is shared.
 */
class MercuryAudioDatagramChannel internal constructor(
    private val nativeHandle: Any,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    suspend fun send(packet: ByteArray) = withContext(dispatcher) {
        try {
            nativeHandle.javaClass.getMethod("send", ByteArray::class.java).invoke(nativeHandle, packet)
        } catch (t: Throwable) {
            throw IrohBackendError.StreamFailed(t.message ?: t.javaClass.simpleName)
        }
        Unit
    }

    /** `timeoutMillis` is the per-call wait ceiling; receivers loop tightly. */
    suspend fun recv(timeoutMillis: Int): ByteArray? = withContext(dispatcher) {
        try {
            nativeHandle.javaClass.getMethod("recv", Int::class.javaPrimitiveType)
                .invoke(nativeHandle, timeoutMillis) as ByteArray?
        } catch (t: Throwable) {
            throw IrohBackendError.StreamFailed(t.message ?: t.javaClass.simpleName)
        }
    }

    suspend fun close() = withContext(dispatcher) {
        try {
            nativeHandle.javaClass.getMethod("close").invoke(nativeHandle)
        } catch (_: Throwable) {
            // idempotent close.
        }
        Unit
    }

    suspend fun maxDatagramSize(): Int = withContext(dispatcher) {
        try {
            (nativeHandle.javaClass.getMethod("maxDatagramSize").invoke(nativeHandle) as Int)
        } catch (t: Throwable) {
            throw IrohBackendError.RuntimeFailed(t.message ?: t.javaClass.simpleName)
        }
    }

    companion object {
        suspend fun open(
            backend: OpenBurnBarIrohFfiBackend,
            target: IrohDialTarget,
            timeoutMillis: Long,
        ): MercuryAudioDatagramChannel {
            val native = backend.openDatagramChannel(target, timeoutMillis)
            return MercuryAudioDatagramChannel(native)
        }

        suspend fun accept(
            backend: OpenBurnBarIrohFfiBackend,
            timeoutMillis: Long,
        ): MercuryAudioDatagramChannel {
            val native = backend.acceptDatagramChannel(timeoutMillis)
            return MercuryAudioDatagramChannel(native)
        }
    }
}
