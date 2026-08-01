package com.openburnbar.data.cloud

import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldF2m
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.EllipticCurve
import org.junit.Assert.assertThrows
import org.junit.Test

class P256PointValidationTest {
    @Test
    fun `canonical P-256 public key passes validation`() {
        requireP256Point(generateP256PublicKey(), "Test")
    }

    @Test
    fun `non-EC public key is rejected`() {
        val rsaPublicKey = KeyPairGenerator.getInstance("RSA")
            .apply { initialize(2048) }
            .generateKeyPair()
            .public

        assertThrows(IllegalStateException::class.java) {
            requireP256Point(rsaPublicKey, "Test")
        }
    }

    @Test
    fun `EC key over a binary field is rejected`() {
        val binaryCurve = EllipticCurve(ECFieldF2m(163), BigInteger.ONE, BigInteger.ONE)
        val binaryParams = ECParameterSpec(
            binaryCurve,
            ECPoint(BigInteger.ONE, BigInteger.ONE),
            BigInteger.valueOf(7),
            1,
        )

        assertThrows(IllegalStateException::class.java) {
            requireP256Point(FakeEcPublicKey(binaryParams, ECPoint(BigInteger.ONE, BigInteger.ONE)), "Test")
        }
    }

    @Test
    fun `coordinate outside the prime field is rejected`() {
        val params = generateP256PublicKey().params
        val primeModulus = (params.curve.field as? ECFieldFp)?.p
            ?: error("P-256 test fixture requires a prime-field curve.")

        assertThrows(IllegalStateException::class.java) {
            requireP256Point(FakeEcPublicKey(params, ECPoint(primeModulus, BigInteger.ONE)), "Test")
        }
    }

    @Test
    fun `negative coordinate is rejected`() {
        val params = generateP256PublicKey().params

        assertThrows(IllegalStateException::class.java) {
            requireP256Point(FakeEcPublicKey(params, ECPoint(BigInteger.valueOf(-1), BigInteger.ONE)), "Test")
        }
    }

    @Test
    fun `in-range point that is not on the curve is rejected`() {
        val params = generateP256PublicKey().params

        assertThrows(IllegalStateException::class.java) {
            requireP256Point(FakeEcPublicKey(params, ECPoint(BigInteger.ONE, BigInteger.ONE)), "Test")
        }
    }

    private fun generateP256PublicKey(): ECPublicKey {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        return generator.generateKeyPair().public as? ECPublicKey
            ?: error("P-256 test fixture requires an EC public key.")
    }

    private class FakeEcPublicKey(
        private val parameters: ECParameterSpec,
        private val point: ECPoint,
    ) : ECPublicKey {
        override fun getAlgorithm(): String = "EC"

        override fun getFormat(): String = "X.509"

        override fun getEncoded(): ByteArray = ByteArray(0)

        override fun getParams(): ECParameterSpec = parameters

        override fun getW(): ECPoint = point
    }
}
