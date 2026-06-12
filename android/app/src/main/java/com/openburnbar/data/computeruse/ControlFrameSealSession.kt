package com.openburnbar.data.computeruse

import com.openburnbar.data.hermes.relay.HermesRelayCrypto
import com.openburnbar.data.hermes.relay.HermesRelayCryptoSupport
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayloadCodec
import com.openburnbar.irohrelay.HermesRealtimeRelayControlSealKeyEnvelope
import java.security.GeneralSecurityException
import java.security.PrivateKey

/**
 * F10 — control-seal session lifecycle. 1:1 Kotlin port of the Swift
 * `ControlFrameSealSession`
 * (`OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ControlFrameSealSession.swift`):
 *
 *  1. At `control.classify` time the phone generates a fresh 32-byte session
 *     secret and wraps it with the tested relay primitive
 *     ([HermesRelayCrypto.wrapSymmetricKeyV3] — RFC 9180 Auth-mode P-256 to
 *     the Mac's pinned relay key, sender-authenticated by the phone's relay
 *     sender key) under [HermesRelayCrypto.controlSealKeyAAD]. The wrap rides
 *     the classify frame as [HermesRealtimeRelayControlSealKeyEnvelope].
 *  2. Both sides derive the AES-256-GCM seal key with
 *     [ControlFrameSeal.deriveSessionKey], salted by the connection id.
 *  3. Every subsequent control payload is replaced by a routing shell
 *     (`streamClass` only) carrying `sealedFrameBase64` — a [ControlFrameSeal]
 *     envelope over the inner payload JSON, AAD-bound to (controller
 *     peerNodeId, frame type).
 *
 * The inner payload JSON uses the relay wire codec
 * ([HermesRealtimeRelayControlPayloadCodec]) so timestamps and field shapes
 * survive the seal round trip byte-exactly across Swift and Kotlin.
 */
object ControlFrameSealSession {
    sealed class SessionException(message: String) : GeneralSecurityException(message) {
        class SealedPayloadMissing : SessionException("control seal payload is missing or undecodable base64")
        class InnerPayloadUndecodable : SessionException("opened control seal payload is not a control payload")
    }

    /** The established session: the wire envelope plus the derived seal key. */
    data class Established(
        val envelope: HermesRealtimeRelayControlSealKeyEnvelope,
        val key: ByteArray,
    )

    /**
     * Phone side: wrap a fresh session secret for the Mac and derive the
     * local seal key. [recipientPublicKeyBase64] is the Mac relay key the
     * phone already pins/verifies (from the paired connection record, never
     * the stream); [senderPrivateKey] is the phone's relay sender key (the
     * same identity the chat lane authenticates with).
     */
    fun establish(
        uid: String,
        connectionId: String,
        peerNodeId: String,
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
                HermesRelayCrypto.controlSealKeyAAD(
                    uid = uid,
                    connectionId = connectionId,
                    peerNodeId = peerNodeId,
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
     * [pinnedSenderPublicKeyX963] MUST come from the same pinned
     * relay-sender-key source the chat opener uses — never from the frame
     * itself. (On Android↔Mac, the Mac is the opener; this mirror keeps the
     * Kotlin lifecycle whole and pins the contract in unit tests.)
     */
    fun open(
        envelope: HermesRealtimeRelayControlSealKeyEnvelope,
        uid: String,
        connectionId: String,
        peerNodeId: String,
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
                HermesRelayCrypto.controlSealKeyAAD(
                    uid = uid,
                    connectionId = connectionId,
                    peerNodeId = peerNodeId,
                    senderDeviceId = envelope.senderDeviceId,
                    senderKeyId = envelope.senderKeyId,
                    senderCounter = envelope.senderCounter,
                ),
            )
        return deriveKey(keyData, connectionId)
    }

    /**
     * Replace [payload] with its sealed shell: `streamClass` stays visible
     * for routing, everything else rides inside the OBCFS1 envelope.
     */
    fun sealPayload(
        payload: HermesRealtimeRelayControlPayload,
        key: ByteArray,
        peerNodeId: String,
        frameType: String,
    ): HermesRealtimeRelayControlPayload {
        val plaintext = HermesRealtimeRelayControlPayloadCodec.encodeToBytes(payload)
        val sealed = ControlFrameSeal.seal(plaintext = plaintext, key = key, peerNodeId = peerNodeId, frameType = frameType)
        return HermesRealtimeRelayControlPayload(
            streamClass = payload.streamClass,
            sealedFrameBase64 = HermesRelayCryptoSupport.base64NoWrap(sealed),
        )
    }

    /**
     * Open a sealed shell back into the inner payload. Fail-closed: any
     * decode/AAD/tag failure throws and the frame must be dropped, never
     * dispatched.
     */
    fun openPayload(
        payload: HermesRealtimeRelayControlPayload,
        key: ByteArray,
        peerNodeId: String,
        frameType: String,
    ): HermesRealtimeRelayControlPayload {
        val sealed =
            payload.sealedFrameBase64
                ?.let { encoded -> runCatching { HermesRelayCryptoSupport.base64Decode(encoded) }.getOrNull() }
                ?: throw SessionException.SealedPayloadMissing()
        val plaintext = ControlFrameSeal.open(envelope = sealed, key = key, peerNodeId = peerNodeId, frameType = frameType)
        return try {
            HermesRealtimeRelayControlPayloadCodec.decodeFromBytes(plaintext)
        } catch (_: Throwable) {
            throw SessionException.InnerPayloadUndecodable()
        }
    }

    private fun deriveKey(sessionSecret: ByteArray, connectionId: String): ByteArray =
        ControlFrameSeal.deriveSessionKey(
            hpkeSessionKey = sessionSecret,
            salt = connectionId.toByteArray(Charsets.UTF_8),
        )
}
