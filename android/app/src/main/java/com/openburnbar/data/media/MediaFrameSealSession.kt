package com.openburnbar.data.media

import com.openburnbar.data.hermes.relay.HermesRelayCrypto
import com.openburnbar.data.hermes.relay.HermesRelayCryptoSupport
import com.openburnbar.irohrelay.HermesRealtimeRelayControlSealKeyEnvelope
import java.security.PrivateKey

/**
 * F7 — media-seal session lifecycle, the F10 control-seal pattern applied to
 * the media lane. 1:1 Kotlin port of the Swift `MediaFrameSealSession`
 * (`OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaFrameSealSession.swift`):
 *
 *  1. The phone generates a fresh 32-byte session secret when it builds its
 *     mirror request and wraps it with [HermesRelayCrypto.wrapSymmetricKeyV3]
 *     (RFC 9180 Auth-mode P-256 to the Mac's pinned relay key,
 *     sender-authenticated by the phone's relay sender key) under
 *     [HermesRelayCrypto.mediaSealKeyAAD], bound to the mirror `viewerId`.
 *     The wrap rides `HermesRealtimeRelayMirrorRequest.mediaSealKey`.
 *  2. The Mac opens it through the SAME pinned relay-sender trust path as the
 *     chat opener and both sides derive the AES-256-GCM frame key with
 *     [MediaFrameAead.deriveSessionKey], salted by the connection id.
 *  3. The Mac seals every encoded media frame ([MediaFrameAead], OBMFA1,
 *     position-bound AAD) before chunking; the phone opens after reassembly.
 */
object MediaFrameSealSession {
    /** The established session: the wire envelope plus the derived frame key. */
    data class Established(
        val envelope: HermesRealtimeRelayControlSealKeyEnvelope,
        val key: ByteArray,
    )

    /**
     * Phone side: wrap a fresh session secret for the Mac and derive the
     * local frame key.
     */
    @Suppress("LongParameterList")
    fun establish(
        uid: String,
        connectionId: String,
        viewerId: String,
        senderDeviceId: String,
        senderPeerNodeId: String,
        senderKeyId: String,
        senderCounter: Long,
        recipientPublicKeyBase64: String,
        senderPrivateKey: PrivateKey,
    ): Established {
        val keyData = HermesRelayCrypto.generateSymmetricKey()
        val wrap =
            HermesRelayCrypto.wrapSymmetricKeyV3(
                keyData = keyData,
                recipientPublicKeyX963 = HermesRelayCryptoSupport.base64Decode(recipientPublicKeyBase64),
                senderPrivateKey = senderPrivateKey,
                aad =
                HermesRelayCrypto.mediaSealKeyAAD(
                    uid = uid,
                    connectionId = connectionId,
                    viewerId = viewerId,
                    senderDeviceId = senderDeviceId,
                    senderKeyId = senderKeyId,
                    senderCounter = senderCounter,
                ),
            )
        val envelope =
            HermesRealtimeRelayControlSealKeyEnvelope(
                encBase64 = wrap.enc,
                wrappedKeyBase64 = wrap.wrappedKey,
                senderDeviceId = senderDeviceId,
                senderPeerNodeId = senderPeerNodeId,
                senderKeyId = senderKeyId,
                senderCounter = senderCounter,
                relayKeyVersion = HermesRelayCrypto.KEY_VERSION_V3,
            )
        return Established(envelope = envelope, key = deriveKey(keyData, connectionId))
    }

    /**
     * Receiver side: open the wrapped session secret.
     * [pinnedSenderPublicKeyX963] MUST come from the pinned relay-sender-key
     * source — never the frame. (On Android↔Mac, the Mac is the opener; this
     * mirror keeps the Kotlin lifecycle whole and pins the contract in unit
     * tests.)
     */
    @Suppress("LongParameterList")
    fun open(
        envelope: HermesRealtimeRelayControlSealKeyEnvelope,
        uid: String,
        connectionId: String,
        viewerId: String,
        recipientPrivateKey: PrivateKey,
        pinnedSenderPublicKeyX963: ByteArray,
    ): ByteArray {
        val keyData =
            HermesRelayCrypto.unwrapSymmetricKeyV3(
                encBase64 = envelope.encBase64,
                wrappedKeyBase64 = envelope.wrappedKeyBase64,
                privateKey = recipientPrivateKey,
                pinnedSenderPublicKeyX963 = pinnedSenderPublicKeyX963,
                aad =
                HermesRelayCrypto.mediaSealKeyAAD(
                    uid = uid,
                    connectionId = connectionId,
                    viewerId = viewerId,
                    senderDeviceId = envelope.senderDeviceId,
                    senderKeyId = envelope.senderKeyId,
                    senderCounter = envelope.senderCounter,
                ),
            )
        return deriveKey(keyData, connectionId)
    }

    private fun deriveKey(sessionSecret: ByteArray, connectionId: String): ByteArray =
        MediaFrameAead.deriveSessionKey(
            sharedSecret = sessionSecret,
            salt = connectionId.toByteArray(Charsets.UTF_8),
        )
}
