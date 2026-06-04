package com.openburnbar.data.hermes.relay

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

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
    const val GATEWAY_KEY_VERSION = 2

    fun requestAAD(uid: String, connectionId: String, requestId: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("request", uid, connectionId, requestId))

    fun keyAAD(uid: String, connectionId: String, requestId: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("key", uid, connectionId, requestId))

    fun chunkAAD(uid: String, connectionId: String, requestId: String, sequence: Int, kind: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("chunk", uid, connectionId, requestId, sequence.toString(), kind))

    fun gatewayEventAAD(uid: String, clientId: String, eventId: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("gatewayEvent", uid, clientId, eventId))

    fun gatewayEventKeyAAD(uid: String, clientId: String, eventId: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("gatewayEventKey", uid, clientId, eventId))

    fun gatewayMessageAAD(uid: String, clientId: String, messageId: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("gatewayMessage", uid, clientId, messageId))

    fun gatewayMessageKeyAAD(uid: String, clientId: String, messageId: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("gatewayMessageKey", uid, clientId, messageId))

    fun gatewayAttachmentKeyAAD(uid: String, clientId: String, attachmentId: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("gatewayAttachmentKey", uid, clientId, attachmentId))

    fun gatewayAttachmentManifestAAD(uid: String, clientId: String, attachmentId: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("gatewayAttachmentManifest", uid, clientId, attachmentId))

    fun gatewayAttachmentBodyAAD(uid: String, clientId: String, attachmentId: String): ByteArray =
        HermesRelayCryptoSupport.aad(listOf("gatewayAttachmentBody", uid, clientId, attachmentId))

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

    /** Sealed gateway message payload schema (MP-27): `{text, actionId?, kind?}`. */
    data class HermesGatewaySealedPayload(val text: String, val actionId: String?, val kind: String?)

    /**
     * Signal-style two-key pairing safety code (MP-1). SHA-256 over BOTH raw X9.63
     * relay public keys, sorted lexicographically by unsigned byte value so the Mac
     * and this device derive the IDENTICAL code without agreeing on roles, displayed
     * as the first 16 digest bytes (>=128 bits) in eight uppercase hex groups.
     * Byte-identical to the Swift/Python derivation.
     *
     * Hashing both keys closes the single-key MITM (a relay substituting the phone
     * key at first pin would otherwise still match an agent-only code); the 128-bit
     * width closes the ~2^64 grind on the displayed code.
     */
    fun gatewayRelaySafetyCode(agentPublicKeyX963: ByteArray, phonePublicKeyX963: ByteArray): String {
        val ordered = listOf(agentPublicKeyX963, phonePublicKeyX963)
            .sortedWith { a, b -> compareUnsignedLex(a, b) }
        val digest = sha256(ordered[0] + ordered[1])
        return (0 until 16 step 2).joinToString(" ") { i ->
            "%02X%02X".format(digest[i].toInt() and 0xFF, digest[i + 1].toInt() and 0xFF)
        }
    }

    private fun compareUnsignedLex(a: ByteArray, b: ByteArray): Int {
        val n = minOf(a.size, b.size)
        for (i in 0 until n) {
            val d = (a[i].toInt() and 0xFF) - (b[i].toInt() and 0xFF)
            if (d != 0) return d
        }
        return a.size - b.size
    }

    /**
     * Decode a sealed gateway message payload (MP-27). The agent seals JSON
     * `{text, actionId?, kind?}`; this decodes it (never rendering the raw bytes,
     * which would surface a literal `{"text":...}`). Throws if `text` is absent, so
     * a malformed sealed body is treated as unopenable rather than shown.
     */
    fun openGatewaySealedPayload(ciphertext: String, keyData: ByteArray, aad: ByteArray): HermesGatewaySealedPayload {
        val plain = openBase64(ciphertext, keyData, aad)
        val json = JSONObject(String(plain, Charsets.UTF_8))
        return HermesGatewaySealedPayload(
            text = json.getString("text"),
            actionId = if (json.has("actionId")) json.getString("actionId") else null,
            kind = if (json.has("kind")) json.getString("kind") else null,
        )
    }

    // ------------------------------------------------------------------
    // Relay key-wrap v3 — RFC 9180 HPKE Auth mode
    // (DHKEM(P-256, HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM).
    //
    // The standards-shaped successor to the v2 `wrapSymmetricKey(...,
    // senderPrivateKey)` 2-DH wrap. The engine lives in
    // `HermesRelayCryptoHpkeV3`; these are the base64 wire-envelope wrappers.
    // v1/v2 stay byte-unchanged and remain the advertised relay capability
    // until the shared canonical v3 vector lands (see the parity handoff).
    // ------------------------------------------------------------------

    /** relayKeyVersion for HPKE Auth v3 (== 3). */
    const val KEY_VERSION_V3 = HermesRelayCryptoHpkeV3.RELAY_KEY_VERSION

    /** relayEncryption marker for HPKE Auth v3. */
    const val ALGORITHM_V3 = HermesRelayCryptoHpkeV3.RELAY_ENCRYPTION

    /**
     * The v3 wire envelope as base64 fields: `enc` (HPKE encapsulated key),
     * `wrappedKey` (HPKE ciphertext over the 32-byte content key), and the
     * diagnostics-only `senderPublicKey`.
     */
    data class RelayKeyWrapV3Wire(val enc: String, val wrappedKey: String, val senderPublicKey: String)

    /**
     * Seal a 32-byte content key under RFC 9180 HPKE Auth (relayKeyVersion 3)
     * to [recipientPublicKeyX963], authenticated by the pinned
     * [senderPrivateKey]. [aad] MUST be the request `keyAAD`. Mirrors the Swift
     * / Python `seal_key_v3`.
     */
    fun wrapSymmetricKeyV3(
        keyData: ByteArray,
        recipientPublicKeyX963: ByteArray,
        senderPrivateKey: java.security.PrivateKey,
        aad: ByteArray,
    ): RelayKeyWrapV3Wire {
        val wrap =
            HermesRelayCryptoHpkeV3.sealKey(
                key = keyData,
                recipientPublicKeyX963 = recipientPublicKeyX963,
                senderPrivateKey = senderPrivateKey,
                aad = aad,
            )
        return RelayKeyWrapV3Wire(
            enc = HermesRelayCryptoSupport.base64NoWrap(wrap.enc),
            wrappedKey = HermesRelayCryptoSupport.base64NoWrap(wrap.wrappedKey),
            senderPublicKey = HermesRelayCryptoSupport.base64NoWrap(wrap.senderPublicKey),
        )
    }

    /**
     * Open a relayKeyVersion-3 envelope. Binds the **pinned**
     * [pinnedSenderPublicKeyX963] (NEVER the wire `senderPublicKey` field).
     * Throws `AEADBadTagException` on a forged sender / wrong recipient / wrong
     * aad / mutated `enc` or `wrappedKey`. Mirrors `open_key_v3`.
     */
    fun unwrapSymmetricKeyV3(
        encBase64: String,
        wrappedKeyBase64: String,
        privateKey: java.security.PrivateKey,
        pinnedSenderPublicKeyX963: ByteArray,
        aad: ByteArray,
    ): ByteArray =
        HermesRelayCryptoHpkeV3.openKey(
            enc = HermesRelayCryptoSupport.base64Decode(encBase64),
            wrappedKey = HermesRelayCryptoSupport.base64Decode(wrappedKeyBase64),
            recipientPrivateKey = privateKey,
            pinnedSenderPublicKeyX963 = pinnedSenderPublicKeyX963,
            aad = aad,
        )
}
