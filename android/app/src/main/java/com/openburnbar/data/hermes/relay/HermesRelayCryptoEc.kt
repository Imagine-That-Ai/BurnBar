package com.openburnbar.data.hermes.relay

import java.security.KeyFactory
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.KeyAgreement

internal object HermesRelayCryptoEc {
    private const val UNCOMPRESSED_POINT_PREFIX = 0x04
    private const val P256_COORDINATE_BYTES = 32
    private const val P256_Y_COORDINATE_OFFSET = 33
    const val UNCOMPRESSED_POINT_LEN = 65

    /**
     * DER prefix of an X.509 SubjectPublicKeyInfo for a P-256 public key
     * (RFC 5480); the 65-byte X9.63 uncompressed point is appended directly
     * after it before handing the result to `KeyFactory`.
     */
    private val P256_SPKI_PREFIX: ByteArray =
        byteArrayOf(
            // SEQUENCE, 89 bytes: SubjectPublicKeyInfo
            0x30, 0x59,
            // SEQUENCE, 19 bytes: AlgorithmIdentifier
            0x30, 0x13,
            // OID 1.2.840.10045.2.1 (id-ecPublicKey)
            0x06, 0x07, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x02, 0x01,
            // OID 1.2.840.10045.3.1.7 (prime256v1)
            0x06, 0x08, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x03, 0x01, 0x07,
            // BIT STRING, 66 bytes; leading 0x00 = no unused bits
            0x03, 0x42, 0x00,
        )

    private val secureRandom = SecureRandom()

    private val BIG_TWO: java.math.BigInteger = java.math.BigInteger.valueOf(2)
    private val BIG_THREE: java.math.BigInteger = java.math.BigInteger.valueOf(3)

    fun decodeUncompressedPublicKey(uncompressed: ByteArray): java.security.PublicKey {
        require(uncompressed.size == UNCOMPRESSED_POINT_LEN && uncompressed[0] == 0x04.toByte()) {
            "Expected 65-byte uncompressed P-256 point"
        }
        val encoded = P256_SPKI_PREFIX + uncompressed
        return KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(encoded))
    }

    fun encodeUncompressedPublicKey(publicKey: java.security.interfaces.ECPublicKey): ByteArray {
        val w = publicKey.w
        val xBytes = HermesRelayCryptoHkdf.leftPadTo(w.affineX.toByteArray(), P256_COORDINATE_BYTES)
        val yBytes = HermesRelayCryptoHkdf.leftPadTo(w.affineY.toByteArray(), P256_COORDINATE_BYTES)
        return ByteArray(UNCOMPRESSED_POINT_LEN).also { out ->
            out[0] = UNCOMPRESSED_POINT_PREFIX.toByte()
            System.arraycopy(xBytes, 0, out, 1, P256_COORDINATE_BYTES)
            System.arraycopy(yBytes, 0, out, P256_Y_COORDINATE_OFFSET, P256_COORDINATE_BYTES)
        }
    }

    fun ecdh(privateKey: java.security.PrivateKey, peerPublicKey: java.security.PublicKey): ByteArray {
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(privateKey)
        agreement.doPhase(peerPublicKey, true)
        return agreement.generateSecret()
    }

    /**
     * Recover the raw 65-byte X9.63 uncompressed public key (`0x04 ‖ X ‖ Y`)
     * for a P-256 private key. Mirrors Swift's `privateKey.publicKey.x963Representation`,
     * which v2 binds into the `info` (kem_context). Computes `Q = d·G` from the
     * private scalar over `secp256r1` so it works for a key reconstructed from a
     * bare scalar (which carries no public point of its own).
     */
    fun publicKeyX963FromPrivateKey(privateKey: java.security.PrivateKey): ByteArray {
        val ecPrivate =
            privateKey as? java.security.interfaces.ECPrivateKey
                ?: error("Hermes relay v2 requires an EC private key")
        val params = ecPrivate.params
        val q = ecPointMultiply(params.generator, ecPrivate.s, params)
        val kf = KeyFactory.getInstance("EC")
        val publicKey =
            kf.generatePublic(java.security.spec.ECPublicKeySpec(q, params))
                as? java.security.interfaces.ECPublicKey
                ?: error("Hermes relay v2 derived a non-EC public key")
        return encodeUncompressedPublicKey(publicKey)
    }

    /**
     * Scalar multiplication `k·P` on the curve described by [params] using the
     * Jacobian-coordinate double-and-add ladder over the prime field. P-256 has
     * curve coefficient `a = p − 3`, which the formulas below assume.
     */
    private fun ecPointMultiply(
        point: java.security.spec.ECPoint,
        k: java.math.BigInteger,
        params: java.security.spec.ECParameterSpec,
    ): java.security.spec.ECPoint {
        val field =
            params.curve.field as? java.security.spec.ECFieldFp
                ?: error("Hermes relay v2 requires a prime-field EC curve")
        val p = field.p
        var result: java.security.spec.ECPoint? = null
        var addend = point
        var n = k
        while (n.signum() > 0) {
            if (n.testBit(0)) {
                result = ecPointAdd(result, addend, p)
            }
            addend = ecPointAdd(addend, addend, p)
            n = n.shiftRight(1)
        }
        return result ?: java.security.spec.ECPoint.POINT_INFINITY
    }

    private fun ecPointAdd(a: java.security.spec.ECPoint?, b: java.security.spec.ECPoint, p: java.math.BigInteger): java.security.spec.ECPoint {
        if (a == null || a == java.security.spec.ECPoint.POINT_INFINITY) return b
        if (b == java.security.spec.ECPoint.POINT_INFINITY) return a
        val two = BIG_TWO
        val three = BIG_THREE
        val lambda: java.math.BigInteger
        if (a.affineX == b.affineX) {
            if ((a.affineY + b.affineY).mod(p).signum() == 0) {
                return java.security.spec.ECPoint.POINT_INFINITY
            }
            // Doubling slope: (3·x² + a) / (2·y); for P-256, a = p − 3.
            val curveA = p - three
            val numerator = (three * a.affineX.modPow(two, p) + curveA).mod(p)
            val denominator = (two * a.affineY).modInverse(p)
            lambda = (numerator * denominator).mod(p)
        } else {
            val numerator = (b.affineY - a.affineY).mod(p)
            val denominator = (b.affineX - a.affineX).mod(p).modInverse(p)
            lambda = (numerator * denominator).mod(p)
        }
        val x3 = (lambda.modPow(two, p) - a.affineX - b.affineX).mod(p)
        val y3 = (lambda * (a.affineX - x3) - a.affineY).mod(p)
        return java.security.spec.ECPoint(x3, y3)
    }

    fun generateEphemeralKeyPair(): java.security.KeyPair {
        val gen = java.security.KeyPairGenerator.getInstance("EC")
        gen.initialize(ECGenParameterSpec("secp256r1"), secureRandom)
        return gen.generateKeyPair()
    }
}
