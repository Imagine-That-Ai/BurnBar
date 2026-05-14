package com.openburnbar.data.hermes.relay

import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Hermes relay symmetric crypto primitives. Wire-format identical to the
 * iOS `HermesRelayCrypto.swift` implementation:
 *
 *   - ECDH on NIST P-256 (`secp256r1`) for the static-relay /
 *     ephemeral-client key agreement.
 *   - HKDF-SHA256 over the shared secret with the AAD as `info` to derive
 *     a fresh 256-bit AES key per envelope.
 *   - AES-256-GCM (12-byte IV, 16-byte tag) for the sealed payload.
 *   - X9.63 uncompressed public-key encoding (`0x04 || X || Y`, 65 bytes)
 *     for keys on the wire.
 *   - AAD format: `OpenBurnBar-HermesRelay-v1|<operation>|<requestId>|<part>`.
 */
object HermesRelayCrypto {
    const val ALGORITHM = "p256-hkdf-sha256-aesgcm"

    private const val AAD_PREFIX = "OpenBurnBar-HermesRelay-v1"
    private const val GCM_TAG_BITS = 128
    private const val GCM_IV_BYTES = 12
    private const val AES_KEY_BYTES = 32
    private const val UNCOMPRESSED_POINT_LEN = 65

    private val secureRandom = SecureRandom()

    data class SealedEnvelope(val nonce: ByteArray, val ciphertext: ByteArray)

    fun aad(operation: String, requestId: String, part: String): ByteArray {
        return "$AAD_PREFIX|$operation|$requestId|$part".toByteArray(Charsets.UTF_8)
    }

    fun deriveKey(sharedSecret: ByteArray, aad: ByteArray): SecretKeySpec {
        val prk = hkdfExtract(salt = ByteArray(0), ikm = sharedSecret)
        val okm = hkdfExpand(prk = prk, info = aad, length = AES_KEY_BYTES)
        return SecretKeySpec(okm, "AES")
    }

    fun seal(plaintext: ByteArray, key: SecretKeySpec, aad: ByteArray): SealedEnvelope {
        val nonce = ByteArray(GCM_IV_BYTES).also(secureRandom::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        val ciphertext = cipher.doFinal(plaintext)
        return SealedEnvelope(nonce, ciphertext)
    }

    fun open(nonce: ByteArray, ciphertext: ByteArray, key: SecretKeySpec, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(ciphertext)
    }

    fun decodeUncompressedPublicKey(uncompressed: ByteArray): java.security.PublicKey {
        require(uncompressed.size == UNCOMPRESSED_POINT_LEN && uncompressed[0] == 0x04.toByte()) {
            "Expected 65-byte uncompressed P-256 point"
        }
        val spkiPrefix = byteArrayOf(
            0x30, 0x59,
            0x30, 0x13,
            0x06, 0x07, 0x2a.toByte(), 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a.toByte(), 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x03, 0x01, 0x07,
            0x03, 0x42, 0x00
        )
        val encoded = spkiPrefix + uncompressed
        return KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(encoded))
    }

    fun encodeUncompressedPublicKey(publicKey: java.security.interfaces.ECPublicKey): ByteArray {
        val w = publicKey.w
        val xBytes = leftPadTo(w.affineX.toByteArray(), 32)
        val yBytes = leftPadTo(w.affineY.toByteArray(), 32)
        return ByteArray(UNCOMPRESSED_POINT_LEN).also { out ->
            out[0] = 0x04
            System.arraycopy(xBytes, 0, out, 1, 32)
            System.arraycopy(yBytes, 0, out, 33, 32)
        }
    }

    fun ecdh(privateKey: java.security.PrivateKey, peerPublicKey: java.security.PublicKey): ByteArray {
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(privateKey)
        agreement.doPhase(peerPublicKey, true)
        return agreement.generateSecret()
    }

    fun generateEphemeralKeyPair(): java.security.KeyPair {
        val gen = java.security.KeyPairGenerator.getInstance("EC")
        gen.initialize(ECGenParameterSpec("secp256r1"), secureRandom)
        return gen.generateKeyPair()
    }

    private fun hkdfExtract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val saltKey = if (salt.isEmpty()) ByteArray(32) else salt
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(saltKey, "HmacSHA256"))
        return mac.doFinal(ikm)
    }

    private fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length <= 32 * 255) { "HKDF output too long" }
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val output = ByteArray(length)
        var previous = ByteArray(0)
        var generated = 0
        var counter = 1
        while (generated < length) {
            mac.reset()
            mac.update(previous)
            mac.update(info)
            mac.update(counter.toByte())
            previous = mac.doFinal()
            val toCopy = minOf(previous.size, length - generated)
            System.arraycopy(previous, 0, output, generated, toCopy)
            generated += toCopy
            counter += 1
        }
        return output
    }

    private fun leftPadTo(bytes: ByteArray, size: Int): ByteArray {
        if (bytes.size == size) return bytes
        if (bytes.size > size) return bytes.copyOfRange(bytes.size - size, bytes.size)
        val out = ByteArray(size)
        System.arraycopy(bytes, 0, out, size - bytes.size, bytes.size)
        return out
    }

    fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
}
