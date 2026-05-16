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
 * iOS / macOS `HermesRelayCrypto.swift` implementation, byte for byte:
 *
 *   - ECDH on NIST P-256 (`secp256r1`) for key-wrap key agreement.
 *   - HKDF-SHA256 over the shared secret with a `keyWrap` sharedInfo to
 *     derive the wrapping key.
 *   - A fresh AES-256 random symmetric key per request, wrapped with
 *     AES-256-GCM (12-byte IV, 16-byte tag) into
 *     `wrappedKey = base64( ephemeralPubKey(65) || sealedKey(48) )`.
 *   - Request body sealed with the same symmetric key under `requestAAD`,
 *     chunks under `chunkAAD`. AES.GCM `combined` shape (Apple
 *     CryptoKit) is `nonce(12) || ciphertext(N) || tag(16)`; matched here
 *     by always emitting `nonce + (cipherJce)` where the JCE
 *     `Cipher.doFinal` output already trails with the 16-byte tag.
 *   - X9.63 uncompressed public-key encoding (`0x04 || X || Y`, 65 bytes)
 *     for keys on the wire.
 *   - AAD strings (verbatim, no platform mutation):
 *       request: `OpenBurnBar-HermesRelay-v1|request|<uid>|<connectionId>|<requestId>`
 *       key:     `OpenBurnBar-HermesRelay-v1|key|<uid>|<connectionId>|<requestId>`
 *       chunk:   `OpenBurnBar-HermesRelay-v1|chunk|<uid>|<connectionId>|<requestId>|<sequence>|<kind>`
 *   - Key-wrap sharedInfo: `OpenBurnBar-HermesRelay-KeyWrap-v1|<keyAAD>`.
 *
 * A drift on any of these breaks Mac ⇄ Android decryption silently. The
 * `HermesRelayWireVectorTest` pins each constant against the iOS source.
 */
object HermesRelayCrypto {
    const val ALGORITHM = "p256-hkdf-sha256-aesgcm"
    const val KEY_VERSION = 1

    private const val AAD_PREFIX = "OpenBurnBar-HermesRelay-v1"
    private const val KEY_WRAP_SHARED_INFO_PREFIX = "OpenBurnBar-HermesRelay-KeyWrap-v1|"
    private const val GCM_TAG_BITS = 128
    private const val GCM_IV_BYTES = 12
    private const val AES_KEY_BYTES = 32
    private const val UNCOMPRESSED_POINT_LEN = 65

    private val secureRandom = SecureRandom()

    data class SealedEnvelope(val nonce: ByteArray, val ciphertext: ByteArray) {
        /** iOS `AES.GCM.sealed.combined` byte shape: `nonce || ciphertext || tag`. */
        fun combined(): ByteArray = nonce + ciphertext
    }

    // --- AAD strings (must match iOS verbatim) --------------------------

    fun requestAAD(uid: String, connectionId: String, requestId: String): ByteArray =
        aad(listOf("request", uid, connectionId, requestId))

    fun keyAAD(uid: String, connectionId: String, requestId: String): ByteArray =
        aad(listOf("key", uid, connectionId, requestId))

    fun chunkAAD(
        uid: String,
        connectionId: String,
        requestId: String,
        sequence: Int,
        kind: String,
    ): ByteArray = aad(listOf("chunk", uid, connectionId, requestId, sequence.toString(), kind))

    private fun aad(parts: List<String>): ByteArray =
        ("$AAD_PREFIX|" + parts.joinToString("|")).toByteArray(Charsets.UTF_8)

    // --- Symmetric key + payload AES-GCM --------------------------------

    fun generateSymmetricKey(): ByteArray = ByteArray(AES_KEY_BYTES).also(secureRandom::nextBytes)

