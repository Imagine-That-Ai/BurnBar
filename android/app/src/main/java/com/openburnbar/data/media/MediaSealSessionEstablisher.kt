package com.openburnbar.data.media

import com.openburnbar.data.hermes.relay.RelaySealSenderIdentity
import com.openburnbar.irohrelay.HermesRealtimeRelayControlSealKeyEnvelope

/**
 * F7 — phone-side media-seal establishment, shared by every mirror-request
 * call site (the [MediaControlStreamCoordinator] invokes it from
 * `requestMirror`, so all four Android mirror surfaces negotiate
 * identically). Android mirror of the iOS `MediaSealSessionEstablisher`
 * (`OpenBurnBarMobile/Services/Media/MediaSealSessionEstablisher.swift`).
 *
 * Default-off: [MediaFrameAeadNegotiation.REMOTE_CONFIG_KEY] resolves to
 * `false` until a fetch-and-activate ramp lands (and on any Firebase
 * initialization failure, e.g. unit tests), so the gate fails closed in
 * every environment — flags off ⇒ no `mediaSealKey` on the mirror request ⇒
 * emitted bytes identical to the legacy lane.
 */
object MediaSealSessionEstablisher {
    data class Session(
        val envelope: HermesRealtimeRelayControlSealKeyEnvelope,
        val key: ByteArray,
    )

    /** Default-ON protection flag, same key the iOS client reads; a fetched
     * Remote Config value is the kill switch and always wins. */
    fun remoteConfigEnabled(): Boolean =
        com.openburnbar.data.computeruse.remoteConfigProtectionFlag(MediaFrameAeadNegotiation.REMOTE_CONFIG_KEY)

    /**
     * Establish when (and only when) the default-off RC flag is on AND the
     * Mac advertised `media_frame_aead_v1` in its presence-heartbeat
     * capability strings. Returns null — the legacy plaintext-at-app-layer
     * lane — otherwise, or when wrap preparation fails (per-frame sealing is
     * defense-in-depth; a mirror must not fail because the seal could not be
     * established). The Mac's HPKE relay recipient key comes from the paired
     * connection record — never from the stream itself.
     */
    suspend fun establishIfNegotiated(
        uid: String,
        connectionId: String,
        viewerId: String,
        macCapabilities: Set<String>,
    ): Session? {
        if (!remoteConfigEnabled()) return null
        if (!MediaFrameAeadNegotiation.resolveSealingEnabled(
                localSupports = true,
                remoteSupports = macCapabilities.contains(MediaFrameAeadNegotiation.CAPABILITY),
            )
        ) {
            return null
        }
        return runCatching {
            val recipientKey =
                RelaySealSenderIdentity.macRelayPublicKeyBase64(uid = uid, connectionId = connectionId)
                    ?: return null
            val sender =
                RelaySealSenderIdentity.prepareAndPublish(
                    uid = uid,
                    connectionId = connectionId,
                    counterKeyPrefix = RelaySealSenderIdentity.MEDIA_SEAL_COUNTER_PREFIX,
                )
            val established =
                MediaFrameSealSession.establish(
                    uid = uid,
                    connectionId = connectionId,
                    viewerId = viewerId,
                    senderDeviceId = sender.senderDeviceId,
                    senderPeerNodeId = sender.senderPeerNodeId,
                    senderKeyId = sender.keyId,
                    senderCounter = sender.senderCounter,
                    recipientPublicKeyBase64 = recipientKey,
                    senderPrivateKey = sender.senderPrivateKey,
                )
            Session(envelope = established.envelope, key = established.key)
        }.getOrNull()
    }
}
