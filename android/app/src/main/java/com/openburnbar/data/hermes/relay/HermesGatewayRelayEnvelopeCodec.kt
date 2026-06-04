package com.openburnbar.data.hermes.relay

import java.security.PrivateKey

data class HermesGatewayRelayEnvelopeWire(
    val relayKeyVersion: Int,
    val relayEncryption: String,
    val payloadCiphertext: String,
    val wrappedKey: String,
    val senderPublicKey: String,
    val enc: String? = null,
)

object HermesGatewayRelayEnvelopeCodec {
    fun sealEventPayload(
        plaintext: ByteArray,
        uid: String,
        clientId: String,
        eventId: String,
        recipientPublicKeyX963: ByteArray,
        senderPrivateKey: PrivateKey,
        preferredRelayKeyVersion: Int = HermesRelayCrypto.KEY_VERSION_V3,
    ): HermesGatewayRelayEnvelopeWire =
        sealPayload(
            plaintext = plaintext,
            payloadAAD = HermesRelayCrypto.gatewayEventAAD(uid, clientId, eventId),
            keyAAD = HermesRelayCrypto.gatewayEventKeyAAD(uid, clientId, eventId),
            recipientPublicKeyX963 = recipientPublicKeyX963,
            senderPrivateKey = senderPrivateKey,
            preferredRelayKeyVersion = preferredRelayKeyVersion,
        )

    fun openEventPayload(
        envelope: HermesGatewayRelayEnvelopeWire,
        uid: String,
        clientId: String,
        eventId: String,
        recipientPrivateKey: PrivateKey,
        pinnedSenderPublicKeyX963: ByteArray,
    ): ByteArray =
        openPayload(
            envelope = envelope,
            payloadAAD = HermesRelayCrypto.gatewayEventAAD(uid, clientId, eventId),
            keyAAD = HermesRelayCrypto.gatewayEventKeyAAD(uid, clientId, eventId),
            recipientPrivateKey = recipientPrivateKey,
            pinnedSenderPublicKeyX963 = pinnedSenderPublicKeyX963,
        )

    fun sealMessagePayload(
        plaintext: ByteArray,
        uid: String,
        clientId: String,
        messageId: String,
        recipientPublicKeyX963: ByteArray,
        senderPrivateKey: PrivateKey,
        preferredRelayKeyVersion: Int = HermesRelayCrypto.KEY_VERSION_V3,
    ): HermesGatewayRelayEnvelopeWire =
        sealPayload(
            plaintext = plaintext,
            payloadAAD = HermesRelayCrypto.gatewayMessageAAD(uid, clientId, messageId),
            keyAAD = HermesRelayCrypto.gatewayMessageKeyAAD(uid, clientId, messageId),
            recipientPublicKeyX963 = recipientPublicKeyX963,
            senderPrivateKey = senderPrivateKey,
            preferredRelayKeyVersion = preferredRelayKeyVersion,
        )

    fun openMessagePayload(
        envelope: HermesGatewayRelayEnvelopeWire,
        uid: String,
        clientId: String,
        messageId: String,
        recipientPrivateKey: PrivateKey,
        pinnedSenderPublicKeyX963: ByteArray,
    ): ByteArray =
        openPayload(
            envelope = envelope,
            payloadAAD = HermesRelayCrypto.gatewayMessageAAD(uid, clientId, messageId),
            keyAAD = HermesRelayCrypto.gatewayMessageKeyAAD(uid, clientId, messageId),
            recipientPrivateKey = recipientPrivateKey,
            pinnedSenderPublicKeyX963 = pinnedSenderPublicKeyX963,
        )

    fun sealAttachmentManifestPayload(
        plaintext: ByteArray,
        uid: String,
        clientId: String,
        attachmentId: String,
        recipientPublicKeyX963: ByteArray,
        senderPrivateKey: PrivateKey,
        preferredRelayKeyVersion: Int = HermesRelayCrypto.KEY_VERSION_V3,
    ): HermesGatewayRelayEnvelopeWire =
        sealPayload(
            plaintext = plaintext,
            payloadAAD = HermesRelayCrypto.gatewayAttachmentManifestAAD(uid, clientId, attachmentId),
            keyAAD = HermesRelayCrypto.gatewayAttachmentKeyAAD(uid, clientId, attachmentId),
            recipientPublicKeyX963 = recipientPublicKeyX963,
            senderPrivateKey = senderPrivateKey,
            preferredRelayKeyVersion = preferredRelayKeyVersion,
        )