    fun sealToBase64(plaintext: ByteArray, keyData: ByteArray, aad: ByteArray): String {
        require(keyData.size == AES_KEY_BYTES) { "symmetric key must be 32 bytes" }
        val nonce = ByteArray(GCM_IV_BYTES).also(secureRandom::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(keyData, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        val ciphertext = cipher.doFinal(plaintext)
        return base64NoWrap(nonce + ciphertext)
    }

    fun openBase64(ciphertext: String, keyData: ByteArray, aad: ByteArray): ByteArray {
        require(keyData.size == AES_KEY_BYTES) { "symmetric key must be 32 bytes" }
        val combined = base64Decode(ciphertext)
        require(combined.size > GCM_IV_BYTES) { "ciphertext too short" }
        val nonce = combined.copyOfRange(0, GCM_IV_BYTES)
        val body = combined.copyOfRange(GCM_IV_BYTES, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(keyData, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(body)
    }

    // --- Key wrap (ECIES-style envelope) --------------------------------

    /**
     * Wrap a symmetric key for `recipientPublicKey` (the relay's static
     * P-256 public key, X9.63 uncompressed). Produces
     * `base64( ephemeralPub(65) || sealedKey(48) )` exactly as iOS.
     */
    fun wrapSymmetricKey(keyData: ByteArray, recipientPublicKeyX963: ByteArray, aad: ByteArray): String {
        require(keyData.size == AES_KEY_BYTES) { "symmetric key must be 32 bytes" }
        val recipientKey = decodeUncompressedPublicKey(recipientPublicKeyX963)
        val ephemeralKeyPair = generateEphemeralKeyPair()
        val ephemeralPub = ephemeralKeyPair.public as java.security.interfaces.ECPublicKey
        val shared = ecdh(ephemeralKeyPair.private, recipientKey)
        val wrappingKey = hkdfDeriveSymmetricKey(
            sharedSecret = shared,
            sharedInfo = keyWrapSharedInfo(aad),
            length = AES_KEY_BYTES,
        )
        val nonce = ByteArray(GCM_IV_BYTES).also(secureRandom::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(wrappingKey, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        val sealed = cipher.doFinal(keyData)
        // iOS combined shape: nonce(12) || ciphertext(32) || tag(16).
        return base64NoWrap(encodeUncompressedPublicKey(ephemeralPub) + nonce + sealed)
    }

    /**
     * Inverse of [wrapSymmetricKey]. `privateKey` is the local static
     * P-256 private key paired with `recipientPublicKey` on the sender
     * side.
     */
    fun unwrapSymmetricKey(wrappedKeyBase64: String, privateKey: java.security.PrivateKey, aad: ByteArray): ByteArray {
        val envelope = base64Decode(wrappedKeyBase64)
        require(envelope.size > UNCOMPRESSED_POINT_LEN) { "wrapped key too short" }
        val ephemeralPubBytes = envelope.copyOfRange(0, UNCOMPRESSED_POINT_LEN)
        val sealed = envelope.copyOfRange(UNCOMPRESSED_POINT_LEN, envelope.size)
        require(sealed.size > GCM_IV_BYTES) { "wrapped key body too short" }
        val ephemeralPub = decodeUncompressedPublicKey(ephemeralPubBytes)
        val shared = ecdh(privateKey, ephemeralPub)
        val wrappingKey = hkdfDeriveSymmetricKey(
            sharedSecret = shared,
            sharedInfo = keyWrapSharedInfo(aad),
            length = AES_KEY_BYTES,
        )
        val nonce = sealed.copyOfRange(0, GCM_IV_BYTES)
        val body = sealed.copyOfRange(GCM_IV_BYTES, sealed.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(wrappingKey, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(body)
    }

    private fun keyWrapSharedInfo(aad: ByteArray): ByteArray =
        KEY_WRAP_SHARED_INFO_PREFIX.toByteArray(Charsets.UTF_8) + aad

    // --- Key encoding ---------------------------------------------------

    fun decodeUncompressedPublicKey(uncompressed: ByteArray): java.security.PublicKey {
        require(uncompressed.size == UNCOMPRESSED_POINT_LEN && uncompressed[0] == 0x04.toByte()) {
            "Expected 65-byte uncompressed P-256 point"
        }
        val spkiPrefix = byteArrayOf(
            0x30, 0x59,
            0x30, 0x13,
            0x06, 0x07, 0x2a.toByte(), 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a.toByte(), 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x03, 0x01, 0x07,
            0x03, 0x42, 0x00,
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

    // --- HKDF -----------------------------------------------------------

    /**
     * Equivalent of CryptoKit `SharedSecret.hkdfDerivedSymmetricKey` with
     * `salt = Data()` and the given `sharedInfo`. The Apple primitive
     * folds the shared secret through `HKDF<SHA256>` and returns a fresh
     * `SymmetricKey`. We mirror that with HKDF-extract → HKDF-expand and
     * truncate to `length`.
     */
    fun hkdfDeriveSymmetricKey(sharedSecret: ByteArray, sharedInfo: ByteArray, length: Int): ByteArray {
        val prk = hkdfExtract(salt = ByteArray(0), ikm = sharedSecret)
        return hkdfExpand(prk = prk, info = sharedInfo, length = length)
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

    // --- Base64 helpers (test-friendly) ---------------------------------
    //
    // Inside instrumented contexts we call `android.util.Base64`; inside
    // JVM unit tests `mockkStatic(android.util.Base64::class)` redirects
    // these to `java.util.Base64`. Both produce identical bytes.

    private fun base64NoWrap(bytes: ByteArray): String =
        android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)

    private fun base64Decode(text: String): ByteArray =
        android.util.Base64.decode(text, android.util.Base64.NO_WRAP)
}
