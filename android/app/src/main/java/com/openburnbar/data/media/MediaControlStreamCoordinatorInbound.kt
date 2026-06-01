@file:Suppress("TooGenericExceptionCaught")
// Relay read loop must survive arbitrary transport failures and schedule reconnect.

package com.openburnbar.data.media

import com.openburnbar.data.computeruse.AgentCapabilityGrantState
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayPresenceHeartbeat
import com.openburnbar.irohrelay.IrohRelayStream
import java.time.Instant
import java.util.Base64
import kotlinx.coroutines.isActive

/** Inbound Mercury control bi-stream read loop and frame dispatch (extracted for detekt size limits). */
internal suspend fun MediaControlStreamCoordinator.runMercuryInboundReadLoop(
    stream: IrohRelayStream,
    uid: String,
    connectionID: String,
) {
    val ackSender = AndroidFileTransferService.AdvertiseSender { outbound -> stream.send(outbound) }
    try {
        while (true) {
            val frame = stream.receive() ?: return
            if (frame.uid != uid || frame.connectionId != connectionID) continue
            dispatchMercuryInboundFrame(frame, ackSender)
        }
    } catch (t: Throwable) {
        inboundPhase.value = MediaControlStreamCoordinator.Phase.Reconnecting(
            nextAttemptInMillis = inboundInitialBackoffMillis,
        )
        inboundLogWarning(
            "Mercury control read failed connectionID=$connectionID error=${t.message}",
            t,
        )
    }
}

internal suspend fun MediaControlStreamCoordinator.dispatchMercuryInboundFrame(
    frame: HermesRealtimeRelayFrame,
    ackSender: AndroidFileTransferService.AdvertiseSender,
) {
    when (frame.type) {
        HermesRealtimeRelayFrameType.MEDIA_BLOB_ADVERTISE ->
            inboundReceiver?.handleAdvertise(frame = frame, ackSender = ackSender)
        HermesRealtimeRelayFrameType.MEDIA_BLOB_ACK -> Unit
        HermesRealtimeRelayFrameType.MEDIA_MIRROR_ACK ->
            frame.media?.mirrorAck?.let { inboundLastMirrorAck.value = it }
        HermesRealtimeRelayFrameType.MEDIA_CALL_ACK ->
            frame.media?.callAck?.let { inboundLastCallAck.value = it }
        HermesRealtimeRelayFrameType.MEDIA_STREAM_FRAME ->
            handleMercuryStreamFrame(frame)
        HermesRealtimeRelayFrameType.MEDIA_PRESENCE_HEARTBEAT ->
            applyMercuryPresenceHeartbeat(frame)
        HermesRealtimeRelayFrameType.CONTROL_AGENT_GRANT_RECEIPT ->
            frame.control?.agentGrantReceipt?.let { receipt ->
                inboundLastAgentGrantReceipt.value = receipt
                AgentCapabilityGrantState.apply(receipt)
            }
        HermesRealtimeRelayFrameType.CONTROL_DENIED ->
            frame.control?.denied?.let { inboundLastControlDenied.value = it }
        HermesRealtimeRelayFrameType.CONTROL_SYSTEM_PERMISSION_STATUS ->
            frame.control?.systemPermissionStatus?.let { status ->
                com.openburnbar.data.computeruse.SystemPermissionInboxStoreHolder
                    .ingest(status, threadId = frame.control?.sessionId)
            }
        HermesRealtimeRelayFrameType.CONTROL_CLIPBOARD_RESPONSE ->
            frame.control?.clipboardResponse?.let { inboundLastClipboardResponse.value = it }
        HermesRealtimeRelayFrameType.REMOTE_UNLOCK_STATE ->
            frame.control?.remoteUnlockState?.let { inboundLastRemoteUnlockState.value = it }
        HermesRealtimeRelayFrameType.REMOTE_UNLOCK_RESULT,
        HermesRealtimeRelayFrameType.REMOTE_UNLOCK_DENIED,
        ->
            frame.control?.remoteUnlockResult?.let { inboundLastRemoteUnlockResult.value = it }
        HermesRealtimeRelayFrameType.MEDIA_CLASSIFY -> Unit
        else -> Unit
    }
}

