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
import org.junit.Assert.assertEquals
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
    }

    private fun JsonObject.string(name: String): String = getValue(name).jsonPrimitive.content
    private fun JsonObject.int(name: String): Int = getValue(name).jsonPrimitive.int
    private fun JsonObject.hex(name: String): ByteArray = string(name).chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
