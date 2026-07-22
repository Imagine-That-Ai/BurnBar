package com.openburnbar.data.cloud

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.openburnbar_domain_ffi.CloudVaultSearchOperation as FfiSearchOperation
import uniffi.openburnbar_domain_ffi.CloudVaultSearchResult

class CloudVaultSearchDomainCoreTest {
    @After
    fun tearDown() {
        CloudVaultSearchDomainCore.resetTestOverrides()
    }

    @Test
    fun shadowIsLegacyAuthoritativeAndReportsOnlySanitizedMismatchDimensions() {
        val key = ByteArray(32) { it.toByte() }
        val originalKey = key.copyOf()
        val legacyExpected = listOf("036d74bea5b27eeb229f4d0e568a3f60", "197b29ae439a587e88c4d9ab6e77211b")
        val diagnostics = mutableListOf<CloudVaultSearchDiagnostic>()
        val comparisons = mutableListOf<CloudVaultShadowComparison>()
        var nativeCalls = 0
        var loweredKey: ByteArray? = null
        CloudVaultSearchDomainCore.modeOverride = CloudVaultSearchMode.SHADOW
        CloudVaultSearchDomainCore.abiVersionOverride = { 3u }
        CloudVaultSearchDomainCore.coreVersionOverride = { "0.1.0" }
        CloudVaultSearchDomainCore.diagnosticOverride = diagnostics::add
        CloudVaultSearchDomainCore.comparisonOverride = comparisons::add
        CloudVaultSearchDomainCore.nativeSearchOverride = { request ->
            nativeCalls += 1
            loweredKey = request.vaultKey
            CloudVaultSearchResult(request.operation, legacyExpected.reversed())
        }

        val result = CloudVaultCrypto.tokenHashes("vault isolation", key, limit = 10)

        assertEquals(legacyExpected, result)
        assertEquals(1, nativeCalls)
        assertTrue(key.contentEquals(originalKey))
        assertTrue(requireNotNull(loweredKey).all { it == 0.toByte() })
        assertEquals(
            listOf(CloudVaultSearchDiagnostic("token_mismatch", "0.1.0", 1)),
            diagnostics,
        )
        assertEquals("mismatch", comparisons.single().outcome)
        assertEquals("result_mismatch", comparisons.single().mismatchCategory)
        assertTrue(comparisons.single().legacyMicros in 0..600_000_000)
        assertTrue(comparisons.single().rustMicros in 0..600_000_000)
    }

    @Test
    fun shadowReturnsLegacyWhenNativeIsUnavailable() {
        val diagnostics = mutableListOf<CloudVaultSearchDiagnostic>()
        val comparisons = mutableListOf<CloudVaultShadowComparison>()
        CloudVaultSearchDomainCore.modeOverride = CloudVaultSearchMode.SHADOW
        CloudVaultSearchDomainCore.abiVersionOverride = { 3u }
        CloudVaultSearchDomainCore.coreVersionOverride = { "unavailable" }
        CloudVaultSearchDomainCore.diagnosticOverride = diagnostics::add
        CloudVaultSearchDomainCore.comparisonOverride = comparisons::add
        CloudVaultSearchDomainCore.nativeSearchOverride = { throw UnsatisfiedLinkError("test native unavailable") }

        assertEquals(emptyList<String>(), CloudVaultCrypto.searchIndexTokenHashes("bounded search", ByteArray(32), 0))
        assertEquals(
            listOf(CloudVaultSearchDiagnostic("index_rust_error", "unavailable", 1)),
            diagnostics,
        )
        assertEquals("native_error", comparisons.single().mismatchCategory)
        assertTrue(comparisons.single().rustMicros in 0..600_000_000)
    }

    @Test
    fun shadowMatchCoversEveryOperationAndEmitsPromotionSafeEvidence() {
        val comparisons = mutableListOf<CloudVaultShadowComparison>()
        val loweredKeys = mutableListOf<ByteArray>()
        CloudVaultSearchDomainCore.modeOverride = CloudVaultSearchMode.SHADOW
        CloudVaultSearchDomainCore.abiVersionOverride = { 3u }
        CloudVaultSearchDomainCore.coreVersionOverride = { "1.2.3-beta.1" }
        CloudVaultSearchDomainCore.comparisonOverride = comparisons::add
        CloudVaultSearchDomainCore.nativeSearchOverride = { request ->
            loweredKeys += request.vaultKey
            CloudVaultSearchResult(request.operation, listOf("same-${request.operation.name.lowercase()}"))
        }

        CloudVaultSearchOperation.entries.forEach { operation ->
            val expected = listOf("same-${operation.diagnosticName}")
            val result = CloudVaultSearchDomainCore.search(
                operation,
                "bounded input",
                ByteArray(32) { 0x5a.toByte() },
                16,
            ) { expected }
            assertEquals(expected, result)
        }

        assertEquals(CloudVaultSearchOperation.entries.map { it.diagnosticName }, comparisons.map { it.operation })
        comparisons.forEach { comparison ->
            assertEquals("cloudvault", comparison.domain)
            assertEquals("search", comparison.slice)
            assertEquals("android", comparison.consumer)
            assertEquals("1.2.3-beta.1", comparison.coreVersion)
            assertEquals("match", comparison.outcome)
            assertNull(comparison.mismatchCategory)
            assertTrue(comparison.legacyMicros in 0..600_000_000)
            assertTrue(comparison.rustMicros in 0..600_000_000)
        }
        assertTrue(loweredKeys.all { key -> key.all { it == 0.toByte() } })
    }

