// Security-pinned E2EE/trust code under active remediation; behavior is pinned by tests and
// a P0 migration gate. Lint findings here are wire-format/defensive-coding by design -
package com.openburnbar.data.computeruse

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec

/**
 * F2 — P-256 wire-format helpers shared by the signing identity and the
 * verifier. The wire forms are byte-identical to the Swift CryptoKit and
 * Node `crypto` counterparts:
 *
 * - Public key: 65-byte X9.63 (`0x04‖X‖Y`) — `P256.Signing.PublicKey
 *   .x963Representation` in Swift; the canonical published controller key.
 * - Signature: raw `r‖s` 64-byte ECDSA-over-SHA256 —
 *   `ECDSASignature.rawRepresentation` in Swift, `dsaEncoding: 'ieee-p1363'`
 *   in Node. JCA emits/consumes ASN.1 DER, so both directions convert here.
 */
internal object PhoneControlP256 {
    private const val COORDINATE_BYTES = 32
    private const val RAW_SIGNATURE_BYTES = 64
    private const val X963_UNCOMPRESSED_BYTES = 65
    private const val X963_UNCOMPRESSED_PREFIX = 0x04.toByte()
    private const val DER_SEQUENCE_TAG = 0x30.toByte()
    private const val DER_INTEGER_TAG = 0x02.toByte()
    private const val DER_LONG_FORM_ONE_LENGTH_BYTE = 0x81.toByte()
    private const val DER_SHORT_FORM_MAX_LENGTH = 0x7F