private fun MediaControlStreamCoordinator.applyMercuryPresenceHeartbeat(frame: HermesRealtimeRelayFrame) {
    val receivedAtMillis = System.currentTimeMillis()
    inboundLastPeerHeartbeatAtMillis.value = receivedAtMillis
    inboundPendingHeartbeatSentAtMillis?.let { sentAtMillis ->
        inboundLastRoundTripMillis.value =
            (receivedAtMillis - sentAtMillis)
                .coerceAtLeast(0L)
                .coerceAtMost(Int.MAX_VALUE.toLong())
                .toInt()
        inboundPendingHeartbeatSentAtMillis = null
    }
    inboundLastPeerCapabilities.value = frame.media?.presence?.capabilities.orEmpty().toSet()
}

internal suspend fun MediaControlStreamCoordinator.runMercuryPresenceHeartbeatLoop(
    stream: IrohRelayStream,
    uid: String,
    connectionID: String,
) {
    while (inboundScope.isActive && inboundSupervisorJob?.isActive == true) {
        val sentAtMillis = System.currentTimeMillis()
        stream.send(makeMercuryPresenceHeartbeat(uid = uid, connectionID = connectionID))
        inboundPendingHeartbeatSentAtMillis = sentAtMillis
        kotlinx.coroutines.delay(inboundPresenceHeartbeatIntervalMillis)
    }
}

internal fun MediaControlStreamCoordinator.makeMercuryPresenceHeartbeat(
    uid: String,
    connectionID: String,
): HermesRealtimeRelayFrame =
    HermesRealtimeRelayFrame(
        type = HermesRealtimeRelayFrameType.MEDIA_PRESENCE_HEARTBEAT,
        uid = uid,
        connectionId = connectionID,
        media = HermesRealtimeRelayMediaPayload(
            presence = HermesRealtimeRelayPresenceHeartbeat(
                peerDeviceId = inboundPeerDeviceIdProvider().ifBlank { "android" },
                displayName = inboundDisplayNameProvider().ifBlank { "Android" },
                deviceDisplayName = inboundDisplayNameProvider().ifBlank { "Android" },
                capabilities = listOf(
                    "media.control",
                    "media.mirror.request",
                    "media.call.invite",
                    "media.blob.transfer",
                ),
                streamingCapabilities = AndroidMediaCodecCapabilityProbe.snapshot(
                    mediaFrameVersions = MercuryMediaFrameVersionSupport.V1_AND_V2,
                ).toWire(),
                sentAt = Instant.now().toString(),
            ),
        ),
    )

internal suspend fun MediaControlStreamCoordinator.handleMercuryStreamFrame(frame: HermesRealtimeRelayFrame) {
    mercuryStreamFrameDelivery(frame)?.let { delivery -> runCatching { delivery() } }
}

private suspend fun MediaControlStreamCoordinator.mercuryStreamFrameDelivery(
    frame: HermesRealtimeRelayFrame,
): (suspend () -> Unit)? {
    val media = frame.media
    val encoded = media?.encodedFrameBase64
    if (
        media == null ||
        media.streamClass != MediaStreamClass.SCREEN_VIDEO.raw ||
        encoded == null
    ) {
        return null
    }
    media.focusContext?.let { focus -> focusContextHandler?.invoke(focus) }
    val chunkBytes = runCatching { Base64.getDecoder().decode(encoded) }.getOrNull() ?: return null
    val data = inboundFrameChunkAssembler.accept(media.frameChunk, chunkBytes) ?: return null
    return if (MediaFrameV2Codec.isEncodedEnvelope(data)) {
        mirrorFrameV2Handler?.let { handler ->
            { handler(inboundMediaFrameV2Codec.decode(data).frame) }
        }
    } else {
        mirrorFrameHandler?.let { handler ->
            { handler(inboundMediaPacketCodec.decode(data).frame) }
        }
    }
}
