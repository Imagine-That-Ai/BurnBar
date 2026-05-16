package com.openburnbar.data.media

import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import com.openburnbar.irohrelay.IrohRelayStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

/**
 * Android-side owner of the persistent media control stream. 1:1 port
 * of `MediaControlStreamCoordinator.swift` (iOS).
 *
 * Risk-1 fix for the Mac → Android push gap: rather than waiting for an
 * active chat response stream to piggyback on, the coordinator dials
 * Mac once when the Hermes session is up and keeps a single bi-stream
 * open dedicated to `media.blob.advertise` / `media.blob.ack` frames in
 * both directions. The stream survives chat-request churn and gives the
 * Mac a reliable "always available" outbound channel.
 *
 * Lifecycle:
 *   1. `start(uid, connectionId)` — dial Mac, send `media.classify` as
 *      the first frame, spawn the read loop, schedule reconnect on
 *      failure.
 *   2. `send(frame)` — outbound advertise/ack from the Android side.
 *   3. `stop()` — close the stream and cancel any pending reconnect.
 */
class MediaControlStreamCoordinator(
    private val dialer: StreamDialer,
    private val receiver: AndroidFileTransferService,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val initialBackoffMillis: Long = 1_000L,
    private val maxBackoffMillis: Long = 30_000L,
    private val analytics: MediaAnalyticsLogger? = null,
) {
    fun interface StreamDialer {
        suspend fun dial(uid: String, connectionID: String): IrohRelayStream
    }

    sealed class Phase {
        object Idle : Phase()
        object Dialing : Phase()
        object Live : Phase()
        data class Reconnecting(val nextAttemptInMillis: Long) : Phase()
        object Stopped : Phase()
        data class Failed(val reason: String) : Phase()
    }

    private val mutex = Mutex()
    private var supervisorJob: Job? = null
    private var currentStream: IrohRelayStream? = null
    private var activeUID: String? = null
    private var activeConnectionID: String? = null
    private var pendingLive: MutableList<CompletableDeferred<IrohRelayStream>> = mutableListOf()

    private val _phase = MutableStateFlow<Phase>(Phase.Idle)
    val phase: StateFlow<Phase> = _phase.asStateFlow()

    private val _consecutiveDialFailures = MutableStateFlow(0)
    val consecutiveDialFailures: StateFlow<Int> = _consecutiveDialFailures.asStateFlow()

    suspend fun start(uid: String, connectionID: String) {
        mutex.withLock {
            if (supervisorJob?.isActive == true) return
            activeUID = uid
            activeConnectionID = connectionID
            _phase.value = Phase.Dialing
            supervisorJob = scope.launch { runSupervisor(uid = uid, connectionID = connectionID) }
        }
    }

    suspend fun stop() {
        val job: Job?
        mutex.withLock {
            job = supervisorJob
            supervisorJob = null
            val stream = currentStream
            currentStream = null
            stream?.runCatching { close() }
            val pending = pendingLive.toList()
            pendingLive.clear()
            pending.forEach { it.completeExceptionally(CancellationException("control stream stopped")) }
            _phase.value = Phase.Stopped
            activeUID = null
            activeConnectionID = null
        }
        job?.cancel()
    }

    suspend fun send(frame: HermesRealtimeRelayFrame) {
        val stream = awaitLiveStream()
        stream.send(frame)
    }

    private suspend fun awaitLiveStream(): IrohRelayStream {
        val immediate: IrohRelayStream? = mutex.withLock {
            val live = currentStream
            if (live != null && _phase.value == Phase.Live) live else null
        }
        if (immediate != null) return immediate
        val deferred = CompletableDeferred<IrohRelayStream>()
        mutex.withLock { pendingLive.add(deferred) }
        return deferred.await()
    }

    private suspend fun resolvePending(stream: IrohRelayStream) {
        val waiting = mutex.withLock {
            val snapshot = pendingLive.toList()
            pendingLive.clear()
            snapshot
        }
        waiting.forEach { it.complete(stream) }
    }

    private suspend fun runSupervisor(uid: String, connectionID: String) {
        var attempt = 0
        while (scope.isActive && supervisorJob?.isActive == true) {
            try {
                _phase.value = Phase.Dialing
                val stream = dialer.dial(uid, connectionID)
                val classifyFrame = HermesRealtimeRelayFrame(
                    type = HermesRealtimeRelayFrameType.MEDIA_CLASSIFY,
                    uid = uid,
                    connectionId = connectionID,
                    media = HermesRealtimeRelayMediaPayload(streamClass = MediaStreamClass.CONTROL.raw),
                )
                stream.send(classifyFrame)
                mutex.withLock { currentStream = stream }
                _consecutiveDialFailures.value = 0
                attempt = 0
                _phase.value = Phase.Live
                analytics?.controlStreamConnected()
                resolvePending(stream)

                readLoop(stream = stream, uid = uid, connectionID = connectionID)

                mutex.withLock { currentStream = null }
                if (supervisorJob?.isActive != true) break
                attempt = (attempt - 1).coerceAtLeast(0)
            } catch (_: CancellationException) {
                break
            } catch (t: Throwable) {
                _consecutiveDialFailures.value = _consecutiveDialFailures.value + 1
                _phase.value = Phase.Failed(t.message ?: t.javaClass.simpleName)
                analytics?.controlStreamLost(t.message ?: t.javaClass.simpleName)
            }

            val backoff = nextBackoff(attempt)
            attempt += 1
            _phase.value = Phase.Reconnecting(nextAttemptInMillis = backoff)
            try { delay(backoff) } catch (_: CancellationException) { break }
        }
        _phase.value = Phase.Stopped
    }

    private suspend fun readLoop(
        stream: IrohRelayStream,
        uid: String,
        connectionID: String,
    ) {
        val ackSender = AndroidFileTransferService.AdvertiseSender { outbound -> stream.send(outbound) }
        try {
            while (true) {
                val frame = stream.receive() ?: return
                if (frame.uid != uid || frame.connectionId != connectionID) continue
                when (frame.type) {
                    HermesRealtimeRelayFrameType.MEDIA_BLOB_ADVERTISE ->
                        receiver.handleAdvertise(frame = frame, ackSender = ackSender)
                    HermesRealtimeRelayFrameType.MEDIA_BLOB_ACK -> {
                        // Phase 2 surfaces this to per-row UI state; Phase 1 logs only.
                    }
                    HermesRealtimeRelayFrameType.MEDIA_CLASSIFY -> {
                        // Re-classification mid-stream — protocol noise.
                    }
                    else -> {
                        // Ignore non-media frames on the control bi-stream.
                    }
                }
            }
        } catch (t: Throwable) {
            _phase.value = Phase.Reconnecting(nextAttemptInMillis = initialBackoffMillis)
        }
    }

    private fun nextBackoff(attempt: Int): Long {
        val exp = min(
            maxBackoffMillis.toDouble(),
            initialBackoffMillis.toDouble() * (2.0.pow(attempt.toDouble())),
        )
        val jitter = Random.nextDouble(initialBackoffMillis.toDouble(), exp + 1)
        return min(maxBackoffMillis, jitter.toLong())
    }
}
