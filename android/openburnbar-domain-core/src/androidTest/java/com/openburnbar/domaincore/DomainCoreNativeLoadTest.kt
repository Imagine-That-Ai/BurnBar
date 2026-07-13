package com.openburnbar.domaincore

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.openburnbar_domain_ffi.CloudVaultSearchOperation
import uniffi.openburnbar_domain_ffi.CloudVaultSearchRequest
import uniffi.openburnbar_domain_ffi.CloudVaultFfiException
import uniffi.openburnbar_domain_ffi.cloudVaultAesGcmOpenCombined
import uniffi.openburnbar_domain_ffi.cloudVaultAesGcmSealCombined
import uniffi.openburnbar_domain_ffi.cloudVaultEscrowOpen
import uniffi.openburnbar_domain_ffi.cloudVaultEscrowSeal
import uniffi.openburnbar_domain_ffi.cloudVaultRecoveryOpenVaultKey
import uniffi.openburnbar_domain_ffi.cloudVaultRecoveryWrapVaultKey
import uniffi.openburnbar_domain_ffi.cloudVaultSearch
import uniffi.openburnbar_domain_ffi.cloudVaultSearchAnalyze
import uniffi.openburnbar_domain_ffi.cloudVaultValidateP256X963PublicKey
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion
import uniffi.openburnbar_domain_ffi.domainCoreVersion

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
    fun searchContractExecutesThroughNativeLibrary() {
        val text = "The QUICK, quick fox and X."
        assertEquals(listOf("quick", "quick", "fox"), cloudVaultSearchAnalyze(text).normalizedTokens)
        assertEquals(
            listOf(
                "e9110d7f0c79afdae6316235800dc41b",
                "66e59fa04825dc74f5ef7cb57884d4ed",
            ),
            cloudVaultSearch(
                CloudVaultSearchRequest(
                    CloudVaultSearchOperation.TOKEN,
                    text,
                    ByteArray(32) { it.toByte() },
                    250,
                ),
            ).hashes,
        )
    }

    @Test
    fun searchNativeContractCoversUnicodeBoundsAndKeyIsolation() {
        val unicode = cloudVaultSearchAnalyze("CAFÉ naïve 東京 Straße １２３ X")
        assertEquals(listOf("café", "naïve", "東京", "straße", "１２３"), unicode.normalizedTokens)
        assertEquals(listOf("café", "naïve", "東京", "straße", "１２３", "x"), unicode.exactPhraseTokens)
        assertEquals(
            listOf("𐐨𐐩"),
            cloudVaultSearchAnalyze("𐐀 𐐀𐐁").normalizedTokens,
        )

        val primaryKey = ByteArray(32) { it.toByte() }
        val alternateKey = ByteArray(32) { (0x20 + it).toByte() }
        val query = search(CloudVaultSearchOperation.QUERY, "Depl X ads", primaryKey, 20)
        assertEquals(
            listOf(
                "b63572c113cb9ddda6dacc5c240c390f",
                "4bfd945bb269124cfa5f35d47767b103",
                "0fbb9c9226d586ccbb3a49235ed47847",
                "41e9eda9d01fef15d3b18d4bcd924f20",
                "2845e8e8fadf0f00d2535626b33dcf48",
                "100c03db24b6a39b078b8f987c56fc70",
                "5e547f79d9db83df558dcbf3c875d804",
            ),
            query,
        )
        assertTrue(search(CloudVaultSearchOperation.INDEX, "bounded search", primaryKey, 0).isEmpty())
        assertTrue(search(CloudVaultSearchOperation.TOKEN, "bounded search", primaryKey, -1).isEmpty())

        val primary = search(CloudVaultSearchOperation.TOKEN, "vault isolation", primaryKey, 10)
        val alternate = search(CloudVaultSearchOperation.TOKEN, "vault isolation", alternateKey, 10)
        assertFalse(primary.toSet().intersect(alternate.toSet()).isNotEmpty())
        assertThrows(CloudVaultFfiException.InvalidKeyLength::class.java) {
            search(CloudVaultSearchOperation.TOKEN, "invalid key", ByteArray(31), 10)
        }
        assertThrows(CloudVaultFfiException.SearchLimitTooLarge::class.java) {
            search(CloudVaultSearchOperation.TOKEN, "oversized limit", primaryKey, 1025)
        }
        assertThrows(CloudVaultFfiException.SearchTextTooLarge::class.java) {
            search(CloudVaultSearchOperation.TOKEN, "x".repeat(1_048_577), primaryKey, 1)
        }
        assertThrows(CloudVaultFfiException.SearchTooManyTokens::class.java) {
            search(CloudVaultSearchOperation.TOKEN, List(4097) { "aa" }.joinToString(" "), primaryKey, 1)
        }
    }

    private fun search(operation: CloudVaultSearchOperation, text: String, key: ByteArray, limit: Int): List<String> =
        cloudVaultSearch(CloudVaultSearchRequest(operation, text, key, limit)).hashes

    private fun hex(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
