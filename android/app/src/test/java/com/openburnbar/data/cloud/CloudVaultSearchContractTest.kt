package com.openburnbar.data.cloud

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudVaultSearchContractTest {
    @Test
    fun tokenizationAndSemanticFeaturesMatchSharedContract() {
        val fixture = loadFixture()
        assertEquals("openburnbar.domain-core.cloudvault.search.v1", fixture.string("schema"))

        for (element in fixture.array("tokenizationCases")) {
            val testCase = element.jsonObject
            val id = testCase.string("id")
            val text = testCase.string("text")
            assertEquals(id, testCase.strings("normalizedTokens"), CloudVaultCryptoSearch.normalizedTokens(text))
            assertEquals(id, testCase.strings("exactPhraseTokens"), CloudVaultCryptoSearch.exactPhraseTokensForContract(text))
        }

        for (element in fixture.array("semanticFeatureCases")) {
            val testCase = element.jsonObject
            assertEquals(
                testCase.string("id"),
                testCase.strings("features"),
                CloudVaultCryptoSearch.semanticFeatureNamesForContract(testCase.string("text")),
            )
        }
    }

    @Test
    fun hashOperationsMatchSharedContractAndRemainBounded() {
        val fixture = loadFixture()
        val primaryKey = fixture.string("primaryKeyHex").hexBytes()
        val alternateKey = fixture.string("alternateKeyHex").hexBytes()
        val isolationOutputs = linkedMapOf<String, MutableList<Set<String>>>()

        for (element in fixture.array("hashCases")) {
            val testCase = element.jsonObject
            val id = testCase.string("id")
            val key = if (testCase.string("key") == "alternate") alternateKey else primaryKey
            val text = testCase.resolvedText()
            val limit = testCase.getValue("limit").jsonPrimitive.int
            val hashes =
                when (testCase.string("operation")) {
                    "token" -> CloudVaultCrypto.tokenHashes(text, key, limit)
                    "index" -> CloudVaultCrypto.searchIndexTokenHashes(text, key, limit)
                    "query" -> CloudVaultCrypto.searchQueryTokenHashes(text, key, limit)
                    "semantic" -> CloudVaultCrypto.semanticHashes(text, key, limit)
                    else -> error("Unknown operation in $id")
                }
            assertEquals(id, testCase.strings("expected"), hashes)
            assertTrue(id, hashes.size <= maxOf(0, limit))

            testCase["isolationGroup"]?.jsonPrimitive?.contentOrNull?.let { group ->
                isolationOutputs.getOrPut(group) { mutableListOf() } += hashes.toSet()
            }
        }

        for ((group, outputs) in isolationOutputs) {
            assertEquals(group, 2, outputs.size)
            assertTrue(group, outputs[0].intersect(outputs[1]).isEmpty())
        }
    }

    private fun loadFixture(): JsonObject {
        val relative = "tests/fixtures/domain-core/cloudvault/v1/cloudvault-search-contract.json"
        val workingDirectory = requireNotNull(System.getProperty("user.dir"))
        val fixture =
            generateSequence(File(workingDirectory).absoluteFile) { it.parentFile }
                .map { File(it, relative) }
                .firstOrNull(File::isFile)
                ?: error("Unable to locate $relative from $workingDirectory")
        return Json.parseToJsonElement(fixture.readText()).jsonObject
    }
}

private fun JsonObject.string(name: String): String = getValue(name).jsonPrimitive.content

private fun JsonObject.array(name: String): JsonArray = getValue(name).jsonArray

private fun JsonObject.strings(name: String): List<String> = array(name).map { it.jsonPrimitive.content }

private fun JsonObject.resolvedText(): String {
    this["text"]?.jsonPrimitive?.contentOrNull?.let { return it }
    val input = getValue("input").jsonObject
    require(input.string("kind") == "numberedTokens")
    val prefix = input.string("prefix")
    val count = input.getValue("count").jsonPrimitive.int
    require(count >= 0)
    return (0 until count).joinToString(" ") { "$prefix$it" }
}

private fun String.hexBytes(): ByteArray {
    require(length % 2 == 0)
    return chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