    @Test
    fun legacyModeDoesNotTouchAbiVersionNativeSearchOrEvidence() {
        var abiCalls = 0
        var nativeCalls = 0
        val comparisons = mutableListOf<CloudVaultShadowComparison>()
        CloudVaultSearchDomainCore.modeOverride = CloudVaultSearchMode.LEGACY
        CloudVaultSearchDomainCore.abiVersionOverride = {
            abiCalls += 1
            3u
        }
        CloudVaultSearchDomainCore.nativeSearchOverride = { request ->
            nativeCalls += 1
            CloudVaultSearchResult(request.operation, listOf("rust"))
        }
        CloudVaultSearchDomainCore.comparisonOverride = comparisons::add

        val expected = listOf("legacy")
        val actual = CloudVaultSearchDomainCore.search(
            CloudVaultSearchOperation.SEMANTIC,
            "local only",
            ByteArray(32),
            1,
        ) { expected }

        assertTrue(expected === actual)
        assertEquals(0, abiCalls)
        assertEquals(0, nativeCalls)
        assertTrue(comparisons.isEmpty())
    }

    @Test
    fun rustModeFailsClosedWithoutEvaluatingLegacy() {
        var legacyCalls = 0
        CloudVaultSearchDomainCore.modeOverride = CloudVaultSearchMode.RUST
        CloudVaultSearchDomainCore.abiVersionOverride = { 3u }
        CloudVaultSearchDomainCore.nativeSearchOverride = { throw UnsatisfiedLinkError("test native unavailable") }

        assertThrows(UnsatisfiedLinkError::class.java) {
            CloudVaultSearchDomainCore.search(
                CloudVaultSearchOperation.QUERY,
                "query",
                ByteArray(32),
                10,
            ) {
                legacyCalls += 1
                emptyList()
            }
        }
        assertEquals(0, legacyCalls)
    }

    @Test
    fun rustModeRejectsTamperedOperationAndOversizedLimitWithoutFallback() {
        var legacyCalls = 0
        CloudVaultSearchDomainCore.modeOverride = CloudVaultSearchMode.RUST
        CloudVaultSearchDomainCore.abiVersionOverride = { 3u }
        CloudVaultSearchDomainCore.nativeSearchOverride = { request ->
            if (request.limit > 1024) throw IllegalArgumentException("bounded native rejection")
            CloudVaultSearchResult(FfiSearchOperation.SEMANTIC, emptyList())
        }

        assertThrows(IllegalStateException::class.java) {
            CloudVaultSearchDomainCore.search(
                CloudVaultSearchOperation.TOKEN,
                "tampered",
                ByteArray(32),
                1,
            ) {
                legacyCalls += 1
                emptyList()
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            CloudVaultSearchDomainCore.search(
                CloudVaultSearchOperation.TOKEN,
                "oversized",
                ByteArray(32),
                1025,
            ) {
                legacyCalls += 1
                emptyList()
            }
        }
        assertEquals(0, legacyCalls)
    }

    @Test
    fun abiMismatchFailsClosedInRustAndRemainsLegacyAuthoritativeInShadow() {
        val diagnostics = mutableListOf<CloudVaultSearchDiagnostic>()
        var nativeCalls = 0
        var legacyCalls = 0
        CloudVaultSearchDomainCore.abiVersionOverride = { 4u }
        CloudVaultSearchDomainCore.coreVersionOverride = { "0.1.0" }
        CloudVaultSearchDomainCore.diagnosticOverride = diagnostics::add
        CloudVaultSearchDomainCore.nativeSearchOverride = { request ->
            nativeCalls += 1
            CloudVaultSearchResult(request.operation, emptyList())
        }

        CloudVaultSearchDomainCore.modeOverride = CloudVaultSearchMode.RUST
        assertThrows(IllegalStateException::class.java) {
            CloudVaultSearchDomainCore.search(CloudVaultSearchOperation.TOKEN, "bounded", ByteArray(32), 1) {
                legacyCalls += 1
                listOf("legacy")
            }
        }
        assertEquals(0, legacyCalls)
        assertEquals(0, nativeCalls)

        CloudVaultSearchDomainCore.modeOverride = CloudVaultSearchMode.SHADOW
        assertEquals(
            listOf("legacy"),
            CloudVaultSearchDomainCore.search(CloudVaultSearchOperation.TOKEN, "bounded", ByteArray(32), 1) {
                legacyCalls += 1
                listOf("legacy")
            },
        )
        assertEquals(1, legacyCalls)
        assertEquals(0, nativeCalls)
        assertEquals(
            listOf(CloudVaultSearchDiagnostic("token_rust_error", "0.1.0", 1)),
            diagnostics,
        )
    }

    @Test
    fun modeParserIsExplicitAndFailClosed() {
        assertEquals(CloudVaultSearchMode.LEGACY, CloudVaultSearchMode.parse(" legacy "))
        assertEquals(CloudVaultSearchMode.SHADOW, CloudVaultSearchMode.parse("SHADOW"))
        assertEquals(CloudVaultSearchMode.RUST, CloudVaultSearchMode.parse("rust"))
        assertEquals(CloudVaultSearchMode.LEGACY, CloudVaultSearchMode.parse(""))
        assertEquals(CloudVaultSearchMode.LEGACY, CloudVaultSearchMode.parse("fallback"))
    }
}
