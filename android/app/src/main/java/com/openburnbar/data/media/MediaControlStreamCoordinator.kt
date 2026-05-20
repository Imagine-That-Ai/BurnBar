package com.openburnbar.data.media

import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayCallInvite
import com.openburnbar.irohrelay.HermesRealtimeRelayCallAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayPresenceHeartbeat
import com.openburnbar.irohrelay.IrohRelayStream
import java.time.Instant
import java.util.UUID
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
    private var receiver: AndroidFileTransferService? = null,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val initialBackoffMillis: Long = 1_000L,
    private val maxBackoffMillis: Long = 30_000L,
    private val analytics: MediaAnalyticsLogger? = null,
    private val peerDeviceIdProvider: () -> String = { android.os.Build.MODEL.orEmpty().ifBlank { "android" } },
    private val displayNameProvider: () -> String = { android.os.Build.MODEL.orEmpty().ifBlank { "Android" } },
    private val presenceHeartbeatIntervalMillis: Long = 60_000L,
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

    data class ActivePair(
        val uid: String,
        val connectionID: String,
    )

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

    private val _lastMirrorAck = MutableStateFlow<HermesRealtimeRelayMirrorAck?>(null)
    val lastMirrorAck: StateFlow<HermesRealtimeRelayMirrorAck?> = _lastMirrorAck.asStateFlow()

    private val _lastCallAck = MutableStateFlow<HermesRealtimeRelayCallAck?>(null)
    val lastCallAck: StateFlow<HermesRealtimeRelayCallAck?> = _lastCallAck.asStateFlow()

    private val _activePair = MutableStateFlow<ActivePair?>(null)
    val activePair: StateFlow<ActivePair?> = _activePair.asStateFlow()

    fun attachReceiver(nextReceiver: AndroidFileTransferService) {
        receiver = nextReceiver
    }

    suspend fun start(uid: String, connectionID: String) {
        mutex.withLock {
            if (supervisorJob?.isActive == true) return
            activeUID = uid
            activeConnectionID = connectionID
            _activePair.value = ActivePair(uid = uid, connectionID = connectionID)
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
            _activePair.value = null
        }
        job?.cancel()
    }

    suspend fun send(frame: HermesRealtimeRelayFrame) {
        val stream = awaitLiveStream()
        stream.send(frame)
    }

    suspend fun requestMirror(requesterDisplayName: String): String {
        val uid = activeUID ?: throw IllegalStateException("Mercury control stream is not paired yet.")
        val connectionID = activeConnectionID ?: throw IllegalStateException("Mercury control stream is not paired yet.")
        val requestID = UUID.randomUUID().toString()
        val request = HermesRealtimeRelayMirrorRequest(
            requestId = requestID,
            requestedAt = Instant.now().toString(),
            requesterDisplayName = requesterDisplayName,
            streamClass = "media.screen.video",
        )
        send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_MIRROR_REQUEST,
                uid = uid,
                connectionId = connectionID,
                requestId = requestID,
                media = HermesRealtimeRelayMediaPayload(mirrorRequest = request),
            )
        )
        return requestID
    }

    suspend fun requestCall(requesterDisplayName: String): String {
        val uid = activeUID ?: throw IllegalStateException("Mercury control stream is not paired yet.")
        val connectionID = activeConnectionID ?: throw IllegalStateException("Mercury control stream is not paired yet.")
        val requestID = UUID.randomUUID().toString()
        val invite = HermesRealtimeRelayCallInvite(
            requestId = requestID,
            requestedAt = Instant.now().toString(),
            requesterDisplayName = requesterDisplayName,
            callKind = "video",
        )
        send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_CALL_INVITE,
                uid = uid,
                connectionId = connectionID,
                requestId = requestID,
                media = HermesRealtimeRelayMediaPayload(callInvite = invite),
            )
        )
        return requestID
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

                val heartbeatJob = scope.launch {
                    presenceHeartbeatLoop(stream = stream, uid = uid, connectionID = connectionID)
                }
                try {
                    readLoop(stream = stream, uid = uid, connectionID = connectionID)
                } finally {
                    heartbeatJob.cancel()
                }

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
        activeUID = null
        activeConnectionID = null
        _activePair.value = null
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
                        receiver?.handleAdvertise(frame = frame, ackSender = ackSender)
                    HermesRealtimeRelayFrameType.MEDIA_BLOB_ACK -> {
                        // Phase 2 surfaces this to per-row UI state; Phase 1 logs only.
                    }
                    HermesRealtimeRelayFrameType.MEDIA_MIRROR_ACK -> {
                        frame.media?.mirrorAck?.let { _lastMirrorAck.value = it }
                    }
                    HermesRealtimeRelayFrameType.MEDIA_CALL_ACK -> {
                        frame.media?.callAck?.let { _lastCallAck.value = it }
                    }
                    HermesRealtimeRelayFrameType.MEDIA_STREAM_FRAME -> {
                        // Android screen-share viewer decode is wired separately; keep the
                        // control stream alive even before the viewer is opened.
                    }
                    HermesRealtimeRelayFrameType.MEDIA_PRESENCE_HEARTBEAT -> {
                        // Presence updates are consumed by the Square connection store.
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

    private suspend fun presenceHeartbeatLoop(
        stream: IrohRelayStream,
        uid: String,
        connectionID: String,
    ) {
        while (scope.isActive && supervisorJob?.isActive == true) {
            stream.send(makePresenceHeartbeat(uid = uid, connectionID = connectionID))
            delay(presenceHeartbeatIntervalMillis)
        }
    }

    private fun makePresenceHeartbeat(uid: String, connectionID: String): HermesRealtimeRelayFrame =
        HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.MEDIA_PRESENCE_HEARTBEAT,
            uid = uid,
            connectionId = connectionID,
            media = HermesRealtimeRelayMediaPayload(
                presence = HermesRealtimeRelayPresenceHeartbeat(
                    peerDeviceId = peerDeviceIdProvider().ifBlank { "android" },
                    displayName = displayNameProvider().ifBlank { "Android" },
                    capabilities = listOf(
                        "media.control",
                        "media.mirror.request",
                        "media.call.invite",
                        "media.blob.transfer",
                    ),
                    sentAt = Instant.now().toString(),
                )
            ),
        )

    private fun nextBackoff(attempt: Int): Long {
        val exp = min(
            maxBackoffMillis.toDouble(),
            initialBackoffMillis.toDouble() * (2.0.pow(attempt.toDouble())),
        )
        val jitter = Random.nextDouble(initialBackoffMillis.toDouble(), exp + 1)
        return min(maxBackoffMillis, jitter.toLong())
    }
}
