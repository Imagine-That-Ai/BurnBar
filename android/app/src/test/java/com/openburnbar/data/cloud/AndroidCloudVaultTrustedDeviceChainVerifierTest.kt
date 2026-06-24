package com.openburnbar.data.cloud

import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class AndroidCloudVaultTrustedDeviceChainVerifierTest {
    @Test
    fun canonicalEscrowPublicKeyDecoderAcceptsGeneratedP256X963Key() {
        val publicKeyData = generatedP256PublicKeyX963()
        val encoded = CloudVaultCryptoSupport.encodeBase64(publicKeyData)

        assertArrayEquals(
            publicKeyData,
            decodeCanonicalEscrowPublicKeyData(encoded, "trusted-device"),
        )
    }

    @Test
    fun canonicalEscrowPublicKeyDecoderRejectsMimeIgnoredWhitespace() {
        val encoded = CloudVaultCryptoSupport.encodeBase64(generatedP256PublicKeyX963())
        val newlinePadded = "${encoded.substring(0, 12)}\n${encoded.substring(12)}"

        assertThrows(IllegalStateException::class.java) {
            decodeCanonicalEscrowPublicKeyData(newlinePadded, "trusted-device")
        }
    }

    @Test
    fun canonicalEscrowPublicKeyDecoderRejectsNonCanonicalBase64() {
        val encoded = CloudVaultCryptoSupport.encodeBase64(generatedP256PublicKeyX963())

        assertThrows(IllegalStateException::class.java) {
            decodeCanonicalEscrowPublicKeyData(encoded.trimEnd('='), "trusted-device")
        }
    }

    @Test
    fun canonicalEscrowPublicKeyDecoderRejectsInvalidX963Length() {
        val shortKey = ByteArray(64) { 0x01 }
        shortKey[0] = 0x04

        assertThrows(IllegalStateException::class.java) {
            decodeCanonicalEscrowPublicKeyData(CloudVaultCryptoSupport.encodeBase64(shortKey), "trusted-device")
        }
    }

    @Test
    fun canonicalEscrowPublicKeyDecoderRejectsOffCurveX963Point() {
        val offCurve = ByteArray(65)
        offCurve[0] = 0x04

        assertThrows(IllegalStateException::class.java) {
            decodeCanonicalEscrowPublicKeyData(CloudVaultCryptoSupport.encodeBase64(offCurve), "trusted-device")
        }
    }

    private fun generatedP256PublicKeyX963(): ByteArray {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        return CloudVaultCrypto.publicKeyX963(generator.generateKeyPair().public)
    }
}
