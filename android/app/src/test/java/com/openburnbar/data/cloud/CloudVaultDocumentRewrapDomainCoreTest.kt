package com.openburnbar.data.cloud

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.openburnbar_domain_ffi.CloudVaultCompanionUpdateIntent
import uniffi.openburnbar_domain_ffi.CloudVaultDocumentEnvelope
import uniffi.openburnbar_domain_ffi.CloudVaultDocumentEnvelopeKind
import uniffi.openburnbar_domain_ffi.CloudVaultDocumentRewrapResult as FfiResult
import uniffi.openburnbar_domain_ffi.CloudVaultPreservedEnvelopeMemberIntent

class CloudVaultDocumentRewrapDomainCoreTest {
    @After
    fun tearDown() {
        CloudVaultDocumentRewrapDomainCore.resetTestOverrides()
    }

    @Test
    fun rustModeLowersOneLexicographicOperationAndAppliesAllIntents() {
        val oldKey = ByteArray(32) { 0x31.toByte() }
        val newKey = ByteArray(32) { 0x32.toByte() }
        val newVaultKeyID = CloudVaultCrypto.vaultKeyID(newKey)
        val createdAt = Any()
        val data =
            linkedMapOf<String, Any?>(
                "sealedTextZ" to textMap(),
                "plainStatus" to "queued",
                "sealedBlobA" to blobMap(createdAt),
                "vaultKeyID" to CloudVaultCrypto.vaultKeyID(oldKey),
                "sealedPayloadM" to payloadMap(CloudVaultCrypto.vaultKeyID(oldKey)),
            )
        val observedNonceFields = mutableListOf<String>()
        var nextNonceByte = 0x20
        var calls = 0
        var loweredOldKey: ByteArray? = null
        var loweredNewKey: ByteArray? = null
        CloudVaultDocumentRewrapDomainCore.modeOverride = CloudVaultDocumentRewrapMode.RUST
        CloudVaultDocumentRewrapDomainCore.abiVersionOverride = { 3u }
        CloudVaultDocumentRewrapDomainCore.nonceOverride = {
            nextNonceByte += 1
            ByteArray(12) { nextNonceByte.toByte() }
        }
        CloudVaultDocumentRewrapDomainCore.nativeRewrapOverride = { request, nativeOldKey, nativeNewKey, nativeKeyID ->
            calls += 1
            loweredOldKey = nativeOldKey
            loweredNewKey = nativeNewKey
            assertEquals(newVaultKeyID, nativeKeyID)
            assertEquals(listOf("sealedBlobA", "sealedPayloadM", "sealedTextZ"), request.envelopes.map { it.fieldName })
            assertEquals(listOf("sealedBlobA", "sealedPayloadM", "sealedTextZ"), request.resealNoncePlan.map { it.fieldName })
            assertEquals(listOf(0x21, 0x22, 0x23), request.resealNoncePlan.map { it.nonce.first().toInt() and 0xff })
            observedNonceFields += request.envelopes.map { it.fieldName }
            FfiResult(
                changedFields = listOf("sealedBlobA", "sealedPayloadM", "sealedTextZ"),
                skippedFields = emptyList(),
                rewrappedEnvelopes =
                listOf(
                    outputBlob("sealedBlobA"),
                    outputPayload("sealedPayloadM", newVaultKeyID),
                    outputText("sealedTextZ", ciphertext = "bmV3"),
                ),
                companionUpdateIntents =
                listOf(CloudVaultCompanionUpdateIntent("sealedPayloadM", "vaultKeyID", newVaultKeyID)),
                preservedMemberIntents =
                listOf(CloudVaultPreservedEnvelopeMemberIntent("sealedBlobA", "createdAt")),
                vaultGenerationUpdate = 9L,
                rotationJobIdUpdate = "job-9",
            )
        }

        val result =
            CloudVaultCrypto.rewrapCloudVaultDocument(
                data = data,
                uid = "userA",
                collection = "collectionA",
                docID = "docA",
                oldKey = oldKey,
                newKey = newKey,
                newVaultKeyID = newVaultKeyID,
                vaultGeneration = 9,
                rotationJobId = "job-9",
            )

        assertEquals(1, calls)
        assertEquals(listOf("sealedBlobA", "sealedPayloadM", "sealedTextZ"), observedNonceFields)
        assertEquals("queued", result.data["plainStatus"])
        assertEquals(newVaultKeyID, result.data["vaultKeyID"])
        assertEquals(9, result.data["vaultGeneration"])
        assertEquals("job-9", result.data["rewrapJobId"])
        val sealedBlob = result.data["sealedBlobA"]
        if (sealedBlob !is Map<*, *>) throw AssertionError("sealedBlobA must remain an envelope map")
        assertSame(createdAt, sealedBlob["createdAt"])
        assertTrue(requireNotNull(loweredOldKey).all { it == 0.toByte() })
        assertTrue(requireNotNull(loweredNewKey).all { it == 0.toByte() })
        assertTrue(oldKey.all { it == 0x31.toByte() })
        assertTrue(newKey.all { it == 0x32.toByte() })
    }

