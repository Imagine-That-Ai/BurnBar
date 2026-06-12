package com.openburnbar.data.computeruse

import com.google.crypto.tink.hybrid.HpkeParameters
import com.google.crypto.tink.hybrid.HpkePublicKey
import com.google.crypto.tink.hybrid.internal.HpkeEncrypt
import com.google.crypto.tink.util.Bytes
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockCredentialEnvelope
import java.security.GeneralSecurityException
import java.util.Base64

object RemoteUnlockCredentialEnvelopeCrypto {
    private const val X25519_PUBLIC_KEY_BYTES = 32
    const val ALGORITHM = "HPKE-X25519-SHA256-CHACHAPOLY"

    data class SealedCredential(
        val ciphertextBase64: String,
        val aadBase64: String,
        val redactedByteCount: Int,
    )

    data class RemoteUnlockSealRequest(
        val credential: String,
        val requestId: String,
        val sessionId: String,
        val clientIntentId: String,
        val credentialKind: HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind,
        val recipientKeyId: String,
        val recipientPublicKeyBase64: String,
        val algorithm: String = ALGORITHM,
    )

    fun seal(request: RemoteUnlockSealRequest): SealedCredential {
        val credential = request.credential
        val requestId = request.requestId
        val sessionId = request.sessionId
        val clientIntentId = request.clientIntentId
        val credentialKind = request.credentialKind
        val recipientKeyId = request.recipientKeyId
        val recipientPublicKeyBase64 = request.recipientPublicKeyBase64
        val algorithm = request.algorithm
        require(algorithm == ALGORITHM) { "unsupported Remote Unlock envelope algorithm: $algorithm" }
        val publicKeyBytes =
            try {
                Base64.getDecoder().decode(recipientPublicKeyBase64)
            } catch (error: IllegalArgumentException) {
                throw GeneralSecurityException("invalid Remote Unlock recipient key", error)
            }
        require(publicKeyBytes.size == X25519_PUBLIC_KEY_BYTES) { "Remote Unlock recipient key must be 32 bytes" }

        val parameters =
            HpkeParameters.builder()
                .setKemId(HpkeParameters.KemId.DHKEM_X25519_HKDF_SHA256)
                .setKdfId(HpkeParameters.KdfId.HKDF_SHA256)
                .setAeadId(HpkeParameters.AeadId.CHACHA20_POLY1305)
                .setVariant(HpkeParameters.Variant.NO_PREFIX)
                .build()
        val publicKey = HpkePublicKey.create(parameters, Bytes.copyFrom(publicKeyBytes), null)
        val info =
            infoData(
                requestId = requestId,
                sessionId = sessionId,
                clientIntentId = clientIntentId,
                credentialKind = credentialKind,
                recipientKeyId = recipientKeyId,
                algorithm = algorithm,
            )
        val ciphertext =
            HpkeEncrypt.create(publicKey).encrypt(
                credential.toByteArray(Charsets.UTF_8),
                info,
            )
        return SealedCredential(
            ciphertextBase64 = Base64.getEncoder().encodeToString(ciphertext),
            aadBase64 = Base64.getEncoder().encodeToString(info),
            redactedByteCount = credential.toByteArray(Charsets.UTF_8).size,
        )
    }

    fun infoData(
        requestId: String,
        sessionId: String,
        clientIntentId: String,
        credentialKind: HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind,
        recipientKeyId: String,
        algorithm: String = ALGORITHM,
    ): ByteArray {
        val builder = StringBuilder("OpenBurnBar Remote Unlock HPKE v1\n")
        appendField(builder, "algorithm", algorithm)
        appendField(builder, "requestId", requestId)
        appendField(builder, "sessionId", sessionId)
        appendField(builder, "clientIntentId", clientIntentId)
        appendField(builder, "credentialKind", credentialKind.wireValue())
        appendField(builder, "recipientKeyId", recipientKeyId)
        return builder.toString().toByteArray(Charsets.UTF_8)
    }

    private fun appendField(builder: StringBuilder, name: String, value: String) {
        val nameBytes = name.toByteArray(Charsets.UTF_8)
        val valueBytes = value.toByteArray(Charsets.UTF_8)
        builder
            .append(nameBytes.size)
            .append(':')
            .append(name)
            .append('=')
            .append(valueBytes.size)
            .append(':')
            .append(value)
            .append('\n')
    }
}

internal fun HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind.wireValue(): String = when (this) {
    HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind.TYPED_PASSWORD -> "typed_password"
    HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind.CLIPBOARD_PASSWORD -> "clipboard_password"
    HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind.SAVED_PASSWORD -> "saved_password"
}
