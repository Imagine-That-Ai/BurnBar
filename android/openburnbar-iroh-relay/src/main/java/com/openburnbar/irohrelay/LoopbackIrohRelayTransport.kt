package com.openburnbar.irohrelay

import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.random.Random
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * In-process iroh transport for tests + the spine demo. Pairs Mac-side
 * and Android-side endpoints through a shared rendezvous. Frames are
 * encoded with the same `IrohRelayFrameCodec` the production transport
 * uses, so this covers the on-wire envelope byte-for-byte.
 *
 * Why in-process and not loopback UDP: deterministic, hermetic fixtures
 * for unit tests. The JNI-backed transport runs against real iroh in CI
 * via the `openburnbar-iroh AAR` workflow.
 */
class LoopbackIrohRelayRendezvous {
    private val hosts = mutableMapOf<String, LoopbackIrohRelayTransport>()
    private val pending = mutableMapOf<String, MutableList<PendingConnect>>()
    private val state = Any()

    private data class PendingConnect(
        val id: UUID,
        val continuation: CancellableContinuation<IrohRelayStream>,
    )

    internal fun register(transport: LoopbackIrohRelayTransport, nodeId: String) {
        val waiters: List<PendingConnect>
        synchronized(state) {
            hosts[nodeId] = transport
            waiters = pending.remove(nodeId).orEmpty()
        }
        for (waiter in waiters) {
            transport.fulfillDial(waiter.id, waiter.continuation)
        }
    }

    internal fun deregister(nodeId: String) {
        synchronized(state) { hosts.remove(nodeId) }
    }

    suspend fun dial(peer: String, timeoutMillis: Long): IrohRelayStream {
        val connectId = UUID.randomUUID()
        val resolvedHost: LoopbackIrohRelayTransport? = synchronized(state) { hosts[peer] }
        if (resolvedHost != null) {
            return suspendCancellableCoroutine<IrohRelayStream> { cont ->
                resolvedHost.fulfillDial(connectId, cont)
            }
        }
        val result = withTimeoutOrNull(timeoutMillis) {
            suspendCancellableCoroutine<IrohRelayStream> { cont ->
                cont.invokeOnCancellation {
                    synchronized(state) {
                        pending[peer]?.removeAll { it.id == connectId }
                    }
                }
                synchronized(state) {
                    pending.getOrPut(peer) { mutableListOf() }
                        .add(PendingConnect(connectId, cont))
                }
            }
        }
        return result ?: run {
            synchronized(state) {
                pending[peer]?.removeAll { it.id == connectId }
            }
            throw IrohRelayTransportError.TimedOut
        }
    }
}

internal class LoopbackQueue {
    private val channel = Channel<ByteArray>(Channel.UNLIMITED)
    private val closed = AtomicBoolean(false)

    fun push(data: ByteArray) {
        if (closed.get()) return
        channel.trySend(data)
    }

    suspend fun pop(): ByteArray? {
        if (closed.get() && channel.isEmpty) return null
        return channel.receiveCatching().getOrNull()
    }

    fun close() {
        if (closed.compareAndSet(false, true)) {
            channel.close()
        }
    }
}

internal class LoopbackStreamPair {
    val clientToHost = LoopbackQueue()
    val hostToClient = LoopbackQueue()
}

/** Loopback stream half. Encodes/decodes via the same codec used in prod. */
class LoopbackIrohRelayStream internal constructor(
    private val readQueue: LoopbackQueue,
    private val writeQueue: LoopbackQueue,
    private val codec: IrohRelayFrameCodec,
) : IrohRelayStream {
    private val buffer = ArrayDeque<Byte>()

    override suspend fun send(frame: HermesRealtimeRelayFrame) {
        writeQueue.push(codec.encode(frame))
    }

    override suspend fun receive(): HermesRealtimeRelayFrame? {
        while (true) {
            if (buffer.size >= IrohRelayProtocol.WireFormat.LENGTH_PREFIX_BYTES) {
                try {
                    val snapshot = buffer.toByteArray()
                    val decoded = codec.decode(snapshot)
                    repeat(decoded.consumed) { buffer.removeFirst() }
                    return decoded.frame
                } catch (e: IrohRelayTransportError.DecodeFailed) {
                    // Need more bytes; fall through.
                }
            }
            val chunk = readQueue.pop()
            if (chunk == null) {
                if (buffer.isNotEmpty()) {
                    throw IrohRelayTransportError.DecodeFailed("stream closed mid-frame with ${buffer.size} bytes buffered")
                }
                return null
            }
            chunk.forEach { buffer.addLast(it) }
        }
    }

    override suspend fun close() {
        writeQueue.close()
    }

    private fun ArrayDeque<Byte>.toByteArray(): ByteArray {
        val out = ByteArray(size)
        var idx = 0
        for (b in this) {
            out[idx++] = b
        }
        return out
    }
}

/**
 * Public loopback transport. `start()` registers in the rendezvous;
 * `connect(target)` dials; `accept()` returns the next inbound stream.
 */
class LoopbackIrohRelayTransport(
    private val rendezvous: LoopbackIrohRelayRendezvous,
    nodeId: String? = null,
    private val codec: IrohRelayFrameCodec = IrohRelayFrameCodec(),
) : IrohRelayTransport {
    private val identity = IrohEndpointIdentity(
        nodeId = nodeId ?: randomLoopbackNodeId(),
        rawPublicKey = ByteArray(32),
    )
    private val accept = Channel<IrohRelayStream>(Channel.UNLIMITED)
    private val stateLock = Mutex()
    private var started: Boolean = false

    override suspend fun start(): IrohEndpointIdentity {
        val first = stateLock.withLock {
            val f = !started
            started = true
            f
        }
        if (first) {
            rendezvous.register(this, identity.nodeId)
        }
        return identity
    }

    override suspend fun connect(target: IrohDialTarget, timeoutMillis: Long): IrohRelayStream {
        if (!stateLock.withLock { started }) throw IrohRelayTransportError.EndpointNotReady
        return rendezvous.dial(target.nodeId, timeoutMillis)
    }

    override suspend fun accept(timeoutMillis: Long): IrohRelayStream {
        if (!stateLock.withLock { started }) throw IrohRelayTransportError.EndpointNotReady
        val received = withTimeoutOrNull(timeoutMillis) { accept.receive() }
            ?: throw IrohRelayTransportError.TimedOut
        return received
    }

    override suspend fun shutdown() {
        val wasStarted = stateLock.withLock {
            val w = started
            started = false
            w
        }
        if (!wasStarted) return
        rendezvous.deregister(identity.nodeId)
        accept.close()
    }

    internal fun fulfillDial(connectId: UUID, continuation: CancellableContinuation<IrohRelayStream>) {
        val pair = LoopbackStreamPair()
        val clientStream = LoopbackIrohRelayStream(
            readQueue = pair.hostToClient,
            writeQueue = pair.clientToHost,
            codec = codec,
        )
        val hostStream = LoopbackIrohRelayStream(
            readQueue = pair.clientToHost,
            writeQueue = pair.hostToClient,
            codec = codec,
        )
        if (continuation.isActive) continuation.resumeWith(Result.success(clientStream))
        accept.trySend(hostStream)
    }

    private companion object {
        fun randomLoopbackNodeId(): String {
            val alphabet = "abcdefghijklmnopqrstuvwxyz234567"
            return buildString(52) {
                repeat(52) { append(alphabet[Random.Default.nextInt(alphabet.length)]) }
            }
        }
    }
}