    @Test
    fun ambiguousEnvelopeMapIsRejectedBeforeLegacyOrNativeExecution() {
        var legacyCalls = 0
        var nativeCalls = 0
        CloudVaultDocumentRewrapDomainCore.modeOverride = CloudVaultDocumentRewrapMode.RUST
        CloudVaultDocumentRewrapDomainCore.abiVersionOverride = { 3u }
        CloudVaultDocumentRewrapDomainCore.nativeRewrapOverride = { _, _, _, _ ->
            nativeCalls += 1
            error("must not execute")
        }
        val ambiguous =
            mapOf<String, Any?>(
                "field" to
                    mapOf(
                        "vaultKeyID" to "v1_old",
                        "sealedBoxBase64" to "AA==",
                        "nonce" to "AA==",
                        "ciphertext" to "AA==",
                        "tag" to "AA==",
                    ),
            )

        assertThrows(IllegalArgumentException::class.java) {
            CloudVaultDocumentRewrapDomainCore.rewrap(
                ambiguous,
                "uid",
                "collection",
                "doc",
                ByteArray(32) { 1.toByte() },
                ByteArray(32) { 2.toByte() },
                "v1_new",
                null,
                null,
            ) {
                legacyCalls += 1
                CloudVaultDocumentRewrapResult(ambiguous, emptyList())
            }
        }
        assertEquals(0, legacyCalls)
        assertEquals(0, nativeCalls)
    }

    @Test
    fun repeatedPlatformNonceFailsBeforeCrossingTheNativeBoundary() {
        var nativeCalls = 0
        CloudVaultDocumentRewrapDomainCore.modeOverride = CloudVaultDocumentRewrapMode.RUST
        CloudVaultDocumentRewrapDomainCore.abiVersionOverride = { 3u }
        CloudVaultDocumentRewrapDomainCore.nonceOverride = { ByteArray(12) { 4.toByte() } }
        CloudVaultDocumentRewrapDomainCore.nativeRewrapOverride = { _, _, _, _ ->
            nativeCalls += 1
            emptyFfiResult()
        }
        val data = mapOf<String, Any?>("a" to textMap(), "b" to textMap())

        assertThrows(IllegalArgumentException::class.java) {
            CloudVaultDocumentRewrapDomainCore.rewrap(
                data,
                "uid",
                "collection",
                "doc",
                ByteArray(32) { 1.toByte() },
                ByteArray(32) { 2.toByte() },
                "v1_new",
                null,
                null,
            ) { CloudVaultDocumentRewrapResult(data, emptyList()) }
        }
        assertEquals(0, nativeCalls)
    }

    @Test
    fun rustFailsClosedOnAbiNativeAndResponseErrorsWithoutLegacyFallback() {
        val newKey = ByteArray(32) { 2.toByte() }
        var legacyCalls = 0
        CloudVaultDocumentRewrapDomainCore.modeOverride = CloudVaultDocumentRewrapMode.RUST
        CloudVaultDocumentRewrapDomainCore.abiVersionOverride = { 4u }

        assertThrows(IllegalStateException::class.java) {
            CloudVaultDocumentRewrapDomainCore.rewrap(
                emptyMap(),
                "uid",
                "collection",
                "doc",
                ByteArray(32) { 1.toByte() },
                newKey,
                CloudVaultCrypto.vaultKeyID(newKey),
                null,
                null,
            ) {
                legacyCalls += 1
                CloudVaultDocumentRewrapResult(emptyMap(), emptyList())
            }
        }
        assertEquals(0, legacyCalls)

        CloudVaultDocumentRewrapDomainCore.resetTestOverrides()
        CloudVaultDocumentRewrapDomainCore.modeOverride = CloudVaultDocumentRewrapMode.RUST
        CloudVaultDocumentRewrapDomainCore.abiVersionOverride = { 3u }
        CloudVaultDocumentRewrapDomainCore.nativeRewrapOverride = { _, _, _, _ -> throw SecurityException("auth failed") }
        assertThrows(SecurityException::class.java) {
            CloudVaultDocumentRewrapDomainCore.rewrap(
                emptyMap(),
                "uid",
                "collection",
                "doc",
                ByteArray(32) { 1.toByte() },
                newKey,
                CloudVaultCrypto.vaultKeyID(newKey),
                null,
                null,
            ) {
                legacyCalls += 1
                CloudVaultDocumentRewrapResult(emptyMap(), emptyList())
            }
        }
        assertEquals(0, legacyCalls)
    }

