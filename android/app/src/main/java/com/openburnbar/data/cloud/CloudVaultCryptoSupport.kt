package com.openburnbar.data.cloud

import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

internal object CloudVaultCryptoSupport {
    private const val GCM_AUTH_TAG_BITS = 128
    private const val GCM_NONCE_BYTES = 12
    private const val SHA256_DIGEST_BYTES = 32
    private const val WRAPPED_KEY_EPHEMERAL_BYTES = 65
    private const val P256_Y_COORDINATE_OFFSET = 33

    fun encodeBase64(data: ByteArray): String = java.util.Base64.getEncoder().encodeToString(data)

    fun decodeBase64(value: String): ByteArray = java.util.Base64.getMimeDecoder().decode(value)

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

    fun fixed32(value: java.math.BigInteger): ByteArray {
        val raw = value.toByteArray()
        val positive = if (raw.size > SHA256_DIGEST_BYTES) raw.copyOfRange(raw.size - SHA256_DIGEST_BYTES, raw.size) else raw
        return ByteArray(SHA256_DIGEST_BYTES - positive.size) + positive
    }
}
