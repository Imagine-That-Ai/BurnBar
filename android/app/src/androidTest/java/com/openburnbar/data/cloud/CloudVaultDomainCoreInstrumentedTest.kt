package com.openburnbar.data.cloud

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.serialization.json.Json
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
import org.junit.runner.RunWith
import uniffi.openburnbar_domain_ffi.domainCoreAbiVersion

@RunWith(AndroidJUnit4::class)
class CloudVaultDomainCoreInstrumentedTest {
    @After
    fun tearDown() {
        CloudVaultDomainCore.resetTestOverrides()
    }

    @Test
    fun abiTwoRustModeMatchesCanonicalC1aKnownAnswersOnDevice() {
        CloudVaultDomainCore.modeOverride = CloudVaultDomainCoreMode.RUST
        assertEquals(2u, domainCoreAbiVersion())
        val context = InstrumentationRegistry.getInstrumentation().context
        val fixture = context.assets.open("cloudvault-deterministic-kat.json").bufferedReader().use {
            Json.parseToJsonElement(it.readText()).jsonObject
        }

        fixture.getValue("aad").jsonArray.forEach { element ->
            val vector = element.jsonObject
            val aad = CloudVaultAADContext(
                uid = vector.string("uid"),
                collection = vector.string("collection"),
                docID = vector.string("docID"),
                field = vector.string("field"),
                schemaVersion = vector.int("schemaVersion"),
                purpose = vector.string("purpose"),
            )
            assertEquals(vector.string("v1"), aad.legacyV1StringValue)
            assertEquals(vector.string("v2"), aad.stringValue)
        }
        fixture.getValue("vaultKeyID").jsonArray.forEach { element ->
            val vector = element.jsonObject
            assertEquals(vector.string("value"), CloudVaultCrypto.vaultKeyID(vector.hex("keyHex")))
        }
        fixture.getValue("sha256").jsonArray.forEach { element ->
            val vector = element.jsonObject
            assertEquals(vector.string("hex"), CloudVaultCrypto.sha256Hex(vector.hex("dataHex")))
        }
        fixture.getValue("keyedHashes").jsonArray.forEach { element ->
            val vector = element.jsonObject
            val purpose = CloudVaultHashPurpose.entries.single { it.wireValue == vector.string("purpose") }
            assertEquals(
                vector.string("hex"),
                CloudVaultDomainCore.keyedHashHex(vector.hex("dataHex"), vector.hex("keyHex"), purpose),
            )
        }
        val data = "the quick brown fox jumps over the lazy dog".toByteArray()
        val key = fixture.getValue("vaultKeyID").jsonArray.first().jsonObject.hex("keyHex")
        fixture.getValue("expectedSessionBodyHash").jsonArray.forEach { element ->
            val vector = element.jsonObject
            assertEquals(
                vector.string("hex"),
                CloudVaultCrypto.expectedSessionBodyHash(data, key, vector.int("bodyHashVersion")),
            )
        }

        fixture.getValue("aesGcm").jsonArray.forEach { element ->
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
    fun rustModeRejectsNonCanonicalBase64AuthenticationFailureAndInvalidUtf8() {
        CloudVaultDomainCore.modeOverride = CloudVaultDomainCoreMode.RUST
        assertThrows(Exception::class.java) { CloudVaultDomainCore.base64Decode("AA==\n") }

        val key = ByteArray(32)
        val nonce = ByteArray(12)
        val sealed = CloudVaultDomainCore.aesSealCombined("payload".toByteArray(), key, nonce, ByteArray(0))
        sealed[sealed.lastIndex] = (sealed.last().toInt() xor 1).toByte()
        assertThrows(Exception::class.java) {
            CloudVaultDomainCore.aesOpenCombined(sealed, key, ByteArray(0))
        }

        val invalidUtf8 = byteArrayOf(0xc3.toByte(), 0x28)
        val detached = CloudVaultDomainCore.aesSealDetached(invalidUtf8, key, nonce, ByteArray(0))
        assertThrows(Exception::class.java) {
            CloudVaultDomainCore.aesOpenTextDetached(
                detached.nonce,
                detached.ciphertext,
                detached.tag,
                key,
                ByteArray(0),
            )
        }
    }

    private fun JsonObject.string(name: String): String = getValue(name).jsonPrimitive.content
    private fun JsonObject.int(name: String): Int = getValue(name).jsonPrimitive.int
    private fun JsonObject.hex(name: String): ByteArray = string(name).chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