    @Test
    fun sameKeyFailsClosedInRustButShadowReturnsLegacyAndReportsSanitizedError() {
        val key = ByteArray(32) { 7.toByte() }
        val diagnostics = mutableListOf<CloudVaultDocumentRewrapDiagnostic>()
        var legacyCalls = 0
        var nativeCalls = 0
        CloudVaultDocumentRewrapDomainCore.abiVersionOverride = { 3u }
        CloudVaultDocumentRewrapDomainCore.coreVersionOverride = { "0.1.0" }
        CloudVaultDocumentRewrapDomainCore.diagnosticOverride = diagnostics::add
        CloudVaultDocumentRewrapDomainCore.nativeRewrapOverride = { _, _, _, _ ->
            nativeCalls += 1
            emptyFfiResult()
        }
        CloudVaultDocumentRewrapDomainCore.modeOverride = CloudVaultDocumentRewrapMode.RUST
        assertThrows(IllegalArgumentException::class.java) {
            CloudVaultDocumentRewrapDomainCore.rewrap(
                emptyMap(),
                "secret-user",
                "secret-collection",
                "secret-doc",
                key,
                key.copyOf(),
                CloudVaultCrypto.vaultKeyID(key),
                null,
                null,
            ) {
                legacyCalls += 1
                CloudVaultDocumentRewrapResult(emptyMap(), emptyList())
            }
        }
        assertEquals(0, legacyCalls)

        CloudVaultDocumentRewrapDomainCore.modeOverride = CloudVaultDocumentRewrapMode.SHADOW
        val shadow =
            CloudVaultDocumentRewrapDomainCore.rewrap(
                emptyMap(),
                "secret-user",
                "secret-collection",
                "secret-doc",
                key,
                key.copyOf(),
                CloudVaultCrypto.vaultKeyID(key),
                null,
                null,
            ) {
                legacyCalls += 1
                CloudVaultDocumentRewrapResult(mapOf("legacy" to true), emptyList())
            }
        assertEquals(mapOf("legacy" to true), shadow.data)
        assertEquals(1, legacyCalls)
        assertEquals(0, nativeCalls)
        assertEquals(
            listOf(CloudVaultDocumentRewrapDiagnostic("document_rewrap", "rust_error", "0.1.0", 1)),
            diagnostics,
        )
    }

    @Test
    fun shadowUsesIdenticalNonceReturnsExactLegacyAndLogsOnlyMismatchDimensions() {
        val oldKey = ByteArray(32) { 0x41.toByte() }
        val newKey = ByteArray(32) { 0x42.toByte() }
        val keyID = CloudVaultCrypto.vaultKeyID(newKey)
        val source = mapOf<String, Any?>("sealedLabel" to CloudVaultCrypto.sealedTextMap(CloudVaultCrypto.sealText("secret", oldKey)))
        CloudVaultDocumentRewrapDomainCore.modeOverride = CloudVaultDocumentRewrapMode.LEGACY
        CloudVaultDocumentRewrapDomainCore.nonceOverride = { ByteArray(12) { 0x55.toByte() } }
        val expected = CloudVaultCrypto.rewrapCloudVaultDocument(source, "uid", "collection", "doc", oldKey, newKey, keyID)
        val expectedEnvelope = expected.data["sealedLabel"]
        if (expectedEnvelope !is Map<*, *>) throw AssertionError("sealedLabel must remain an envelope map")

        CloudVaultDocumentRewrapDomainCore.resetTestOverrides()
        val diagnostics = mutableListOf<CloudVaultDocumentRewrapDiagnostic>()
        CloudVaultDocumentRewrapDomainCore.modeOverride = CloudVaultDocumentRewrapMode.SHADOW
        CloudVaultDocumentRewrapDomainCore.abiVersionOverride = { 3u }
        CloudVaultDocumentRewrapDomainCore.coreVersionOverride = { "0.1.0" }
        CloudVaultDocumentRewrapDomainCore.nonceOverride = { ByteArray(12) { 0x55.toByte() } }
        CloudVaultDocumentRewrapDomainCore.diagnosticOverride = diagnostics::add
        CloudVaultDocumentRewrapDomainCore.nativeRewrapOverride = { request, _, _, _ ->
            assertEquals("sealedLabel", request.resealNoncePlan.single().fieldName)
            assertEquals(0x55, request.resealNoncePlan.single().nonce.first().toInt() and 0xff)
            FfiResult(
                changedFields = listOf("sealedLabel"),
                skippedFields = emptyList(),
                rewrappedEnvelopes = listOf(outputText("sealedLabel", ciphertext = "dGFtcGVyZWQ=")),
                companionUpdateIntents = emptyList(),
                preservedMemberIntents = emptyList(),
                vaultGenerationUpdate = null,
                rotationJobIdUpdate = null,
            )
        }

        val actual = CloudVaultCrypto.rewrapCloudVaultDocument(source, "uid", "collection", "doc", oldKey, newKey, keyID)

        assertEquals(expected.changedFields, actual.changedFields)
        assertEquals(expectedEnvelope, actual.data["sealedLabel"])
        assertEquals(
            listOf(CloudVaultDocumentRewrapDiagnostic("document_rewrap", "mismatch", "0.1.0", 1)),
            diagnostics,
        )
    }

