package com.openburnbar.data.computeruse

import com.google.crypto.tink.subtle.Ed25519Sign
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.util.Base64

/**
 * F2 — signing key custody class. Android mirror of the Swift
 * `PhoneControlSigningKeyKind` (`HermesRealtimeRelayTypes.swift`) and the
 * server's `parsePhoneControlSigningKeyKind`
 * (`functions/src/callables/computerUseSecurity.ts`).
 *
 * `ED25519` is the legacy software Tink key; `SECURE_ENCLAVE_P256` is a
 * non-exportable NIST P-256 key held in the StrongBox / TEE Android Keystore
 * (Secure Enclave on iOS). An absent wire value resolves to the legacy
 * default so pre-F2 envelopes keep verifying unchanged.
 */
enum class PhoneControlSigningKeyKind(val wireValue: String) {
    ED25519("ed25519"),
    SECURE_ENCLAVE_P256("se-p256"),
    ;

    companion object {
        /** Every controller paired before F2 signs with the software Ed25519 key. */
        val LEGACY_DEFAULT: PhoneControlSigningKeyKind = ED25519

        /**
         * Resolve a wire `keyKind` discriminator. `null`/empty resolves to the
         * legacy default; an unknown value returns `null` so callers fail closed.
         */
        fun fromWire(raw: String?): PhoneControlSigningKeyKind? = when (raw) {
            null, "", ED25519.wireValue -> ED25519
            SECURE_ENCLAVE_P256.wireValue -> SECURE_ENCLAVE_P256
            else -> null
        }
    }
}

/**
 * F2 — key-kind-aware signing identity: the Android mirror of the Swift
 * `PhoneControlAuthoritySigningKey` (`PhoneControlAuthoritySigningKey.swift`).
 * The sender holds one of these and every envelope-producing path signs
 * through it, so key custody (software Ed25519 vs. StrongBox/TEE P-256) is a
 * property of the stored identity rather than of each call site.
 */
sealed class PhoneControlSigningIdentity {
    /** Legacy software Ed25519 key (32-byte Tink seed). Wire-identical to pre-F2. */
    class Ed25519(val privateKeySeed: ByteArray) : PhoneControlSigningIdentity() {
        init {
            require(privateKeySeed.size == ED25519_SEED_BYTES) { "Ed25519 private key seed must be 32 bytes" }
        }
    }

    /**
     * A NIST P-256 key — an opaque AndroidKeyStore (StrongBox/TEE) handle on
     * device, a plain software `KeyPairGenerator("EC")` key in unit tests.
     * Both sign through JCA `SHA256withECDSA`; the DER output is converted to
     * the raw `r‖s` 64-byte wire form (Swift `signature.rawRepresentation`,
     * Node `dsaEncoding: 'ieee-p1363'`).
     */
    class SecureEnclaveP256(
        val privateKey: PrivateKey,
        val publicKey: ECPublicKey,
    ) : PhoneControlSigningIdentity()

    val kind: PhoneControlSigningKeyKind
        get() = when (this) {
            is Ed25519 -> PhoneControlSigningKeyKind.ED25519
            is SecureEnclaveP256 -> PhoneControlSigningKeyKind.SECURE_ENCLAVE_P256
        }

    /**
     * The canonical published bytes — what `publishPhoneControlAuthority`
     * uploads as `publicKeyBase64` and what every `peerNodeId` derivation
     * hashes: 32-byte raw for Ed25519, 65-byte X9.63 (`0x04‖X‖Y`) for SE-P256.
     */
    val publicKeyRepresentation: ByteArray
        get() = when (this) {
            is Ed25519 -> PhoneControlSigner.publicKey(privateKeySeed)
            is SecureEnclaveP256 -> PhoneControlP256.x963Representation(publicKey)
        }

    /**
     * The `keyKind` to put on the wire for envelopes this identity signs:
     * `null` for legacy Ed25519 so pre-F2 envelopes stay byte-identical
     * (receivers resolve absence to `ed25519`), the explicit kind otherwise.
     */
    val wireKeyKind: String?
        get() = if (kind == PhoneControlSigningKeyKind.ED25519) null else kind.wireValue

    /**
     * Sign `payload`, returning the base64 wire signature: raw 64-byte
     * Ed25519, or raw (`r‖s`) 64-byte ECDSA-over-SHA256 for P-256 — the two
     * forms `PhoneControlSignerVerify` accepts.
     */
    fun signatureBase64(payload: ByteArray): String = when (this) {
        is Ed25519 -> Base64.getEncoder().encodeToString(Ed25519Sign(privateKeySeed).sign(payload))
        is SecureEnclaveP256 -> {
            val der =
                Signature.getInstance(P256_JCA_SIGNATURE_ALGORITHM).run {
                    initSign(privateKey)
                    update(payload)
                    sign()
                }
            Base64.getEncoder().encodeToString(PhoneControlP256.derToRawSignature(der))
        }
    }

    companion object {
        private const val ED25519_SEED_BYTES = 32
        internal const val P256_JCA_SIGNATURE_ALGORITHM = "SHA256withECDSA"
    }
}
