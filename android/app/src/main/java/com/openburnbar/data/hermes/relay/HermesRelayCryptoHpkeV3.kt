package com.openburnbar.data.hermes.relay

import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * RFC 9180 HPKE **Auth mode** relay key-wrap — relay key-wrap **v3**.
 *
 * The standards-shaped successor to the bespoke v2 authenticated 2-DH wrap
 * (`HermesRelayCrypto.wrapSymmetricKey(..., senderPrivateKey = ...)`). It wraps
 * the 32-byte relay content key under the canonical suite:
 *
 * ```
 * Mode: Auth                          (mode_auth = 0x02)
 * KEM:  DHKEM(P-256, HKDF-SHA256)     (kem_id    = 0x0010)
 * KDF:  HKDF-SHA256                   (kdf_id    = 0x0001)
 * AEAD: AES-256-GCM                   (aead_id   = 0x0002)
 * ```
 *
 * Wire markers: `relayKeyVersion = 3`,
 * `relayEncryption = "hpke-auth-p256-hkdfsha256-aes256gcm"`.
 *
 * HPKE context: `info = "OpenBurnBar-HermesRelay-HPKE-v3|" ‖ key_aad`,
 * `aad = key_aad`, `pt = 32-byte content key`,
 * `ct = HPKE Auth single-shot Seal(pt, aad)` (seq 0 ⇒ nonce = base_nonce).
 *
 * Byte-for-byte interoperable with the Python (`gateway/crypto/relay_e2ee.py`)
 * and Swift (`HermesRelayCrypto.swift`) v3 ports: all three implement the SAME
 * RFC 9180 schedule, labels, P-256 X9.63 point encoding, `info`, and AAD, so
 * interop is guaranteed by the standard rather than by a bespoke KEM. The
 * shared interop gate is the v3 wire vector (`HermesGatewayWireVectorV3.json`,
 * owned by the vector lane) that all three open.
 *
 * **Sender authentication** is HPKE Auth mode: the recipient binds the
 * **pinned** sender static key (never a wire-supplied `senderPublicKey`) into
 * `AuthDecap`, so a forged/swapped sender both changes the second DH leg and
 * the `kem_context`, fails to derive the same shared secret, and the AES-256-GCM
 * `open` raises `AEADBadTagException`. The envelope `senderPublicKey` field is
 * diagnostics-only and is NEVER used as the authenticated sender key.
 *
 * The crypto is hand-rolled on the JCE primitives already used by v1/v2
 * (`HermesRelayCryptoEc` ECDH + X9.63 point coding, `HermesRelayCryptoHkdf`
 * HKDF-SHA256 extract/expand, JCE `AES/GCM/NoPadding`) so v3 ships with **zero**
 * new dependencies and stays byte-controllable for cross-language parity — the
 * same trade Python (`cryptography`) makes. KEM/KCI/metadata limits are the
 * inherent RFC 9180 `AuthDecap` bounds documented for v2 and unchanged here.
 */
internal object HermesRelayCryptoHpkeV3 {
    const val RELAY_KEY_VERSION = 3
    const val RELAY_ENCRYPTION = "hpke-auth-p256-hkdfsha256-aes256gcm"

    /** `info = INFO_PREFIX ‖ key_aad`. Hard domain separation from v1/v2. */
    const val INFO_PREFIX = "OpenBurnBar-HermesRelay-HPKE-v3|"

    // RFC 9180 §7.1 algorithm identifiers.
    private const val KEM_ID = 0x0010 // DHKEM(P-256, HKDF-SHA256)
    private const val KDF_ID = 0x0001 // HKDF-SHA256
    private const val AEAD_ID = 0x0002 // AES-256-GCM
    private const val MODE_AUTH: Byte = 0x02

    // RFC 9180 §5.1 / §7.1 lengths.
    private const val NSECRET = 32 // DHKEM(P-256) shared-secret length
    private const val NK = 32 // AES-256 key length
    private const val NN = 12 // AES-GCM nonce length
    private const val DH_LEN = 32 // P-256 ECDH raw X length
    private const val CONTENT_KEY_BYTES = 32
    private const val GCM_TAG_BITS = 128

    private const val BYTE_BITS = 8
    private const val BYTE_MASK = 0xFF

