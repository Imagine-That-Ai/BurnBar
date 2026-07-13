package com.openburnbar.data.cloud

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CloudVaultDomainCoreTest {
    @After
    fun tearDown() {
        CloudVaultDomainCore.resetTestOverrides()
    }

    @Test
    fun canonicalC1aKnownAnswersMatchKotlinLegacy() {
        CloudVaultDomainCore.modeOverride = CloudVaultDomainCoreMode.LEGACY
        val fixture = canonicalFixture()

        fixture.array("aad").forEach { element ->
            val vector = element.jsonObject
            val context = CloudVaultAADContext(
                uid = vector.string("uid"),
                collection = vector.string("collection"),
                docID = vector.string("docID"),
                field = vector.string("field"),
                schemaVersion = vector.int("schemaVersion"),
                purpose = vector.string("purpose"),
            )
            assertEquals(vector.string("v1"), context.legacyV1StringValue)
            assertEquals(vector.string("v2"), context.stringValue)
        }
        fixture.array("sha256").forEach { element ->
            val vector = element.jsonObject
            assertEquals(vector.string("hex"), CloudVaultCrypto.sha256Hex(vector.hex("dataHex")))
        }
        fixture.array("vaultKeyID").forEach { element ->
            val vector = element.jsonObject
            assertEquals(vector.string("value"), CloudVaultCrypto.vaultKeyID(vector.hex("keyHex")))
        }
        fixture.array("keyedHashes").forEach { element ->
            val vector = element.jsonObject
            val purpose = CloudVaultHashPurpose.entries.single { it.wireValue == vector.string("purpose") }
            assertEquals(
                vector.string("hex"),
                CloudVaultDomainCore.keyedHashHex(vector.hex("dataHex"), vector.hex("keyHex"), purpose),
            )
        }

        val data = "the quick brown fox jumps over the lazy dog".toByteArray()
        val key = fixture.array("vaultKeyID").first().jsonObject.hex("keyHex")
        fixture.array("expectedSessionBodyHash").forEach { element ->
            val vector = element.jsonObject
            assertEquals(
                vector.string("hex"),
                CloudVaultCrypto.expectedSessionBodyHash(data, key, vector.int("bodyHashVersion")),
            )
        }
    }

    @Test
    fun canonicalC1bAesKnownAnswersMatchKotlinLegacy() {
        CloudVaultDomainCore.modeOverride = CloudVaultDomainCoreMode.LEGACY
        canonicalFixture().array("aesGcm").forEach { element ->
            val vector = element.jsonObject
            val key = vector.hex("keyHex")
            val nonce = vector.hex("nonceHex")
            val plaintext = vector.hex("plaintextHex")
            val aad = vector.hex("aadHex")
            val sealed = CloudVaultDomainCore.aesSealDetached(plaintext, key, nonce, aad)

            assertArrayEquals(nonce, sealed.nonce)
            assertArrayEquals(vector.hex("ciphertextHex"), sealed.ciphertext)
            assertArrayEquals(vector.hex("tagHex"), sealed.tag)
            val combined = CloudVaultDomainCore.aesSealCombined(plaintext, key, nonce, aad)
            assertEquals(vector.string("combinedBase64"), CloudVaultDomainCore.base64Encode(combined))
            assertArrayEquals(plaintext, CloudVaultDomainCore.aesOpenCombined(combined, key, aad))
        }
    }

    @Test
    fun allVaultKeyOperationsRejectNon32ByteKeys() {
        listOf(ByteArray(0), ByteArray(31), ByteArray(33)).forEach { key ->
            assertThrows(IllegalArgumentException::class.java) { CloudVaultCrypto.vaultKeyID(key) }
            assertThrows(IllegalArgumentException::class.java) { CloudVaultCrypto.blobPlaintextHmac(byteArrayOf(1), key) }
            assertThrows(IllegalArgumentException::class.java) { CloudVaultCrypto.sessionBodyHash(byteArrayOf(1), key) }
            assertThrows(IllegalArgumentException::class.java) { CloudVaultCrypto.sessionChunkHash("x", key) }
            assertThrows(IllegalArgumentException::class.java) { CloudVaultCrypto.projectMemoryContentHash(byteArrayOf(1), key) }
        }
    }

    @Test
    fun sealedTextFutureSchemaFailsClosed() {
        CloudVaultDomainCore.modeOverride = CloudVaultDomainCoreMode.LEGACY
        val key = ByteArray(32)
        val envelope = CloudVaultCrypto.sealText("future", key).copy(
            schemaVersion = CloudVaultCrypto.CURRENT_SEALED_TEXT_SCHEMA_VERSION + 1,
        )

        assertThrows(IllegalArgumentException::class.java) {
            CloudVaultCrypto.openText(envelope, key)
        }
    }

    @Test
    fun shadowReturnsLegacyAndReportsOnlySanitizedDimensions() {
        val diagnostics = mutableListOf<CloudVaultDomainCoreDiagnostic>()
        CloudVaultDomainCore.diagnosticOverride = diagnostics::add
        var legacyCalls = 0
        var rustCalls = 0

        val result = CloudVaultDomainCore.dispatchForTest(
            selectedMode = CloudVaultDomainCoreMode.SHADOW,
            operation = "session_body",
            legacy = {
                legacyCalls += 1
                "legacy-value"
            },
            rust = {
                rustCalls += 1
                "rust-value"
            },
        )

        assertEquals("legacy-value", result)
        assertEquals(1, legacyCalls)
        assertEquals(1, rustCalls)
        assertEquals(
            listOf(CloudVaultDomainCoreDiagnostic("session_body", 3, "mismatch", 1)),
            diagnostics,
        )
    }

    @Test
    fun productionRustModeFailsClosedBeforeCallingAnAbiMismatch() {
        CloudVaultDomainCore.modeOverride = CloudVaultDomainCoreMode.RUST
        CloudVaultDomainCore.abiVersionOverride = { 4u }

        assertThrows(IllegalStateException::class.java) {
            CloudVaultCrypto.vaultKeyID(ByteArray(32))
        }
    }

    @Test
    fun rustModeNeverEvaluatesLegacy() {
        var legacyCalls = 0
        var rustCalls = 0
        val result = CloudVaultDomainCore.dispatchForTest(
            selectedMode = CloudVaultDomainCoreMode.RUST,
            operation = "vault_key_id",
            legacy = {
                legacyCalls += 1
                "legacy"
            },
            rust = {
                rustCalls += 1
                "rust"
            },
        )

        assertEquals("rust", result)
        assertEquals(0, legacyCalls)
        assertEquals(1, rustCalls)
    }

    private fun canonicalFixture(): JsonObject {
        val resource = checkNotNull(javaClass.classLoader?.getResourceAsStream("cloudvault-deterministic-kat.json"))
        return resource.bufferedReader().use { Json.parseToJsonElement(it.readText()).jsonObject }
    }

    private fun JsonObject.array(name: String): JsonArray = getValue(name).jsonArray
    private fun JsonObject.string(name: String): String = getValue(name).jsonPrimitive.content
    private fun JsonObject.int(name: String): Int = getValue(name).jsonPrimitive.int
    private fun JsonObject.hex(name: String): ByteArray = string(name).chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
