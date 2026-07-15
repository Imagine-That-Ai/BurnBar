package com.openburnbar.domaincore

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.openburnbar_domain_ffi.CloudVaultDocumentEnvelope
import uniffi.openburnbar_domain_ffi.CloudVaultDocumentEnvelopeKind
import uniffi.openburnbar_domain_ffi.CloudVaultDocumentRewrapRequest
import uniffi.openburnbar_domain_ffi.CloudVaultFfiException
import uniffi.openburnbar_domain_ffi.CloudVaultResealNonce
import uniffi.openburnbar_domain_ffi.CloudVaultSearchOperation
import uniffi.openburnbar_domain_ffi.CloudVaultSearchRequest
import uniffi.openburnbar_domain_ffi.cloudVaultAesGcmOpenCombined
import uniffi.openburnbar_domain_ffi.cloudVaultAesGcmSealCombined
import uniffi.openburnbar_domain_ffi.cloudVaultEscrowOpen
import uniffi.openburnbar_domain_ffi.cloudVaultEscrowSeal
import uniffi.openburnbar_domain_ffi.cloudVaultRecoveryOpenVaultKey
import uniffi.openburnbar_domain_ffi.cloudVaultRecoveryWrapVaultKey
import uniffi.openburnbar_domain_ffi.cloudVaultRewrapDocument
import uniffi.openburnbar_domain_ffi.cloudVaultSearch
import uniffi.openburnbar_domain_ffi.cloudVaultSearchAnalyze
import uniffi.openburnbar_domain_ffi.cloudVaultValidateP256X963PublicKey
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion
import uniffi.openburnbar_domain_ffi.domainCoreSourceFingerprint
import uniffi.openburnbar_domain_ffi.domainCoreVersion
import uniffi.openburnbar_domain_ffi.hermesGatewayRelaySafetyCode
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

@RunWith(AndroidJUnit4::class)
class DomainCoreNativeLoadTest {
    @Test
    fun generatedBindingLoadsAbiVersionThreeNativeLibrary() {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val expectedIdentity =
            assets.open("union-abi-manifest.json").bufferedReader().use { JSONObject(it.readText()) }
        assertEquals(expectedIdentity.getLong("abiVersion").toUInt(), domainCoreAbiVersion())
        assertEquals(expectedIdentity.getString("coreVersion"), domainCoreVersion())
        val sourceFingerprint = domainCoreSourceFingerprint()
        assertTrue(sourceFingerprint.matches(Regex("[0-9a-f]{64}")))
        val expectedSourceFingerprint =
            assets
                .open("openburnbar-domain-core-source.sha256")
                .bufferedReader()
                .use { it.readText().trim() }
        assertTrue(expectedSourceFingerprint.matches(Regex("[0-9a-f]{64}")))
        assertEquals(expectedIdentity.getString("sourceSha256"), expectedSourceFingerprint)
        assertEquals(expectedSourceFingerprint, sourceFingerprint)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val candidateCommit = InstrumentationRegistry.getArguments().getString("candidateCommit").orEmpty()
        assertTrue(candidateCommit.matches(Regex("[0-9a-f]{40}")))
        val nativeLibrary =
            File(
                instrumentation.context.applicationInfo.nativeLibraryDir,
                System.mapLibraryName("openburnbar_domain_ffi"),
            )
        assertTrue(nativeLibrary.isFile)
        assertFalse(nativeLibrary.isDirectory)
        val binarySha256 = sha256(nativeLibrary)
        File(instrumentation.context.filesDir, "domain-core-observed-identity.json")
            .writeText(
                JSONObject()
                    .put("candidateCommit", candidateCommit)
                    .put("coreVersion", domainCoreVersion())
                    .put("abiVersion", domainCoreAbiVersion().toLong())
                    .put("sourceSha256", sourceFingerprint)
                    .put("binarySha256", binarySha256)
                    .toString() + "\n",
            )
        assertEquals(
            "97AB 6CD8 FEF0 9594 D5ED FAF1 1D10 B6F7",
            hermesGatewayRelaySafetyCode(
                Base64.decode(
                    "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU=",
                    Base64.DEFAULT,
                ),
                Base64.decode(
                    "BHzyexiNA09+ilI4AwS1GsPAiWnid/IbNaYLSPxHZpl4B3dVENuO0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9E=",
                    Base64.DEFAULT,
                ),
            ),
        )
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
    fun documentRewrapExecutesThroughNativeLibrary() {
        val newKeyId = "v1_515a733d7320b35b2117893952f93a94"
        val envelope =
            CloudVaultDocumentEnvelope(
                kind = CloudVaultDocumentEnvelopeKind.SEALED_PAYLOAD,
                fieldName = "sealedPayload",
                schemaVersion = 2u,
                algorithm = "AES-256-GCM",
                keyVersion = 1u,
                vaultKeyId = "v1_3e441393404b2085e7a3090a47d377ab",
                nonce = null,
                ciphertext = null,
                tag = null,
                sealedBoxBase64 = "ERERERERERERERER/IcMhLA283cnbpRNi2CTKvNBn1ZeDHqbBsvt7oVOgZ2I6DwXeAOM",
                plaintextSha256 = null,
                plaintextHmac = null,
                integrityHashVersion = null,
                aad = "OpenBurnBar-CloudVaultSealedPayload-v2",
                hasCreatedAt = false,
            )
        val request =
            CloudVaultDocumentRewrapRequest(
                uid = "userA",
                collection = "cli_agent_mission_requests",
                docId = "requestA",
                documentFieldNames = listOf("vaultKeyID", "plainStatus", "sealedPayload"),
                envelopes = listOf(envelope),
                resealNoncePlan =
                    listOf(
                        CloudVaultResealNonce(
                            fieldName = "sealedPayload",
                            nonce = ByteArray(12) { 0x22 },
                        ),
                    ),
                vaultGeneration = 7L,
                rotationJobId = "job-7",
            )
        val result =
            cloudVaultRewrapDocument(
                request,
                ByteArray(32) { 0x71 },
                ByteArray(32) { 0x72 },
                newKeyId,
            )
        assertEquals(listOf("sealedPayload"), result.changedFields)
        assertEquals(listOf("vaultKeyID"), result.companionUpdateIntents.map { it.companionFieldName })
        assertEquals(7L, result.vaultGenerationUpdate)
        assertEquals("job-7", result.rotationJobIdUpdate)
        assertEquals(newKeyId, result.rewrappedEnvelopes.single().vaultKeyId)
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

    private fun search(
        operation: CloudVaultSearchOperation,
        text: String,
        key: ByteArray,
        limit: Int,
    ): List<String> = cloudVaultSearch(CloudVaultSearchRequest(operation, text, key, limit)).hashes

    private fun hex(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
