package com.openburnbar.data.media

import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import com.openburnbar.irohrelay.IrohRelayStream
import java.time.Instant

internal data class MediaControlHeartbeatLoopParams(
    val stream: IrohRelayStream,
    val uid: String,
    val connectionID: String,
    val scopeActive: () -> Boolean,
    val supervisorActive: () -> Boolean,
    val peerDeviceIdProvider: () -> String,
    val displayNameProvider: () -> String,
    val intervalMillis: Long,
    val onHeartbeatSent: (sentAtMillis: Long) -> Unit,
)

internal object MediaControlPresence {
    suspend fun heartbeatLoop(params: MediaControlHeartbeatLoopParams) {
        while (params.scopeActive() && params.supervisorActive()) {
            params.onHeartbeatSent(System.currentTimeMillis())
            params.stream.send(
                makeHeartbeat(
                    params.uid,
                    params.connectionID,
                    params.peerDeviceIdProvider,
                    params.displayNameProvider,
                ),
            )
            kotlinx.coroutines.delay(params.intervalMillis)
        }
    }

    fun makeHeartbeat(
        uid: String,
        connectionID: String,
        peerDeviceIdProvider: () -> String,
        displayNameProvider: () -> String,
    ): HermesRealtimeRelayFrame =
        HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.MEDIA_PRESENCE_HEARTBEAT,
            uid = uid,
            connectionId = connectionID,
            media =
            HermesRealtimeRelayMediaPayload(
                presence =
                com.openburnbar.irohrelay.HermesRealtimeRelayPresenceHeartbeat(
                    peerDeviceId = peerDeviceIdProvider().ifBlank { "android" },
                    displayName = displayNameProvider().ifBlank { "Android" },
                    deviceDisplayName = displayNameProvider().ifBlank { "Android" },
                    capabilities =
                    listOf(
                        "media.control",
                        "media.mirror.request",
                        "media.call.invite",
                        "media.blob.transfer",
                    ),
                    streamingCapabilities =
                    AndroidMediaCodecCapabilityProbe.snapshot(
                        mediaFrameVersions = MercuryMediaFrameVersionSupport.V1_AND_V2,
                    ).toWire(),
                    sentAt = Instant.now().toString(),
                ),
            ),
        )
}
