package com.openburnbar.data.hermes.relay

import java.security.KeyFactory
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.KeyAgreement

internal object HermesRelayCryptoEc {
    private const val BITS_PER_BYTE = 0x08
    private const val UNCOMPRESSED_POINT_PREFIX = 0x04
    private const val VAL_0X03 = 0x03
    private const val VAL_0X06 = 0x06
    private const val VAL_0X07 = 0x07
    private const val VAL_0X13 = 0x13
    private const val VAL_0X30 = 0x30
    private const val VAL_0X42 = 0x42
    private const val VAL_0X48 = 0x48
    private const val VAL_0X59 = 0x59
    private const val VAL_0X2A = 0x2a
    private const val VAL_0X3D = 0x3d
    private const val VAL_0X86 = 0x86
    private const val VAL_0XCE = 0xce
    private const val P256_COORDINATE_BYTES = 32
    private const val P256_Y_COORDINATE_OFFSET = 33
    const val UNCOMPRESSED_POINT_LEN = 65

    private val secureRandom = SecureRandom()

    fun decodeUncompressedPublicKey(uncompressed: ByteArray): java.security.PublicKey {
        require(uncompressed.size == UNCOMPRESSED_POINT_LEN && uncompressed[0] == 0x04.toByte()) {
            "Expected 65-byte uncompressed P-256 point"
        }
        val spkiPrefix =
            byteArrayOf(
                VAL_0X30, VAL_0X59,
                VAL_0X30, VAL_0X13,
                VAL_0X06, VAL_0X07, VAL_0X2A.toByte(), VAL_0X86.toByte(), VAL_0X48, VAL_0XCE.toByte(), VAL_0X3D, VAL_0X02, VAL_0X01,
                VAL_0X06, BITS_PER_BYTE, VAL_0X2A.toByte(), VAL_0X86.toByte(), VAL_0X48, VAL_0XCE.toByte(), VAL_0X3D, VAL_0X03, VAL_0X01, VAL_0X07,
                VAL_0X03, VAL_0X42, VAL_0X00,
            )
        val encoded = spkiPrefix + uncompressed
        return KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(encoded))
    }

    fun encodeUncompressedPublicKey(publicKey: java.security.interfaces.ECPublicKey): ByteArray {
        val w = publicKey.w
        val xBytes = HermesRelayCryptoHkdf.leftPadTo(w.affineX.toByteArray(), P256_COORDINATE_BYTES)
        val yBytes = HermesRelayCryptoHkdf.leftPadTo(w.affineY.toByteArray(), P256_COORDINATE_BYTES)
        return ByteArray(UNCOMPRESSED_POINT_LEN).also { out ->
            out[0] = UNCOMPRESSED_POINT_PREFIX
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

    fun generateEphemeralKeyPair(): java.security.KeyPair {
        val gen = java.security.KeyPairGenerator.getInstance("EC")
        gen.initialize(ECGenParameterSpec("secp256r1"), secureRandom)
        return gen.generateKeyPair()
    }
}