    /** secp256r1 (NIST P-256) domain parameters, resolved through the platform JCA. */
    val curveParameters: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC")
            .apply { init(ECGenParameterSpec("secp256r1")) }
            .getParameterSpec(ECParameterSpec::class.java)
    }

    /** The 65-byte X9.63 (`0x04‖X‖Y`) encoding of a P-256 public key. */
    fun x963Representation(publicKey: ECPublicKey): ByteArray {
        val x = fixedLength(publicKey.w.affineX)
        val y = fixedLength(publicKey.w.affineY)
        return byteArrayOf(X963_UNCOMPRESSED_PREFIX) + x + y
    }

    /**
     * Build a P-256 public key from the published controller bytes: 65-byte
     * X9.63 (`0x04`-prefixed) — the StrongBox / Secure Enclave export — or
     * compact 64-byte raw (`X‖Y`). Mirrors the Swift
     * `PhoneControlVerifyingKey.p256PublicKey(from:)` normalization.
     */
    fun publicKeyFromRepresentation(bytes: ByteArray): ECPublicKey? {
        val coordinates =
            when {
                bytes.size == X963_UNCOMPRESSED_BYTES && bytes[0] == X963_UNCOMPRESSED_PREFIX ->
                    bytes.copyOfRange(1, X963_UNCOMPRESSED_BYTES)
                bytes.size == RAW_SIGNATURE_BYTES -> bytes
                else -> return null
            }
        val x = BigInteger(1, coordinates.copyOfRange(0, COORDINATE_BYTES))
        val y = BigInteger(1, coordinates.copyOfRange(COORDINATE_BYTES, 2 * COORDINATE_BYTES))
        return runCatching {
            val key =
                KeyFactory.getInstance("EC")
                    .generatePublic(ECPublicKeySpec(ECPoint(x, y), curveParameters))
            require(key is ECPublicKey) { "expected EC public key" }
            key
        }.getOrNull()
    }

    /**
     * Convert a JCA ASN.1 DER ECDSA signature (`SEQUENCE { INTEGER r, INTEGER s }`)
     * to the raw `r‖s` 64-byte wire form. DER integers are minimal-length
     * two's-complement — a leading `0x00` pad (high bit set) is dropped and
     * short integers (leading-zero coordinates) are left-padded back to 32 bytes.
     */
    fun derToRawSignature(der: ByteArray): ByteArray {
        require(der.size > 2 && der[0] == DER_SEQUENCE_TAG) { "ECDSA signature is not a DER sequence" }
        var index = 1
        index += derLengthByteCount(der, index)
        val (r, afterR) = readDerInteger(der, index)
        val (s, afterS) = readDerInteger(der, afterR)
        require(afterS == der.size) { "ECDSA DER signature has trailing bytes" }
        return fixedLength(r) + fixedLength(s)
    }

    /**
     * Convert a raw `r‖s` 64-byte signature to ASN.1 DER for JCA verification.
     */
    fun rawToDerSignature(raw: ByteArray): ByteArray {
        require(raw.size == RAW_SIGNATURE_BYTES) { "raw ECDSA signature must be 64 bytes" }
        val r = BigInteger(1, raw.copyOfRange(0, COORDINATE_BYTES))
        val s = BigInteger(1, raw.copyOfRange(COORDINATE_BYTES, RAW_SIGNATURE_BYTES))
        val rDer = derInteger(r)
        val sDer = derInteger(s)
        val body = rDer + sDer
        return byteArrayOf(DER_SEQUENCE_TAG) + derLength(body.size) + body
    }

    /**
     * Verify an ECDSA-over-SHA256 signature over `payload`. The raw `r‖s`
     * 64-byte wire form is the primary encoding; a DER signature is also
     * accepted so a stricter signer still interops (mirrors the Swift
     * `PhoneControlVerifyingKey.isValidSignature` dual acceptance).
     */
    fun verifySignature(publicKey: ECPublicKey, signature: ByteArray, payload: ByteArray): Boolean {
        if (signature.size == RAW_SIGNATURE_BYTES) {
            val der = runCatching { rawToDerSignature(signature) }.getOrNull()
            if (der != null && verifyDerSignature(publicKey, der, payload)) return true
        }
        return verifyDerSignature(publicKey, signature, payload)
    }

    private fun verifyDerSignature(publicKey: ECPublicKey, der: ByteArray, payload: ByteArray): Boolean =
        runCatching {
            Signature.getInstance(PhoneControlSigningIdentity.P256_JCA_SIGNATURE_ALGORITHM).run {
                initVerify(publicKey)
                update(payload)
                verify(der)
            }
        }.getOrDefault(false)

    private fun fixedLength(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        require(value.signum() >= 0) { "ECDSA component must be non-negative" }
        // Drop a sign pad byte, then left-pad with zeros to the coordinate width.
        val significant = bytes.dropWhile { it == 0.toByte() }
        require(significant.size <= COORDINATE_BYTES) { "ECDSA component exceeds 32 bytes" }
        return ByteArray(COORDINATE_BYTES - significant.size) + significant.toByteArray()
    }

    private fun derLengthByteCount(der: ByteArray, index: Int): Int {
        val first = der[index].toInt() and 0xFF
        return if (first <= DER_SHORT_FORM_MAX_LENGTH) 1 else 1 + (first and DER_SHORT_FORM_MAX_LENGTH)
    }

    private fun readDerInteger(der: ByteArray, start: Int): Pair<BigInteger, Int> {
        require(start + 2 <= der.size && der[start] == DER_INTEGER_TAG) { "expected DER INTEGER" }
        val length = der[start + 1].toInt() and 0xFF
        require(length <= DER_SHORT_FORM_MAX_LENGTH) { "oversized DER INTEGER in ECDSA signature" }
        val valueStart = start + 2
        val valueEnd = valueStart + length
        require(valueEnd <= der.size) { "truncated DER INTEGER" }
        return BigInteger(der.copyOfRange(valueStart, valueEnd)) to valueEnd
    }

    private fun derInteger(value: BigInteger): ByteArray {
        // BigInteger.toByteArray() is minimal two's complement — exactly DER.
        val body = value.toByteArray()
        return byteArrayOf(DER_INTEGER_TAG, body.size.toByte()) + body
    }

    private fun derLength(length: Int): ByteArray =
        if (length <= DER_SHORT_FORM_MAX_LENGTH) {
            byteArrayOf(length.toByte())
        } else {
            byteArrayOf(DER_LONG_FORM_ONE_LENGTH_BYTE, length.toByte())
        }
}
