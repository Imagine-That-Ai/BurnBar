package com.openburnbar.data.media

import android.util.Log
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantReceipt
import com.openburnbar.irohrelay.HermesRealtimeRelayCallAck
import com.openburnbar.irohrelay.HermesRealtimeRelayCallInvite
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardResponse
import com.openburnbar.irohrelay.HermesRealtimeRelayControlDenied
import com.openburnbar.irohrelay.HermesRealtimeRelayFocusContext
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayLongTermReferenceAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorStop
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockResult
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockSession
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState
import com.openburnbar.irohrelay.IrohRelayStream
import java.lang.IllegalStateException
import java.time.Instant
import java.util.UUID
import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random
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
import kotlinx.coroutines.withTimeoutOrNull

private const val MILLIS = 25
private const val VAL_4096 = 4096

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
    private val controlAuthorityPeerNodeIdProvider: () -> String? = { null },
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
    private var pendingHeartbeatSentAtMillis: Long? = null

    private val frameDispatcher by lazy {
        MediaControlFrameDispatcher(
            handlers =
            MediaControlFrameDispatcherHandlers(
                receiverProvider = { receiver },
                mirrorFrameHandler = { mirrorFrameHandler },
                mirrorFrameV2Handler = { mirrorFrameV2Handler },
                focusContextHandler = { focusContextHandler },
            ),
            callbacks =
            MediaControlFrameDispatcherCallbacks(
                onMirrorAck = { _lastMirrorAck.value = it },
                onCallAck = { _lastCallAck.value = it },
                onAgentGrantReceipt = { _lastAgentGrantReceipt.value = it },
                onControlDenied = { _lastControlDenied.value = it },
                onClipboardResponse = { _lastClipboardResponse.value = it },
                onRemoteUnlockState = { _lastRemoteUnlockState.value = it },
                onRemoteUnlockResult = { _lastRemoteUnlockResult.value = it },
                onPeerHeartbeat = { receivedAt, capabilities ->
                    _lastPeerHeartbeatAtMillis.value = receivedAt
                    _lastPeerCapabilities.value = capabilities
                },
                onRoundTripMillis = { _lastRoundTripMillis.value = it },
                pendingHeartbeatSentAtMillis = { pendingHeartbeatSentAtMillis },
                clearPendingHeartbeat = { pendingHeartbeatSentAtMillis = null },
            ),
        )
    }

    @Volatile
    var mirrorFrameHandler: (suspend (MediaFrame) -> Unit)? = null

    @Volatile
    var mirrorFrameV2Handler: (suspend (MediaFrameV2) -> Unit)? = null

    /**
     * Mercury Smart Zoom — focus context updates arrive on
     * `.mediaStreamFrame` envelopes with only `media.focusContext`
     * populated. Mirror surfaces install this handler to feed the
     * client-side Smart Zoom reducer.
     */
    @Volatile
    var focusContextHandler: (suspend (HermesRealtimeRelayFocusContext) -> Unit)? = null

    private val _phase = MutableStateFlow<Phase>(Phase.Idle)
    val phase: StateFlow<Phase> = _phase.asStateFlow()

    private val _consecutiveDialFailures = MutableStateFlow(0)
    val consecutiveDialFailures: StateFlow<Int> = _consecutiveDialFailures.asStateFlow()

    private val _lastMirrorAck = MutableStateFlow<HermesRealtimeRelayMirrorAck?>(null)
    val lastMirrorAck: StateFlow<HermesRealtimeRelayMirrorAck?> = _lastMirrorAck.asStateFlow()

    private val _lastCallAck = MutableStateFlow<HermesRealtimeRelayCallAck?>(null)
    val lastCallAck: StateFlow<HermesRealtimeRelayCallAck?> = _lastCallAck.asStateFlow()

    private val _lastAgentGrantReceipt = MutableStateFlow<HermesRealtimeRelayAgentGrantReceipt?>(null)
    val lastAgentGrantReceipt: StateFlow<HermesRealtimeRelayAgentGrantReceipt?> =
        _lastAgentGrantReceipt.asStateFlow()

    private val _lastControlDenied = MutableStateFlow<HermesRealtimeRelayControlDenied?>(null)
    val lastControlDenied: StateFlow<HermesRealtimeRelayControlDenied?> =
        _lastControlDenied.asStateFlow()

    private val _lastClipboardResponse = MutableStateFlow<HermesRealtimeRelayClipboardResponse?>(null)
    val lastClipboardResponse: StateFlow<HermesRealtimeRelayClipboardResponse?> =
        _lastClipboardResponse.asStateFlow()

    private val _lastRemoteUnlockState = MutableStateFlow<HermesRealtimeRelayRemoteUnlockState?>(null)
    val lastRemoteUnlockState: StateFlow<HermesRealtimeRelayRemoteUnlockState?> =
        _lastRemoteUnlockState.asStateFlow()

    private val _lastRemoteUnlockResult = MutableStateFlow<HermesRealtimeRelayRemoteUnlockResult?>(null)
    val lastRemoteUnlockResult: StateFlow<HermesRealtimeRelayRemoteUnlockResult?> =
        _lastRemoteUnlockResult.asStateFlow()

    private val _lastPeerHeartbeatAtMillis = MutableStateFlow(0L)
    val lastPeerHeartbeatAtMillis: StateFlow<Long> = _lastPeerHeartbeatAtMillis.asStateFlow()
    private val _lastRoundTripMillis = MutableStateFlow<Int?>(null)
    val lastRoundTripMillis: StateFlow<Int?> = _lastRoundTripMillis.asStateFlow()
    private val _lastPeerCapabilities = MutableStateFlow<Set<String>>(emptySet())
    val lastPeerCapabilities: StateFlow<Set<String>> = _lastPeerCapabilities.asStateFlow()

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
            pendingHeartbeatSentAtMillis = null
            _lastRoundTripMillis.value = null
            logInfo("Mercury control supervisor starting connectionID=$connectionID")
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
            pendingHeartbeatSentAtMillis = null
            _lastRoundTripMillis.value = null
            _activePair.value = null
        }
        job?.cancel()
    }

    suspend fun send(frame: HermesRealtimeRelayFrame) {
        val stream = awaitLiveStream()
        stream.send(frame)
    }

    suspend fun ensureResponsive(freshnessIntervalMillis: Long = 2_000L, probeTimeoutMillis: Long = 1_000L): Boolean {
        val now = System.currentTimeMillis()
        val lastHeartbeat = _lastPeerHeartbeatAtMillis.value
        if (_phase.value == Phase.Live && lastHeartbeat > 0L && now - lastHeartbeat <= freshnessIntervalMillis) {
            return true
        }

        val uid = activeUID ?: error("Mercury control stream is not paired yet.")
        val connectionID = activeConnectionID ?: error("Mercury control stream is not paired yet.")
        val stream = mutex.withLock { currentStream }
        if (stream == null) {
            _phase.value = Phase.Reconnecting(nextAttemptInMillis = initialBackoffMillis)
            return false
        }

        val beforeProbe = _lastPeerHeartbeatAtMillis.value
        return try {
            val sentAtMillis = System.currentTimeMillis()
            stream.send(
                MediaControlPresence.makeHeartbeat(
                    uid = uid,
                    connectionID = connectionID,
                    peerDeviceIdProvider = peerDeviceIdProvider,
                    displayNameProvider = displayNameProvider,
                ),
            )
            pendingHeartbeatSentAtMillis = sentAtMillis

            val replied =
                withTimeoutOrNull(probeTimeoutMillis.coerceAtLeast(1L)) {
                    while (_lastPeerHeartbeatAtMillis.value <= beforeProbe) {
                        delay(MILLIS)
                    }
                    true
                } == true

            if (replied) {
                true
            } else {
                mutex.withLock {
                    if (currentStream === stream) {
                        currentStream = null
                    }
                }
                stream.runCatching { close() }
                _phase.value = Phase.Reconnecting(nextAttemptInMillis = initialBackoffMillis)
                false
            }
        } catch (t: CancellationException) {
            throw t
        } catch (t: IllegalStateException) {
            mutex.withLock {
                if (currentStream === stream) {
                    currentStream = null
                }
            }
            stream.runCatching { close() }
            _phase.value = Phase.Reconnecting(nextAttemptInMillis = initialBackoffMillis)
            logWarning("Mercury control responsiveness probe failed connectionID=$connectionID error=${t.message}", t)
            false
        }
    }

    suspend fun requestMirror(requesterDisplayName: String, remoteUnlockSession: HermesRealtimeRelayRemoteUnlockSession? = null): String {
        val uid = activeUID ?: error("Mercury control stream is not paired yet.")
        val connectionID = activeConnectionID ?: error("Mercury control stream is not paired yet.")
        val requestID = UUID.randomUUID().toString()
        val viewerID = UUID.randomUUID().toString()
        val request =
            HermesRealtimeRelayMirrorRequest(
                requestId = requestID,
                requestedAt = Instant.now().toString(),
                requesterDisplayName = requesterDisplayName,
                streamClass = "media.screen.video",
                streamingCapabilities =
                AndroidMediaCodecCapabilityProbe.snapshot(
                    mediaFrameVersions = MercuryMediaFrameVersionSupport.V1_AND_V2,
                ).toWire(),
                viewerId = viewerID,
                viewerDeviceId = peerDeviceIdProvider().ifBlank { "android" },
                controlAuthorityPeerNodeId = controlAuthorityPeerNodeIdProvider(),
                remoteUnlockSession = remoteUnlockSession,
            )
        send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_MIRROR_REQUEST,
                uid = uid,
                connectionId = connectionID,
                requestId = requestID,
                media = HermesRealtimeRelayMediaPayload(mirrorRequest = request),
            ),
        )
        logInfo("Mercury mirror request sent requestID=$requestID connectionID=$connectionID")
        return requestID
    }

    suspend fun stopMirror(requestID: String, sessionID: String? = null, reason: String? = null) {
        val uid = activeUID ?: error("Mercury control stream is not paired yet.")
        val connectionID = activeConnectionID ?: error("Mercury control stream is not paired yet.")
        send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_MIRROR_STOP,
                uid = uid,
                connectionId = connectionID,
                requestId = requestID,
                media =
                HermesRealtimeRelayMediaPayload(
                    mirrorStop =
                    HermesRealtimeRelayMirrorStop(
                        requestId = requestID,
                        sessionId = sessionID,
                        stoppedAt = mediaControlSwiftReferenceDateSecondsNow(),
                        reason = reason,
                    ),
                ),
            ),
        )
        logInfo("Mercury mirror stop sent requestID=$requestID connectionID=$connectionID reason=${reason.orEmpty()}")
    }

    suspend fun sendLongTermReferenceAcknowledgement(token: MediaFrameV2LongTermReferenceToken, requestID: String? = null) {
        val uid = activeUID ?: error("Mercury control stream is not paired yet.")
        val connectionID = activeConnectionID ?: error("Mercury control stream is not paired yet.")
        send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_LONG_TERM_REFERENCE_ACK,
                uid = uid,
                connectionId = connectionID,
                requestId = requestID,
                media =
                HermesRealtimeRelayMediaPayload(
                    longTermReferenceAck =
                    HermesRealtimeRelayLongTermReferenceAck(
                        requestId = requestID,
                        tokenValue = token.value,
                        decodedAt = Instant.now().toString(),
                    ),
                ),
            ),
        )
    }

    suspend fun requestCall(requesterDisplayName: String): String {
        val uid = activeUID ?: error("Mercury control stream is not paired yet.")
        val connectionID = activeConnectionID ?: error("Mercury control stream is not paired yet.")
        val requestID = UUID.randomUUID().toString()
        val invite =
            HermesRealtimeRelayCallInvite(
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
            ),
        )
        return requestID
    }

    private suspend fun awaitLiveStream(): IrohRelayStream {
        val immediate: IrohRelayStream? =
            mutex.withLock {
                val live = currentStream
                if (live != null && _phase.value == Phase.Live) live else null
            }
        if (immediate != null) return immediate
        val deferred = CompletableDeferred<IrohRelayStream>()
        mutex.withLock { pendingLive.add(deferred) }
        return deferred.await()
    }

    private suspend fun resolvePending(stream: IrohRelayStream) {
        val waiting =
            mutex.withLock {
                val snapshot = pendingLive.toList()
                pendingLive.clear()
                snapshot
            }
        waiting.forEach { it.complete(stream) }
    }

    private suspend fun runSupervisor(uid: String, connectionID: String) {
        var attempt = 0
        var active = scope.isActive && supervisorJob?.isActive == true
        while (active) {
            val keepRunning =
                try {
                    dialAndReadLoop(uid = uid, connectionID = connectionID, attempt = attempt)
                } catch (_: CancellationException) {
                    false
                } catch (t: IllegalStateException) {
                    _consecutiveDialFailures.value = _consecutiveDialFailures.value + 1
                    _phase.value = Phase.Failed(t.message ?: t.javaClass.simpleName)
                    logWarning("Mercury control dial failed connectionID=$connectionID error=${t.message}", t)
                    analytics?.controlStreamLost(t.message ?: t.javaClass.simpleName)
                    true
                }
            active = keepRunning && scope.isActive && supervisorJob?.isActive == true
            if (active) {
                val backoff = nextBackoff(attempt)
                attempt += 1
                _phase.value = Phase.Reconnecting(nextAttemptInMillis = backoff)
                logInfo("Mercury control reconnect scheduled connectionID=$connectionID backoffMs=$backoff")
                active = scope.isActive && supervisorJob?.isActive == true && delayUnlessCancelled(backoff)
            }
        }
        logInfo("Mercury control supervisor stopped connectionID=$connectionID")
        _phase.value = Phase.Stopped
        activeUID = null
        activeConnectionID = null
        _activePair.value = null
    }

    private suspend fun dialAndReadLoop(uid: String, connectionID: String, attempt: Int): Boolean {
        _phase.value = Phase.Dialing
        logInfo("Mercury control dial attempt=${attempt + 1} connectionID=$connectionID")
        val stream = dialer.dial(uid, connectionID)
        val classifyFrame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_CLASSIFY,
                uid = uid,
                connectionId = connectionID,
                media = HermesRealtimeRelayMediaPayload(streamClass = MediaStreamClass.CONTROL.raw),
            )
        stream.send(classifyFrame)
        mutex.withLock { currentStream = stream }
        _consecutiveDialFailures.value = 0
        _phase.value = Phase.Live
        logInfo("Mercury control live connectionID=$connectionID")
        analytics?.controlStreamConnected()
        resolvePending(stream)

        val heartbeatJob =
            scope.launch {
                MediaControlPresence.heartbeatLoop(
                    MediaControlHeartbeatLoopParams(
                        stream = stream,
                        uid = uid,
                        connectionID = connectionID,
                        scopeActive = { scope.isActive },
                        supervisorActive = { supervisorJob?.isActive == true },
                        peerDeviceIdProvider = peerDeviceIdProvider,
                        displayNameProvider = displayNameProvider,
                        intervalMillis = presenceHeartbeatIntervalMillis,
                        onHeartbeatSent = { sentAtMillis -> pendingHeartbeatSentAtMillis = sentAtMillis },
                    ),
                )
            }
        try {
            readLoop(stream = stream, uid = uid, connectionID = connectionID)
        } finally {
            heartbeatJob.cancel()
        }

        mutex.withLock { currentStream = null }
        logInfo("Mercury control read loop ended connectionID=$connectionID")
        return supervisorJob?.isActive == true
    }

    private suspend fun delayUnlessCancelled(backoff: Long): Boolean {
        return try {
            delay(backoff)
            true
        } catch (_: CancellationException) {
            false
        }
    }

    private suspend fun readLoop(stream: IrohRelayStream, uid: String, connectionID: String) {
        val ackSender = AndroidFileTransferService.AdvertiseSender { outbound -> stream.send(outbound) }
        try {
            while (true) {
                val frame = stream.receive() ?: return
                val isMatchingFrame = frame.uid == uid && frame.connectionId == connectionID
                if (isMatchingFrame) {
                    frameDispatcher.dispatch(frame, ackSender)
                }
            }
        } catch (t: IllegalStateException) {
            _phase.value = Phase.Reconnecting(nextAttemptInMillis = initialBackoffMillis)
            logWarning("Mercury control read failed connectionID=$connectionID error=${t.message}", t)
        }
    }

    private fun nextBackoff(attempt: Int): Long {
        val exp =
            min(
                maxBackoffMillis.toDouble(),
                initialBackoffMillis.toDouble() * 2.0.pow(attempt.toDouble()),
            )
        val jitter = Random.nextDouble(initialBackoffMillis.toDouble(), exp + 1)
        return min(maxBackoffMillis, jitter.toLong())
    }

    private fun logInfo(message: String) {
        runCatching { Log.i(TAG, message) }
    }

    private fun logWarning(message: String, error: Throwable) {
        runCatching { Log.w(TAG, message, error) }
    }

    private companion object {
        private const val TAG = "BurnBar"
    }
}
