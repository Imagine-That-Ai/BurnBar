package com.openburnbar.data.cloud

import com.openburnbar.data.policy.MobileEscrowImportFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidEscrowCredentialImporterTest {
    @Test
    fun classifyRejectsBeforeDecrypt() {
        var decrypted = false
        val importer = AndroidEscrowCredentialImporter()
        val result =
            importer.importEnvelope(
                fields =
                AndroidEscrowCredentialImporter.EnvelopeFields(
                    envelopeId = "env-1",
                    ciphertextBase64 = "dGVzdA==",
                    grantId = "grant-1",
                    envelopeVersion = 2,
                    targetDeviceId = "android-a",
                    grantStatus = "active",
                    grantExpiresAtMs = null,
                ),
                currentDeviceId = "android-a",
                nowMs = 1_700_000_000_000,
                hasPrivateKey = true,
            ) { _, _ ->
                decrypted = true
                ByteArray(0)
            }
        assertTrue(result is AndroidEscrowCredentialImporter.Result.Rejected)
        assertEquals(
            MobileEscrowImportFailure.EXPIRED_GRANT,
            (result as AndroidEscrowCredentialImporter.Result.Rejected).failure,
        )
        assertTrue(!decrypted)
    }

    @Test
    fun classifyAllowsDecryptWhenWellFormed() {
        var decrypted = false
        val importer = AndroidEscrowCredentialImporter()
        val result =
            importer.importEnvelope(
                fields =
                AndroidEscrowCredentialImporter.EnvelopeFields(
                    envelopeId = "env-1",
                    ciphertextBase64 = "dGVzdA==",
                    grantId = "grant-1",
                    envelopeVersion = 2,
                    targetDeviceId = "android-a",
                    grantStatus = "active",
                    grantExpiresAtMs = 1_800_000_000_000,
                    providerId = "openai",
                    sourceDeviceId = "mac-1",
                    credentialKind = "api_key",
                    accountLabel = "OpenAI",
                    keyVersion = 1,
                    metadataBinding = EscrowCredentialMetadataBinding.METADATA_BINDING,
                ),
                currentDeviceId = "android-a",
                nowMs = 1_700_000_000_000,
                hasPrivateKey = true,
            ) { _, aad ->
                decrypted = true
                assertTrue(aad.isNotEmpty())
                "ok".toByteArray()
            }
        assertTrue(result is AndroidEscrowCredentialImporter.Result.Imported)
        assertTrue(decrypted)
    }

    @Test
    fun persistImportedWritesSecretOrFails() {
        val stored = mutableMapOf<String, String>()
        val importer =
            AndroidEscrowCredentialImporter(
                persistSecret = { provider, secret ->
                    stored[provider] = secret
                    true
                },
            )
        val imported =
            AndroidEscrowCredentialImporter.Result.Imported("sk-live".toByteArray())
        val persisted = importer.persistImported(imported, "openai")
        assertTrue(persisted is AndroidEscrowCredentialImporter.Result.Imported)
        assertEquals("sk-live", stored["openai"])
    }

    @Test
    fun persistImportedFailsClosedWhenStoreDropsSecret() {
        val importer = AndroidEscrowCredentialImporter(persistSecret = { _, _ -> false })
        val imported = AndroidEscrowCredentialImporter.Result.Imported("sk-live".toByteArray())
        val persisted = importer.persistImported(imported, "openai")
        assertTrue(persisted is AndroidEscrowCredentialImporter.Result.PersistFailed)
    }
}