    // RFC 9180 §4 labeled-KDF framing. The KEM derivations use the KEM suite id;
    // the key schedule uses the full HPKE suite id (which binds the AEAD), giving
    // v3 its domain separation from any other suite.
    private val HPKE_V1 = "HPKE-v1".toByteArray(Charsets.US_ASCII)
    private val KEM_SUITE_ID = "KEM".toByteArray(Charsets.US_ASCII) + i2osp2(KEM_ID)
    private val HPKE_SUITE_ID =
        "HPKE".toByteArray(Charsets.US_ASCII) + i2osp2(KEM_ID) + i2osp2(KDF_ID) + i2osp2(AEAD_ID)

    /**
     * A v3 key-wrap envelope (raw bytes). [enc] is the 65-byte X9.63 HPKE
     * encapsulated key, [wrappedKey] is the 48-byte HPKE ciphertext over the
     * 32-byte content key (32 ‖ 16-byte tag), [senderPublicKey] is the 65-byte
     * X9.63 sender public key carried for diagnostics only.
     */
    class RelayKeyWrapV3(
        val enc: ByteArray,
        val wrappedKey: ByteArray,
        val senderPublicKey: ByteArray,
    )

    /**
     * HPKE Auth seal of [key] (the 32-byte content key) to
     * [recipientPublicKeyX963], authenticated by [senderPrivateKey]. [aad] MUST
     * be the request `keyAAD`. Mirrors Python `seal_key_v3`.
     */
    fun sealKey(
        key: ByteArray,
        recipientPublicKeyX963: ByteArray,
        senderPrivateKey: java.security.PrivateKey,
        aad: ByteArray,
    ): RelayKeyWrapV3 {
        require(key.size == CONTENT_KEY_BYTES) { "content key must be 32 bytes" }
        val (sharedSecret, enc) = authEncap(recipientPublicKeyX963, senderPrivateKey)
        val (hpkeKey, baseNonce) = keySchedule(sharedSecret, info(aad))
        val wrappedKey = aeadSeal(hpkeKey, baseNonce, aad, key)
        val senderPublicKey = HermesRelayCryptoEc.publicKeyX963FromPrivateKey(senderPrivateKey)
        return RelayKeyWrapV3(enc = enc, wrappedKey = wrappedKey, senderPublicKey = senderPublicKey)
    }

    /**
     * HPKE Auth open. Binds the **pinned** [pinnedSenderPublicKeyX963] (never a
     * wire field). Mirrors Python `open_key_v3`. Throws `AEADBadTagException` on
     * a wrong sender / recipient / aad / mutated `enc` / mutated `wrappedKey`,
     * and a point-decode exception if [enc] or the pinned sender key is not a
     * valid P-256 point.
     */
    fun openKey(
        enc: ByteArray,
        wrappedKey: ByteArray,
        recipientPrivateKey: java.security.PrivateKey,
        pinnedSenderPublicKeyX963: ByteArray,
        aad: ByteArray,
    ): ByteArray {
        val sharedSecret = authDecap(enc, recipientPrivateKey, pinnedSenderPublicKeyX963)
        val (hpkeKey, baseNonce) = keySchedule(sharedSecret, info(aad))
        return aeadOpen(hpkeKey, baseNonce, aad, wrappedKey)
    }

    private fun info(aad: ByteArray): ByteArray = INFO_PREFIX.toByteArray(Charsets.UTF_8) + aad

    // --- RFC 9180 §4.1 DHKEM(P-256, HKDF-SHA256) Auth mode ---

    /** AuthEncap(pkR, skS) → (shared_secret, enc). Internal for known-answer tests. */
    internal fun authEncap(
        recipientPublicKeyX963: ByteArray,
        senderPrivateKey: java.security.PrivateKey,
    ): Pair<ByteArray, ByteArray> {
        val recipient = HermesRelayCryptoEc.decodeUncompressedPublicKey(recipientPublicKeyX963)
        val ephemeral = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val ephemeralPublic =
            ephemeral.public as? java.security.interfaces.ECPublicKey
                ?: error("HPKE v3 ephemeral keypair must use an EC public key")
        val enc = HermesRelayCryptoEc.encodeUncompressedPublicKey(ephemeralPublic)
        val dh = dh(ephemeral.private, recipient) + dh(senderPrivateKey, recipient)
        val pkRm = serializePublicKey(recipient)
        val pkSm = HermesRelayCryptoEc.publicKeyX963FromPrivateKey(senderPrivateKey)
        return extractAndExpand(dh, enc + pkRm + pkSm) to enc
    }

