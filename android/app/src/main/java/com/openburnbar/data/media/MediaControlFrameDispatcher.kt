package com.openburnbar.data.media

import com.openburnbar.data.computeruse.AgentCapabilityGrantState
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantReceipt
import com.openburnbar.irohrelay.HermesRealtimeRelayCallAck
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardResponse
import com.openburnbar.irohrelay.HermesRealtimeRelayControlDenied
import com.openburnbar.irohrelay.HermesRealtimeRelayFocusContext
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockResult
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState
import java.util.Base64

internal data class MediaControlFrameDispatcherHandlers(
    val receiverProvider: () -> AndroidFileTransferService?,
    val mirrorFrameHandler: () -> (suspend (MediaFrame) -> Unit)?,
    val mirrorFrameV2Handler: () -> (suspend (MediaFrameV2) -> Unit)?,
    val focusContextHandler: () -> (suspend (HermesRealtimeRelayFocusContext) -> Unit)?,
    /**
     * F7 — the negotiated per-mirror MediaFrameAead session key, or null when
     * the mirror was established on the legacy plaintext lane. Sealed (OBMFA1)
     * frames are dropped (fail closed) when this is null or the open fails.
     */
    val mediaFrameSealKeyProvider: () -> ByteArray? = { null },
)

internal data class MediaControlFrameDispatcherCallbacks(
    val onMirrorAck: (HermesRealtimeRelayMirrorAck) -> Unit,
    val onCallAck: (HermesRealtimeRelayCallAck) -> Unit,
    val onAgentGrantReceipt: (HermesRealtimeRelayAgentGrantReceipt) -> Unit,
    val onControlDenied: (HermesRealtimeRelayControlDenied) -> Unit,
    val onClipboardResponse: (HermesRealtimeRelayClipboardResponse) -> Unit,
    val onRemoteUnlockState: (HermesRealtimeRelayRemoteUnlockState) -> Unit,
    val onRemoteUnlockResult: (HermesRealtimeRelayRemoteUnlockResult) -> Unit,
    val onPeerHeartbeat: (receivedAtMillis: Long, capabilities: Set<String>) -> Unit,
    val onRoundTripMillis: (Int) -> Unit,
    val pendingHeartbeatSentAtMillis: () -> Long?,
    val clearPendingHeartbeat: () -> Unit,
)

