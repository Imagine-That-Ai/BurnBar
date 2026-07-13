package com.openburnbar.domaincore

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.openburnbar_domain_ffi.cloudVaultAesGcmOpenCombined
import uniffi.openburnbar_domain_ffi.cloudVaultAesGcmSealCombined
import uniffi.openburnbar_domain_ffi.cloudVaultEscrowOpen
import uniffi.openburnbar_domain_ffi.cloudVaultEscrowSeal
import uniffi.openburnbar_domain_ffi.cloudVaultRecoveryOpenVaultKey
import uniffi.openburnbar_domain_ffi.cloudVaultRecoveryWrapVaultKey
import uniffi.openburnbar_domain_ffi.cloudVaultValidateP256X963PublicKey
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion
import uniffi.openburnbar_domain_ffi.domainCoreVersion
import uniffi.openburnbar_domain_ffi.HermesAadKind
import uniffi.openburnbar_domain_ffi.hermesGatewayRelaySafetyCode
import uniffi.openburnbar_domain_ffi.hermesHkdfSha256
import uniffi.openburnbar_domain_ffi.hermesHmacSha256
import uniffi.openburnbar_domain_ffi.hermesOpenBase64
import uniffi.openburnbar_domain_ffi.hermesRelayAad
import uniffi.openburnbar_domain_ffi.hermesRatchetEnvelopeAad
import uniffi.openburnbar_domain_ffi.hermesSealBase64

@RunWith(AndroidJUnit4::class)
class DomainCoreNativeLoadTest {
    @Test
    fun generatedBindingLoadsAbiVersionTwoNativeLibrary() {
        assertEquals(2u, domainCoreAbiVersion())
        assertTrue(domainCoreVersion().isNotBlank())
    }

    @Test
    fun aesGcmExecutesThroughArm64NativeLibrary() {
        val plaintext = "OpenBurnBar".encodeToByteArray()
        val aad = "aad".encodeToByteArray()
        val key = ByteArray(32)
        val sealed = cloudVaultAesGcmSealCombined(plaintext, key, ByteArray(12), aad)
        assertTrue(cloudVaultAesGcmOpenCombined(sealed, key, aad).contentEquals(plaintext))
    }

    @Test
    fun recoveryAndP256EscrowExecuteThroughNativeLibrary() {
        val recoveryKey = "abc-defg-hjkm-npq-rst-vwxyz-23456789"
        val vaultKey = ByteArray(32) { it.toByte() }
        val nonce = ByteArray(12) { it.toByte() }
        val recoveryWrapped = cloudVaultRecoveryWrapVaultKey(vaultKey, recoveryKey, nonce)
        assertEquals(
            "3d3722923f9209d63093b1212a55b5fb5de462c00137ba6d6b46228404873166",
            recoveryWrapped.verificationHash,
        )
        assertTrue(cloudVaultRecoveryOpenVaultKey(recoveryWrapped.combined, recoveryKey).contentEquals(vaultKey))

        val publicKey =
            hex(
                "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" +
                    "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
            )
        val sharedSecret = ByteArray(32) { (0xa0 + it).toByte() }
        cloudVaultValidateP256X963PublicKey(publicKey)
        val escrowWire = cloudVaultEscrowSeal(ByteArray(0), publicKey, sharedSecret, nonce)
        assertTrue(cloudVaultEscrowOpen(escrowWire, sharedSecret).isEmpty())
    }

    @Test
    fun hermesCanonicalTransformsExecuteInAndroidNativeLibrary() {
        val aad = hermesRelayAad(
            HermesAadKind.REQUEST,
            listOf("user-1", "connection-2", "request-3"),
        )
        assertEquals(
            "OpenBurnBar-HermesRelay-v1|request|user-1|connection-2|request-3",
            String(aad, Charsets.UTF_8),
        )
        val key = ByteArray(32) { 0x11 }
        val nonce = ByteArray(12) { 0x22 }
        val sealed = hermesSealBase64("hello Hermes".toByteArray(), key, aad, nonce)
        assertEquals("IiIiIiIiIiIiIiIif5JrJa/v1zqXUrtPoOyiZT6RHzZafNp9vG78CQ==", sealed)
        assertEquals("hello Hermes", String(hermesOpenBase64(sealed, key, aad)))

        val ikm = ByteArray(22) { 0x0b }
        val salt = ByteArray(13) { it.toByte() }
        val info = ByteArray(10) { (0xf0 + it).toByte() }
        assertEquals(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            hermesHkdfSha256(ikm, salt, info, 42u).joinToString("") { "%02x".format(it) },
        )

        val agent = ByteArray(65) { it.toByte() }
        val phone = ByteArray(65) { (64 - it).toByte() }
        assertEquals(
            "897E 3E16 F194 F44A 9E79 B41E F88E CBE7",
            hermesGatewayRelaySafetyCode(agent, phone),
        )

        val ratchetKey = ByteArray(32) { it.toByte() }
        assertEquals(
            "e3846c975a1e190bd2d985eb4e0bf3ca7ad203c2a4adc5db0f9ca3b4fc7afba4",
            hermesHmacSha256(
                ratchetKey,
                "OpenBurnBar-HermesRatchet-v1-chain".toByteArray(),
            ).joinToString("") { "%02x".format(it) },
        )
        val ratchetAad = hermesRatchetEnvelopeAad(
                "assoc".toByteArray(),
                "OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM",
                "session",
                "sender",
                "receiver",
                "cHVibGlj",
                1uL,
                2uL,
                3uL,
                4uL,
            )
        val prefix = "OpenBurnBar-HermesRatchet-v1-AAD".toByteArray()
        assertTrue(
            ratchetAad.copyOfRange(0, prefix.size).contentEquals(prefix),
        )
    }

    private fun hex(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