    @Test
    fun modeParserDefaultsUnknownValuesToLegacy() {
        assertEquals(CloudVaultDocumentRewrapMode.LEGACY, CloudVaultDocumentRewrapMode.parse(" legacy "))
        assertEquals(CloudVaultDocumentRewrapMode.SHADOW, CloudVaultDocumentRewrapMode.parse("SHADOW"))
        assertEquals(CloudVaultDocumentRewrapMode.RUST, CloudVaultDocumentRewrapMode.parse("rust"))
        assertEquals(CloudVaultDocumentRewrapMode.LEGACY, CloudVaultDocumentRewrapMode.parse("future-mode"))
    }

    private fun payloadMap(vaultKeyID: String): Map<String, Any> = mapOf(
        "schemaVersion" to 2,
        "algorithm" to "AES-256-GCM",
        "keyVersion" to 1,
        "vaultKeyID" to vaultKeyID,
        "sealedBoxBase64" to "ERERERERERERERER/IcMhLA283cnbpRNi2CTKvNBn1ZeDHqbBsvt7oVOgZ2I6DwXeAOM",
        "aad" to "OpenBurnBar-CloudVaultSealedPayload-v2",
    )

    private fun textMap(): Map<String, Any> = mapOf(
        "schemaVersion" to 2,
        "algorithm" to "AES-256-GCM",
        "keyVersion" to 1,
        "nonce" to "EhISEhISEhISEhIS",
        "ciphertext" to "klujVkaSuje+TiZhYw0=",
        "tag" to "6fIIAety1elc8wLasntHiw==",
        "aad" to "OpenBurnBar-CloudVault-aad-v2|userA|collectionA|docA|sealedTextZ|2|sealedTextZ",
    )

    private fun blobMap(createdAt: Any): Map<String, Any> = mapOf(
        "schemaVersion" to 2,
        "algorithm" to "AES-256-GCM",
        "keyVersion" to 1,
        "plaintextHMAC" to "ccdf8340a0ac5c43222429dfe57f07a711200f92a2b126456eb1e5b5b68935e8",
        "integrityHashVersion" to 1,
        "sealedBoxBase64" to "ExMTExMTExMTHF//R2eJOKG8evtuzUFrtP+6VRddslLN+8Fd0byQUpJW80vWQA==",
        "aad" to "OpenBurnBar-CloudVaultBlob-v2",
        "createdAt" to createdAt,
    )

    private fun outputPayload(field: String, vaultKeyID: String): CloudVaultDocumentEnvelope = CloudVaultDocumentEnvelope(
        CloudVaultDocumentEnvelopeKind.SEALED_PAYLOAD,
        field,
        2u,
        "AES-256-GCM",
        1u,
        vaultKeyID,
        null,
        null,
        null,
        "IiIiIiIiIiIiIiIiAA==",
        null,
        null,
        null,
        "OpenBurnBar-CloudVault-aad-v2|userA|collectionA|docA|$field|2|$field",
        false,
    )

    private fun outputText(field: String, ciphertext: String): CloudVaultDocumentEnvelope = CloudVaultDocumentEnvelope(
        CloudVaultDocumentEnvelopeKind.SEALED_TEXT,
        field,
        2u,
        "AES-256-GCM",
        1u,
        null,
        "ISEhISEhISEhISEh",
        ciphertext,
        "vHtGRTsSqIo62nhmt30fcQ==",
        null,
        null,
        null,
        null,
        "OpenBurnBar-CloudVault-aad-v2|userA|collectionA|docA|$field|2|$field",
        false,
    )

    private fun outputBlob(field: String): CloudVaultDocumentEnvelope = CloudVaultDocumentEnvelope(
        CloudVaultDocumentEnvelopeKind.BLOB,
        field,
        2u,
        "AES-256-GCM",
        1u,
        null,
        null,
        null,
        null,
        "IyMjIyMjIyMjIyMjAA==",
        null,
        "5fe0e2d17a7f00ab0c6f5ba4ae6f443026e0633d51e81c2881c668dba84f99cf",
        1u,
        "OpenBurnBar-CloudVault-aad-v2|userA|collectionA|docA|$field|2|$field",
        true,
    )

    private fun emptyFfiResult(): FfiResult = FfiResult(emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), null, null)
}