    fun openAttachmentManifestPayload(
        envelope: HermesGatewayRelayEnvelopeWire,
        uid: String,
        clientId: String,
        attachmentId: String,
        recipientPrivateKey: PrivateKey,
        pinnedSenderPublicKeyX963: ByteArray,
    ): ByteArray =
        openPayload(
            envelope = envelope,
            payloadAAD = HermesRelayCrypto.gatewayAttachmentManifestAAD(uid, clientId, attachmentId),
            keyAAD = HermesRelayCrypto.gatewayAttachmentKeyAAD(uid, clientId, attachmentId),
            recipientPrivateKey = recipientPrivateKey,
            pinnedSenderPublicKeyX963 = pinnedSenderPublicKeyX963,
        )

    fun sealPayload(
        plaintext: ByteArray,
        payloadAAD: ByteArray,
        keyAAD: ByteArray,
        recipientPublicKeyX963: ByteArray,
        senderPrivateKey: PrivateKey,
        preferredRelayKeyVersion: Int = HermesRelayCrypto.KEY_VERSION_V3,
    ): HermesGatewayRelayEnvelopeWire {
        val contentKey = HermesRelayCrypto.generateSymmetricKey()
        val payloadCiphertext = HermesRelayCrypto.sealToBase64(plaintext, contentKey, payloadAAD)
        val senderPublicKey = HermesRelayCryptoSupport.base64NoWrap(
            HermesRelayCryptoEc.publicKeyX963FromPrivateKey(senderPrivateKey)
        )
        return if (preferredRelayKeyVersion == HermesRelayCrypto.KEY_VERSION_V3) {
            val wrap = HermesRelayCrypto.wrapSymmetricKeyV3(
                keyData = contentKey,
                recipientPublicKeyX963 = recipientPublicKeyX963,
                senderPrivateKey = senderPrivateKey,
                aad = keyAAD,
            )
            HermesGatewayRelayEnvelopeWire(
                relayKeyVersion = HermesRelayCrypto.KEY_VERSION_V3,
                relayEncryption = HermesRelayCrypto.ALGORITHM_V3,
                payloadCiphertext = payloadCiphertext,
                wrappedKey = wrap.wrappedKey,
                senderPublicKey = senderPublicKey,
                enc = wrap.enc,
            )
        } else {
            val wrappedKey = HermesRelayCrypto.wrapSymmetricKey(
                keyData = contentKey,
                recipientPublicKeyX963 = recipientPublicKeyX963,
                aad = keyAAD,
                senderPrivateKey = senderPrivateKey,
            )
            HermesGatewayRelayEnvelopeWire(
                relayKeyVersion = HermesRelayCrypto.GATEWAY_KEY_VERSION,
                relayEncryption = HermesRelayCrypto.ALGORITHM,
                payloadCiphertext = payloadCiphertext,
                wrappedKey = wrappedKey,
                senderPublicKey = senderPublicKey,
            )
        }
    }

    fun openPayload(
        envelope: HermesGatewayRelayEnvelopeWire,
        payloadAAD: ByteArray,
        keyAAD: ByteArray,
        recipientPrivateKey: PrivateKey,
        pinnedSenderPublicKeyX963: ByteArray,
    ): ByteArray {
        val contentKey =
            when (envelope.relayKeyVersion) {
                HermesRelayCrypto.KEY_VERSION_V3 -> {
                    require(envelope.relayEncryption == HermesRelayCrypto.ALGORITHM_V3) {
                        "gateway v3 envelope missing HPKE relayEncryption marker"
                    }
                    val enc = requireNotNull(envelope.enc) { "gateway v3 envelope missing enc" }
                    HermesRelayCrypto.unwrapSymmetricKeyV3(
                        encBase64 = enc,
                        wrappedKeyBase64 = envelope.wrappedKey,
                        privateKey = recipientPrivateKey,
                        pinnedSenderPublicKeyX963 = pinnedSenderPublicKeyX963,
                        aad = keyAAD,
                    )
                }
                HermesRelayCrypto.GATEWAY_KEY_VERSION -> {
                    require(envelope.relayEncryption == HermesRelayCrypto.ALGORITHM) {
                        "gateway v2 envelope missing relayEncryption marker"
                    }
                    HermesRelayCrypto.unwrapSymmetricKey(
                        wrappedKeyBase64 = envelope.wrappedKey,
                        privateKey = recipientPrivateKey,
                        aad = keyAAD,
                        senderPublicKeyX963 = pinnedSenderPublicKeyX963,
                    )
                }
                else -> error("unsupported gateway relayKeyVersion ${envelope.relayKeyVersion}")
            }
        return HermesRelayCrypto.openBase64(envelope.payloadCiphertext, contentKey, payloadAAD)
    }
}
