package com.openburnbar.data.cloud

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import uniffi.openburnbar_domain_ffi.CloudVaultSearchResult

class CloudVaultSearchChunkerTest {
    @After
    fun tearDown() {
        CloudVaultSearchDomainCore.resetTestOverrides()
    }

    @Test
    fun denseShortTokensAreSplitWithoutLossBeforeNativeSearch() {
        val text = List(5_000) { "aa" }.joinToString(" ")
        val reservedText = "session title provider"

        val chunks =
            CloudVaultSearchChunker.chunkUtf8String(
                text = text,
                maxBytes = 16_000,
                reservedText = reservedText,
            )

        assertEquals(text, chunks.joinToString(separator = ""))
        assertTrue(chunks.size > 1)
        for (chunk in chunks) {
            assertTrue(chunk.toByteArray(Charsets.UTF_8).size <= 16_000)
            assertTrue(
                CloudVaultSearchChunker.conservativeTokenCount("$chunk $reservedText") <=
                    CloudVaultSearchChunker.MAX_EXTRACTED_TOKENS,
            )
        }
    }

    @Test
    fun unicodeScalarsAreNeverSplitAcrossByteChunks() {
        val text = "alpha 😀 beta 東京 gamma"

        val chunks =
            CloudVaultSearchChunker.chunkUtf8String(
                text = text,
                maxBytes = 8,
                reservedText = "title",
            )

        assertEquals(text, chunks.joinToString(separator = ""))
        assertTrue(chunks.all { it.toByteArray(Charsets.UTF_8).size <= 8 })
    }

    @Test
    fun oversizedReservedContextIsRejectedBeforeIndexing() {
        val reservedText = List(CloudVaultSearchChunker.MAX_EXTRACTED_TOKENS) { "x" }.joinToString(" ")

        try {
            CloudVaultSearchChunker.chunkUtf8String("body", 16_000, reservedText)
            fail("Expected oversized search context to be rejected")
        } catch (error: IllegalArgumentException) {
            assertTrue(error.message.orEmpty().contains("context"))
        }
    }

    @Test
    fun everyDenseChunkFitsOneRustIndexCall() {
        val text = List(5_000) { "aa" }.joinToString(" ")
        val reservedText = "session title provider"
        val chunks = CloudVaultSearchChunker.chunkUtf8String(text, 16_000, reservedText)
        var nativeCalls = 0
        CloudVaultSearchDomainCore.modeOverride = CloudVaultSearchMode.RUST
        CloudVaultSearchDomainCore.abiVersionOverride = { 3u }
        CloudVaultSearchDomainCore.nativeSearchOverride = { request ->
            assertTrue(
                CloudVaultSearchChunker.conservativeTokenCount(request.text) <=
                    CloudVaultSearchChunker.MAX_EXTRACTED_TOKENS,
            )
            nativeCalls += 1
            CloudVaultSearchResult(request.operation, emptyList())
        }

        for (chunk in chunks) {
            CloudVaultCrypto.searchIndexTokenHashes("$chunk $reservedText", ByteArray(32), 1_024)
        }

        assertEquals(chunks.size, nativeCalls)
    }
}
