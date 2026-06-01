package com.openburnbar.data.hermes.relay

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Hermes relay symmetric crypto primitives. Wire-format identical to the
 * iOS / macOS `HermesRelayCrypto.swift` implementation, byte for byte.
 */
object HermesRelayCrypto {
    private const val BITS_PER_BYTE = 0x08
    private const val GCM_TAG_BITS = 128
    private const val GCM_IV_BYTES = 12
    private const val AES_KEY_BYTES = 32

    private const val AAD_PREFIX = "OpenBurnBar-HermesRelay-v1"
    private const val KEY_WRAP_SHARED_INFO_PREFIX = "OpenBurnBar-HermesRelay-KeyWrap-v1|"

    private val secureRandom = SecureRandom()

    const val ALGORITHM = "p256-hkdf-sha256-aesgcm"
    const val KEY_VERSION = 1

    fun requestAAD(uid: String, connectionId: String, requestId: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("request", uid, connectionId, requestId))

    fun keyAAD(uid: String, connectionId: String, requestId: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("key", uid, connectionId, requestId))

    fun chunkAAD(uid: String, connectionId: String, requestId: String, sequence: Int, kind: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("chunk", uid, connectionId, requestId, sequence.toString(), kind))

    fun generateSymmetricKey(): ByteArray = ByteArray(AES_KEY_BYTES).also(secureRandom::nextBytes)

    fun sealToBase64(plaintext: ByteArray, keyData: ByteArray, aad: ByteArray): String {
        require(keyData.size == AES_KEY_BYTES) { "symmetric key must be 32 bytes" }
        val nonce = ByteArray(GCM_IV_BYTES).also(secureRandom::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(keyData, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        val ciphertext = cipher.doFinal(plaintext)
        return HermesRelayCryptoSupport.base64NoWrap(nonce + ciphertext)
    }

    fun openBase64(ciphertext: String, keyData: ByteArray, aad: ByteArray): ByteArray {
        require(keyData.size == AES_KEY_BYTES) { "symmetric key must be 32 bytes" }
        val combined = HermesRelayCryptoSupport.base64Decode(ciphertext)
        require(combined.size > GCM_IV_BYTES) { "ciphertext too short" }
        val nonce = combined.copyOfRange(0, GCM_IV_BYTES)
        val body = combined.copyOfRange(GCM_IV_BYTES, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(keyData, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(body)
    }

    fun wrapSymmetricKey(keyData: ByteArray, recipientPublicKeyX963: ByteArray, aad: ByteArray): String {
        require(keyData.size == AES_KEY_BYTES) { "symmetric key must be 32 bytes" }
        val recipientKey = HermesRelayCryptoEc.decodeUncompressedPublicKey(recipientPublicKeyX963)
        val ephemeralKeyPair = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val ephemeralPub =
            ephemeralKeyPair.public as? java.security.interfaces.ECPublicKey
                ?: error("Hermes relay ephemeral keypair must use an EC public key")
        val shared = HermesRelayCryptoEc.ecdh(ephemeralKeyPair.private, recipientKey)
        val wrappingKey =
            HermesRelayCryptoHkdf.hkdfDeriveSymmetricKey(
                sharedSecret = shared,
                sharedInfo = HermesRelayCryptoSupport.keyWrapSharedInfo(aad),
                length = AES_KEY_BYTES,
            )
        val nonce = ByteArray(GCM_IV_BYTES).also(secureRandom::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(wrappingKey, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        val sealed = cipher.doFinal(keyData)
        return HermesRelayCryptoSupport.base64NoWrap(HermesRelayCryptoEc.encodeUncompressedPublicKey(ephemeralPub) + nonce + sealed)
    }

    fun unwrapSymmetricKey(wrappedKeyBase64: String, privateKey: java.security.PrivateKey, aad: ByteArray): ByteArray {
        val envelope = HermesRelayCryptoSupport.base64Decode(wrappedKeyBase64)
        require(envelope.size > HermesRelayCryptoEc.UNCOMPRESSED_POINT_LEN) { "wrapped key too short" }
        val ephemeralPubBytes = envelope.copyOfRange(0, HermesRelayCryptoEc.UNCOMPRESSED_POINT_LEN)
        val sealed = envelope.copyOfRange(HermesRelayCryptoEc.UNCOMPRESSED_POINT_LEN, envelope.size)
        require(sealed.size > GCM_IV_BYTES) { "wrapped key body too short" }
        val ephemeralPub = HermesRelayCryptoEc.decodeUncompressedPublicKey(ephemeralPubBytes)
        val shared = HermesRelayCryptoEc.ecdh(privateKey, ephemeralPub)
        val wrappingKey =
            HermesRelayCryptoHkdf.hkdfDeriveSymmetricKey(
                sharedSecret = shared,
                sharedInfo = HermesRelayCryptoSupport.keyWrapSharedInfo(aad),
                length = AES_KEY_BYTES,
            )
        val nonce = sealed.copyOfRange(0, GCM_IV_BYTES)
        val body = sealed.copyOfRange(GCM_IV_BYTES, sealed.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(wrappingKey, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(body)
    }

    fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
}