internal class MediaControlFrameDispatcher(
    private val handlers: MediaControlFrameDispatcherHandlers,
    private val callbacks: MediaControlFrameDispatcherCallbacks,
) {
    private val mediaPacketCodec = MediaPacketCodec(maxPayloadBytes = MediaFrameV2Codec.DEFAULT_MAX_PAYLOAD_BYTES)
    private val mediaFrameV2Codec = MediaFrameV2Codec()
    private val frameChunkAssembler = MediaFrameChunkAssembler()

    suspend fun dispatch(frame: HermesRealtimeRelayFrame, ackSender: AndroidFileTransferService.AdvertiseSender) {
        when (frame.type) {
            HermesRealtimeRelayFrameType.MEDIA_BLOB_ADVERTISE ->
                handlers.receiverProvider()?.handleAdvertise(frame = frame, ackSender = ackSender)
            HermesRealtimeRelayFrameType.MEDIA_BLOB_ACK -> Unit
            HermesRealtimeRelayFrameType.MEDIA_MIRROR_ACK -> {
                frame.media?.mirrorAck?.let(callbacks.onMirrorAck)
            }
            HermesRealtimeRelayFrameType.MEDIA_CALL_ACK -> {
                frame.media?.callAck?.let(callbacks.onCallAck)
            }
            HermesRealtimeRelayFrameType.MEDIA_STREAM_FRAME -> handleStreamFrame(frame)
            HermesRealtimeRelayFrameType.MEDIA_PRESENCE_HEARTBEAT -> {
                val receivedAtMillis = System.currentTimeMillis()
                callbacks.pendingHeartbeatSentAtMillis()?.let { sentAtMillis ->
                    callbacks.onRoundTripMillis(
                        (receivedAtMillis - sentAtMillis)
                            .coerceAtLeast(0L)
                            .coerceAtMost(Int.MAX_VALUE.toLong())
                            .toInt(),
                    )
                    callbacks.clearPendingHeartbeat()
                }
                callbacks.onPeerHeartbeat(receivedAtMillis, frame.media?.presence?.capabilities.orEmpty().toSet())
            }
            HermesRealtimeRelayFrameType.CONTROL_AGENT_GRANT_RECEIPT -> {
                frame.control?.agentGrantReceipt?.let { receipt ->
                    callbacks.onAgentGrantReceipt(receipt)
                    AgentCapabilityGrantState.apply(receipt)
                }
            }
            HermesRealtimeRelayFrameType.CONTROL_DENIED -> {
                frame.control?.denied?.let(callbacks.onControlDenied)
            }
            HermesRealtimeRelayFrameType.CONTROL_SYSTEM_PERMISSION_STATUS -> {
                frame.control?.systemPermissionStatus?.let { status ->
                    com.openburnbar.data.computeruse.SystemPermissionInboxStoreHolder
                        .ingest(status, threadId = frame.control?.sessionId)
                }
            }
            HermesRealtimeRelayFrameType.CONTROL_CLIPBOARD_RESPONSE -> {
                frame.control?.clipboardResponse?.let(callbacks.onClipboardResponse)
            }
            HermesRealtimeRelayFrameType.REMOTE_UNLOCK_STATE -> {
                frame.control?.remoteUnlockState?.let(callbacks.onRemoteUnlockState)
            }
            HermesRealtimeRelayFrameType.REMOTE_UNLOCK_RESULT,
            HermesRealtimeRelayFrameType.REMOTE_UNLOCK_DENIED,
            -> {
                frame.control?.remoteUnlockResult?.let(callbacks.onRemoteUnlockResult)
            }
            HermesRealtimeRelayFrameType.MEDIA_CLASSIFY -> Unit
            else -> Unit
        }
    }

    private suspend fun handleStreamFrame(frame: HermesRealtimeRelayFrame) {
        val media = frame.media ?: return
        media.focusContext?.let { focus ->
            handlers.focusContextHandler()?.invoke(focus)
        }
        val encoded = media.encodedFrameBase64
        val chunkBytes = encoded?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
        val assembled =
            if (media.streamClass == MediaStreamClass.SCREEN_VIDEO.raw && chunkBytes != null) {
                frameChunkAssembler.accept(media.frameChunk, chunkBytes)
            } else {
                null
            }
        if (assembled == null) return
        // F7: a sealed (OBMFA1) frame must open under the negotiated session
        // key with the cleartext position rebuilt into the AAD — fail closed
        // (DROP) on a missing key/position or any tag mismatch. Plaintext
        // legacy frames flow unchanged.
        val data =
            if (MediaFrameAead.isSealedEnvelope(assembled)) {
                openSealedFrame(assembled, media) ?: return
            } else {
                assembled
            }
        runCatching {
            if (MediaFrameV2Codec.isEncodedEnvelope(data)) {
                handlers.mirrorFrameV2Handler()?.invoke(mediaFrameV2Codec.decode(data).frame)
            } else {
                handlers.mirrorFrameHandler()?.invoke(mediaPacketCodec.decode(data).frame)
            }
        }
    }

    private fun openSealedFrame(envelope: ByteArray, media: com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload): ByteArray? {
        val key = handlers.mediaFrameSealKeyProvider() ?: return null
        val position = media.sealedFramePosition ?: return null
        return runCatching {
            MediaFrameAead.open(
                envelope = envelope,
                key = key,
                streamClass = MediaStreamClass.SCREEN_VIDEO.raw,
                kind = position.kind.toUByte(),
                gopID = position.gopId.toUInt(),
                frameIndex = position.frameIndex.toUInt(),
            )
        }.getOrNull()
    }
}