    /** AuthDecap(enc, skR, pkS) → shared_secret. Internal for known-answer tests. */
    internal fun authDecap(
        enc: ByteArray,
        recipientPrivateKey: java.security.PrivateKey,
        senderPublicKeyX963: ByteArray,
    ): ByteArray {
        val ephemeralPublic = HermesRelayCryptoEc.decodeUncompressedPublicKey(enc)
        val senderPublic = HermesRelayCryptoEc.decodeUncompressedPublicKey(senderPublicKeyX963)
        val dh = dh(recipientPrivateKey, ephemeralPublic) + dh(recipientPrivateKey, senderPublic)
        val pkRm = HermesRelayCryptoEc.publicKeyX963FromPrivateKey(recipientPrivateKey)
        val pkSm = serializePublicKey(senderPublic)
        // kem_context binds the WIRE enc bytes (a mutated enc fails the open).
        return extractAndExpand(dh, enc + pkRm + pkSm)
    }

    /** P-256 DH = raw 32-byte big-endian X coordinate, left-padded (RFC 9180 §7.1.1). */
    private fun dh(privateKey: java.security.PrivateKey, peer: java.security.PublicKey): ByteArray =
        HermesRelayCryptoHkdf.leftPadTo(HermesRelayCryptoEc.ecdh(privateKey, peer), DH_LEN)

    private fun serializePublicKey(publicKey: java.security.PublicKey): ByteArray =
        HermesRelayCryptoEc.encodeUncompressedPublicKey(publicKey as java.security.interfaces.ECPublicKey)

    private fun extractAndExpand(dh: ByteArray, kemContext: ByteArray): ByteArray {
        val eaePrk = labeledExtract(KEM_SUITE_ID, ByteArray(0), "eae_prk", dh)
        return labeledExpand(KEM_SUITE_ID, eaePrk, "shared_secret", kemContext, NSECRET)
    }

    // --- RFC 9180 §5.1 KeySchedule (mode_auth, empty PSK) ---

    private fun keySchedule(sharedSecret: ByteArray, info: ByteArray): Pair<ByteArray, ByteArray> {
        val empty = ByteArray(0)
        val pskIdHash = labeledExtract(HPKE_SUITE_ID, empty, "psk_id_hash", empty)
        val infoHash = labeledExtract(HPKE_SUITE_ID, empty, "info_hash", info)
        val keyScheduleContext = byteArrayOf(MODE_AUTH) + pskIdHash + infoHash
        val secret = labeledExtract(HPKE_SUITE_ID, sharedSecret, "secret", empty)
        val key = labeledExpand(HPKE_SUITE_ID, secret, "key", keyScheduleContext, NK)
        val baseNonce = labeledExpand(HPKE_SUITE_ID, secret, "base_nonce", keyScheduleContext, NN)
        return key to baseNonce
    }

    // --- RFC 9180 §4 labeled KDF (over HermesRelayCryptoHkdf's RFC 5869 core) ---

    private fun labeledExtract(suiteId: ByteArray, salt: ByteArray, label: String, ikm: ByteArray): ByteArray =
        HermesRelayCryptoHkdf.hkdfExtract(
            salt = salt,
            ikm = HPKE_V1 + suiteId + label.toByteArray(Charsets.US_ASCII) + ikm,
        )

    private fun labeledExpand(
        suiteId: ByteArray,
        prk: ByteArray,
        label: String,
        info: ByteArray,
        length: Int,
    ): ByteArray =
        HermesRelayCryptoHkdf.hkdfExpand(
            prk = prk,
            info = i2osp2(length) + HPKE_V1 + suiteId + label.toByteArray(Charsets.US_ASCII) + info,
            length = length,
        )

    // --- single-shot AEAD (sequence 0 ⇒ nonce = base_nonce) ---

    private fun aeadSeal(key: ByteArray, baseNonce: ByteArray, aad: ByteArray, plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_TAG_BITS, baseNonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(plaintext)
    }

    private fun aeadOpen(key: ByteArray, baseNonce: ByteArray, aad: ByteArray, ciphertext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_TAG_BITS, baseNonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(ciphertext)
    }

    /** I2OSP(value, 2) — two-byte big-endian length (RFC 9180 notation). */
    private fun i2osp2(value: Int): ByteArray =
        byteArrayOf(((value ushr BYTE_BITS) and BYTE_MASK).toByte(), (value and BYTE_MASK).toByte())
}
