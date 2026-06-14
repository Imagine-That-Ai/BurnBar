package com.openburnbar.data.cloud

import java.text.Normalizer
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.signal.libsignal.protocol.ecc.ECPrivateKey
import org.signal.libsignal.protocol.ecc.ECPublicKey

private const val FIXED_COORDINATE_BYTES = 32

internal object CloudVaultCryptoSupport {
    private const val GCM_AUTH_TAG_BITS = 128
    private const val GCM_NONCE_BYTES = 12
    private const val SHA256_DIGEST_BYTES = 32
    private const val WRAPPED_KEY_EPHEMERAL_BYTES = 65
    private const val P256_Y_COORDINATE_OFFSET = 33

    fun encodeBase64(data: ByteArray): String = java.util.Base64.getEncoder().encodeToString(data)

    fun decodeBase64(value: String): ByteArray = java.util.Base64.getMimeDecoder().decode(value)

    fun decodeSignalPublicKey(bytes: ByteArray): ECPublicKey = ECPublicKey(bytes)

    fun decodeSignalPrivateKey(bytes: ByteArray): ECPrivateKey = ECPrivateKey(bytes)

    fun bindingToAAD(binding: SignalEnvelopeBinding): String {
        val segments =
            listOf(
                binding.mode,
                binding.scope,
                binding.uid,
                binding.clientId ?: "",
                binding.collection ?: "",
                binding.docId ?: "",
                binding.field ?: "",
                binding.slotId ?: "",
                binding.formatVersion.toString(),
            ).map { Normalizer.normalize(it, Normalizer.Form.NFC) }
        require(segments.none { it.any { ch -> ch == '|' || ch == '\r' || ch == '\n' } }) {
            "Signal envelope binding segment contains a reserved character"
        }
        return "OpenBurnBar-Signal-AAD-v1|${segments.joinToString("|")}"
    }

    fun atRestSeal(plaintext: ByteArray, recipientIdentityPublicKey: ByteArray, binding: SignalEnvelopeBinding): ByteArray {
        val canonical = bindingToAAD(binding)
        return decodeSignalPublicKey(recipientIdentityPublicKey).seal(
            plaintext,
            "${CloudVaultCrypto.SIGNAL_AT_REST_INFO_PREFIX}$canonical".toByteArray(Charsets.UTF_8),
            canonical.toByteArray(Charsets.UTF_8),
        )
    }

    fun atRestOpen(ciphertext: ByteArray, recipientIdentityPrivateKey: ByteArray, binding: SignalEnvelopeBinding): ByteArray {
        val canonical = bindingToAAD(binding)
        return decodeSignalPrivateKey(recipientIdentityPrivateKey).open(
            ciphertext,
            "${CloudVaultCrypto.SIGNAL_AT_REST_INFO_PREFIX}$canonical".toByteArray(Charsets.UTF_8),
            canonical.toByteArray(Charsets.UTF_8),
        )
    }

    fun openAesGcm(key: ByteArray, nonce: ByteArray, ciphertextAndTag: ByteArray, aad: ByteArray? = null): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_AUTH_TAG_BITS, nonce))
        if (aad != null) cipher.updateAAD(aad)
        return cipher.doFinal(ciphertextAndTag)
    }

    fun publicKeyFromX963(bytes: ByteArray, params: java.security.spec.ECParameterSpec): java.security.PublicKey {
        require(bytes.size == WRAPPED_KEY_EPHEMERAL_BYTES && bytes[0] == 0x04.toByte()) {
            "Invalid P-256 public key"
        }
        val x = java.math.BigInteger(1, bytes.copyOfRange(1, P256_Y_COORDINATE_OFFSET))
        val y = java.math.BigInteger(1, bytes.copyOfRange(P256_Y_COORDINATE_OFFSET, WRAPPED_KEY_EPHEMERAL_BYTES))
        return java.security.KeyFactory.getInstance("EC")
            .generatePublic(java.security.spec.ECPublicKeySpec(java.security.spec.ECPoint(x, y), params))
    }
}

internal fun cloudVaultFixed32(value: java.math.BigInteger): ByteArray {
    val raw = value.toByteArray()
    val positive = if (raw.size > FIXED_COORDINATE_BYTES) raw.copyOfRange(raw.size - FIXED_COORDINATE_BYTES, raw.size) else raw
    return ByteArray(FIXED_COORDINATE_BYTES - positive.size) + positive
}
