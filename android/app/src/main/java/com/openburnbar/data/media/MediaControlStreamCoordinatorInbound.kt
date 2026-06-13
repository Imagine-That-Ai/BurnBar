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
        HermesRealtimeRelayFrameType.CONTROL_DENIED -> {
            frame.control?.denied?.let { inboundLastControlDenied.value = it }
            inboundAgentWatchControlFrames.tryEmit(frame)
        }
        // RR-7b: replay inbound approval / classify frames to the Agent Watch ingest receiver (the
        // analogue of iOS AgentWatchReceiver.ingest) so a control.approvalRequest populates the
        // reducer's pendingApproval WITH its wireRequest and the phone can sign + transmit a response.
        HermesRealtimeRelayFrameType.CONTROL_APPROVAL_REQUEST,
        HermesRealtimeRelayFrameType.CONTROL_APPROVAL_RESPONSE,
        HermesRealtimeRelayFrameType.CONTROL_CLASSIFY,
        ->
            inboundAgentWatchControlFrames.tryEmit(frame)
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
    // F7: a sealed (OBMFA1) frame must open under the negotiated session key
    // with the cleartext position rebuilt into the AAD — fail closed (DROP)
    // on a missing key/position or any tag mismatch. Plaintext legacy frames
    // flow unchanged. Mirrors the iOS coordinator read loop.
    val data =
        runCatching { Base64.getDecoder().decode(encoded) }.getOrNull()
            ?.let { chunkBytes -> inboundFrameChunkAssembler.accept(media.frameChunk, chunkBytes) }
            ?.let { assembled ->
                if (MediaFrameAead.isSealedEnvelope(assembled)) {
                    openSealedMercuryMediaFrame(assembled, media)
                } else {
                    assembled
                }
            }
            ?: return null
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

/**
 * F7 — open a sealed media frame under the per-mirror session key, binding
 * the frame's cleartext stream position into the AAD. Any failure returns
 * null and the caller MUST drop the frame (never decode sealed bytes).
 */
internal fun MediaControlStreamCoordinator.openSealedMercuryMediaFrame(
    envelope: ByteArray,
    media: HermesRealtimeRelayMediaPayload,
): ByteArray? {
    val key = mediaFrameSealKey ?: return null
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
