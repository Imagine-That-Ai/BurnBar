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

    /**
     * Wrap a 32-byte symmetric key for [recipientPublicKeyX963].
     *
     * When [senderPrivateKey] is `null` this is the **v1** ephemeral-static
     * ECIES wrap — byte-identical to the realtime relay path (`ikm = dh1`,
     * `info = "…KeyWrap-v1|" ‖ aad`). Do not change that leg.
     *
     * When [senderPrivateKey] is provided this is the **v2 authenticated**
     * wrap (HPKE-AuthEncap-shaped 2-DH KEM): `ikm = ECDH(eph, R) ‖ ECDH(skS, R)`
     * (concat, `dh1` first — never XOR), one HKDF-SHA256 over the v2 `info`
     * binding `enc ‖ pkR ‖ pkS`. The wire layout is unchanged from v1.
     */
    fun wrapSymmetricKey(
        keyData: ByteArray,
        recipientPublicKeyX963: ByteArray,
        aad: ByteArray,
        senderPrivateKey: java.security.PrivateKey? = null,
    ): String {
        require(keyData.size == AES_KEY_BYTES) { "symmetric key must be 32 bytes" }
        val recipientKey = HermesRelayCryptoEc.decodeUncompressedPublicKey(recipientPublicKeyX963)
        val ephemeralKeyPair = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val ephemeralPub =
            ephemeralKeyPair.public as? java.security.interfaces.ECPublicKey
                ?: error("Hermes relay ephemeral keypair must use an EC public key")
        val enc = HermesRelayCryptoEc.encodeUncompressedPublicKey(ephemeralPub)
        val dh1 = HermesRelayCryptoEc.ecdh(ephemeralKeyPair.private, recipientKey)
        val wrappingKey =
            if (senderPrivateKey != null) {
                // v2 authenticated: ikm = ECDH(eph, R) ‖ ECDH(skS, R).
                val dh2 = HermesRelayCryptoEc.ecdh(senderPrivateKey, recipientKey)
                val senderPubX963 = HermesRelayCryptoEc.publicKeyX963FromPrivateKey(senderPrivateKey)
                HermesRelayCryptoHkdf.hkdfDeriveSymmetricKey(
                    sharedSecret = dh1 + dh2,
                    sharedInfo =
                        HermesRelayCryptoSupport.keyWrapSharedInfoV2(
                            aad = aad,
                            enc = enc,
                            pkR = recipientPublicKeyX963,
                            pkS = senderPubX963,
                        ),
                    length = AES_KEY_BYTES,
                )
            } else {
                HermesRelayCryptoHkdf.hkdfDeriveSymmetricKey(
                    sharedSecret = dh1,
                    sharedInfo = HermesRelayCryptoSupport.keyWrapSharedInfo(aad),
                    length = AES_KEY_BYTES,
                )
            }
        val nonce = ByteArray(GCM_IV_BYTES).also(secureRandom::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(wrappingKey, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        val sealed = cipher.doFinal(keyData)
        return HermesRelayCryptoSupport.base64NoWrap(enc + nonce + sealed)
    }

    /**
     * Unwrap a symmetric key.
     *
     * When [senderPublicKeyX963] is `null` this is the **v1** path. When
     * provided it is the **v2 authenticated** unwrap: the recipient binds the
     * *pinned* sender static key (NOT a wire-supplied field) into the second DH,
     * so a swapped/forged sender key fails AES-GCM tag verification — the forge
     * defense. The pinned recipient public key is recovered from [privateKey]
     * (`Q = d·G`) so it byte-matches the seal-side `info`.
     */
    fun unwrapSymmetricKey(
        wrappedKeyBase64: String,
        privateKey: java.security.PrivateKey,
        aad: ByteArray,
        senderPublicKeyX963: ByteArray? = null,
    ): ByteArray {
        val envelope = HermesRelayCryptoSupport.base64Decode(wrappedKeyBase64)
        require(envelope.size > HermesRelayCryptoEc.UNCOMPRESSED_POINT_LEN) { "wrapped key too short" }
        val ephemeralPubBytes = envelope.copyOfRange(0, HermesRelayCryptoEc.UNCOMPRESSED_POINT_LEN)
        val sealed = envelope.copyOfRange(HermesRelayCryptoEc.UNCOMPRESSED_POINT_LEN, envelope.size)
        require(sealed.size > GCM_IV_BYTES) { "wrapped key body too short" }
        val ephemeralPub = HermesRelayCryptoEc.decodeUncompressedPublicKey(ephemeralPubBytes)
        val dh1 = HermesRelayCryptoEc.ecdh(privateKey, ephemeralPub)
        val wrappingKey =
            if (senderPublicKeyX963 != null) {
                // v2 authenticated: ikm = ECDH(r, eph) ‖ ECDH(r, S_pinned).
                val senderKey = HermesRelayCryptoEc.decodeUncompressedPublicKey(senderPublicKeyX963)
                val dh2 = HermesRelayCryptoEc.ecdh(privateKey, senderKey)
                val recipientOwnPubX963 = HermesRelayCryptoEc.publicKeyX963FromPrivateKey(privateKey)
                HermesRelayCryptoHkdf.hkdfDeriveSymmetricKey(
                    sharedSecret = dh1 + dh2,
                    sharedInfo =
                        HermesRelayCryptoSupport.keyWrapSharedInfoV2(
                            aad = aad,
                            enc = ephemeralPubBytes,
                            pkR = recipientOwnPubX963,
                            pkS = senderPublicKeyX963,
                        ),
                    length = AES_KEY_BYTES,
                )
            } else {
                HermesRelayCryptoHkdf.hkdfDeriveSymmetricKey(
                    sharedSecret = dh1,
                    sharedInfo = HermesRelayCryptoSupport.keyWrapSharedInfo(aad),
                    length = AES_KEY_BYTES,
                )
            }
        val nonce = sealed.copyOfRange(0, GCM_IV_BYTES)
        val body = sealed.copyOfRange(GCM_IV_BYTES, sealed.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(wrappingKey, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(body)
    }

    fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
}
