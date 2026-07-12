package com.openburnbar.data.media

import com.openburnbar.irohrelay.IrohDialTarget
import com.openburnbar.irohrelay.IrohEndpointIdentity
import com.openburnbar.irohrelay.IrohRelayStream
import com.openburnbar.irohrelay.IrohRelayTransport
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Keeps the native iroh endpoint owner alive for the full paired-Mac control
 * session. The returned stream does not own the UniFFI endpoint handle, so
 * creating a throwaway transport per dial lets JNA/UniFFI clean up the native
 * endpoint while Mercury is still reading or reconnecting.
 */
internal class RetainedIrohControlTransportPool(
    private val transportFactory: (relayURL: String?) -> IrohRelayTransport,
) {
    private val lock = Mutex()
    private var transport: IrohRelayTransport? = null
    private var relayURL: String? = null

    suspend fun dial(target: IrohDialTarget, timeoutMillis: Long, beforeConnect: suspend (IrohEndpointIdentity) -> Unit = {}): IrohRelayStream {
        val retained = transportFor(target.relayURL)
        beforeConnect(retained.identity)
        return retained.transport.connect(target, timeoutMillis)
    }

    suspend fun shutdown() {
        val stale =
            lock.withLock {
                val current = transport
                transport = null
                relayURL = null
                current
            }
        stale?.shutdown()
    }

    private suspend fun transportFor(rawRelayURL: String?): StartedTransport {
        val normalizedRelayURL = rawRelayURL?.trim()?.takeIf { it.isNotEmpty() }
        return lock.withLock {
            val current = transport
            if (current != null && relayURL == normalizedRelayURL) {
                return@withLock StartedTransport(current, current.start())
            }

            current?.runCatching { shutdown() }
            val fresh = transportFactory(normalizedRelayURL)
            val identity = fresh.start()
            transport = fresh
            relayURL = normalizedRelayURL
            StartedTransport(fresh, identity)
        }
    }

    private data class StartedTransport(
        val transport: IrohRelayTransport,
        val identity: IrohEndpointIdentity,
    )
}
