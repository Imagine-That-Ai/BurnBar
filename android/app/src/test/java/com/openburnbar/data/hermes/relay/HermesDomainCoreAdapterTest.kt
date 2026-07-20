package com.openburnbar.data.hermes.relay

import android.util.Log
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HermesDomainCoreAdapterTest {
    @After
    fun restoreAndroidLog() {
        System.clearProperty("openburnbar.domain_core.hermes.mode")
        HermesDomainCoreAdapter.resetTestOverrides()
        unmockkStatic(Log::class)
    }

    @Test
    fun `shadow generic adapter records native unavailable without leaking the failure`() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        System.setProperty("openburnbar.domain_core.hermes.mode", "shadow")
        val mode = HermesDomainCoreMode.resolve()
        val expected = String(charArrayOf('l', 'e', 'g', 'a', 'c', 'y'))
        val comparisons = mutableListOf<HermesShadowComparison>()
        HermesDomainCoreAdapter.comparisonOverride = comparisons::add
        HermesDomainCoreAdapter.abiVersionOverride = { error("secret native loader detail") }
        HermesDomainCoreAdapter.coreVersionOverride = { error("must not query version") }

        val actual = HermesDomainCoreAdapter.safetyCode(byteArrayOf(0x01), byteArrayOf(0x02)) { expected }

        if (mode == HermesDomainCoreMode.SHADOW) {
            assertTrue(expected === actual)
            assertEquals(
                HermesShadowComparison(
                    slice = "payload-keywrap",
                    operation = "safety_code",
                    coreVersion = "0.0.0-native-unavailable",
                    outcome = "mismatch",
                    mismatchCategory = "native_unavailable",
                    legacyMicros = comparisons.single().legacyMicros,
                    rustMicros = 0,
                    observedAt = comparisons.single().observedAt,
                ),
                comparisons.single(),
            )
            verify(exactly = 1) {
                Log.w("OpenBurnBarDomainCore", "domain_core.hermes.safety_code native_unavailable")
            }
        } else {
            assertEquals(HermesDomainCoreMode.LEGACY, mode)
            assertSame(expected, actual)
            assertTrue(comparisons.isEmpty())
            verify(exactly = 0) { Log.w(any(), any<String>()) }
        }
    }

    @Test
    fun `shadow generic adapter records ABI mismatch without querying native version`() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        System.setProperty("openburnbar.domain_core.hermes.mode", "shadow")
        val mode = HermesDomainCoreMode.resolve()
        val expected = byteArrayOf(0x00, 0x7f, 0xff.toByte())
        val comparisons = mutableListOf<HermesShadowComparison>()
        HermesDomainCoreAdapter.comparisonOverride = comparisons::add
        HermesDomainCoreAdapter.abiVersionOverride = { 2u }
        HermesDomainCoreAdapter.coreVersionOverride = { error("must not query version") }

        val actual = HermesDomainCoreAdapter.open("sensitive ciphertext", byteArrayOf(0x01), byteArrayOf(0x02)) { expected }

        if (mode == HermesDomainCoreMode.SHADOW) {
            assertArrayEquals(expected, actual)
            assertEquals("payload-keywrap", comparisons.single().slice)
            assertEquals("open", comparisons.single().operation)
            assertEquals("0.0.0-abi-mismatch", comparisons.single().coreVersion)
            assertEquals("mismatch", comparisons.single().outcome)
            assertEquals("native_error", comparisons.single().mismatchCategory)
            assertEquals(0, comparisons.single().rustMicros)
            verify(exactly = 1) {
                Log.w("OpenBurnBarDomainCore", "domain_core.hermes.open abi_mismatch")
            }
        } else {
            assertEquals(HermesDomainCoreMode.LEGACY, mode)
            assertSame(expected, actual)
            assertTrue(comparisons.isEmpty())
            verify(exactly = 0) { Log.w(any(), any<String>()) }
        }
    }

    @Test
    fun `shadow returns exact legacy bytes when rust throws`() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        val expected = byteArrayOf(0x00, 0x7f, 0xff.toByte())
        val comparisons = mutableListOf<HermesShadowComparison>()
        HermesDomainCoreAdapter.comparisonOverride = comparisons::add
        HermesDomainCoreAdapter.coreVersionOverride = { "1.2.3" }

        val actual = HermesDomainCoreAdapter.selectValueWhenNativeAvailable(
            operation = "bounded_input",
            mode = HermesDomainCoreMode.SHADOW,
            legacy = { expected },
            rust = { error("sensitive Rust failure") },
            equivalent = ByteArray::contentEquals,
        )

        assertArrayEquals(expected, actual)
        verify(exactly = 1) {
            Log.w("OpenBurnBarDomainCore", "domain_core.hermes.bounded_input native_error")
        }
        assertEquals(1, comparisons.size)
        assertEquals("hermes", comparisons.single().domain)
        assertEquals("payload-keywrap", comparisons.single().slice)
        assertEquals("android", comparisons.single().consumer)
        assertEquals("native_error", comparisons.single().mismatchCategory)
        assertEquals("1.2.3", comparisons.single().coreVersion)
    }

    @Test
    fun `shadow returns exact legacy string when rust throws`() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        val expected = String(charArrayOf('1', '2', '3', '4'))

        val actual = HermesDomainCoreAdapter.selectValueWhenNativeAvailable(
            operation = "safety_code",
            mode = HermesDomainCoreMode.SHADOW,
            legacy = { expected },
            rust = { error("sensitive Rust failure") },
            equivalent = String::equals,
        )

        assertTrue(expected === actual)
        verify(exactly = 1) {
            Log.w("OpenBurnBarDomainCore", "domain_core.hermes.safety_code native_error")
        }
    }

    @Test
    fun `hpke adapter emits the required promotion slice`() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        System.setProperty("openburnbar.domain_core.hermes.mode", "shadow")
        val mode = HermesDomainCoreMode.resolve()
        val expected = "OpenBurnBar-HermesRelay-HPKE-v3|aad".toByteArray()
        val comparisons = mutableListOf<HermesShadowComparison>()
        HermesDomainCoreAdapter.comparisonOverride = comparisons::add

        val actual = HermesDomainCoreAdapter.hpkeV3Info("aad".toByteArray()) { expected }

        if (mode == HermesDomainCoreMode.SHADOW) {
            assertArrayEquals(expected, actual)
            assertEquals("hpke_v3_info", comparisons.single().operation)
            assertEquals("hpke-info", comparisons.single().slice)
        } else {
            assertEquals(HermesDomainCoreMode.LEGACY, mode)
            assertSame(expected, actual)
            assertTrue(comparisons.isEmpty())
            verify(exactly = 0) { Log.w(any(), any<String>()) }
        }
    }

    @Test
    fun `shadow generic selector records match and mismatch with bounded timings`() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        val expected = byteArrayOf(0x00, 0x7f, 0xff.toByte())
        val comparisons = mutableListOf<HermesShadowComparison>()
        HermesDomainCoreAdapter.comparisonOverride = comparisons::add
        HermesDomainCoreAdapter.coreVersionOverride = { "1.4.0-beta.2" }

        val matched = HermesDomainCoreAdapter.selectValueWhenNativeAvailable(
            operation = "aad",
            mode = HermesDomainCoreMode.SHADOW,
            legacy = { expected },
            rust = { expected.copyOf() },
            equivalent = ByteArray::contentEquals,
        )
        val mismatched = HermesDomainCoreAdapter.selectValueWhenNativeAvailable(
            operation = "ratchet_open",
            mode = HermesDomainCoreMode.SHADOW,
            legacy = { expected },
            rust = { byteArrayOf(0x01) },
            equivalent = ByteArray::contentEquals,
        )

        assertSame(expected, matched)
        assertSame(expected, mismatched)
        assertEquals(listOf("match", "mismatch"), comparisons.map { it.outcome })
        assertEquals(listOf(null, "result_mismatch"), comparisons.map { it.mismatchCategory })
        assertEquals(listOf("aad", "ratchet"), comparisons.map { it.slice })
        comparisons.forEach { comparison ->
            assertEquals("1.4.0-beta.2", comparison.coreVersion)
            assertTrue(comparison.legacyMicros in 0..600_000_000)
            assertTrue(comparison.rustMicros in 0..600_000_000)
        }
    }

    @Test
    fun `shadow special seal paths contain native loader failure and preserve legacy outputs`() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        System.setProperty("openburnbar.domain_core.hermes.mode", "shadow")
        val mode = HermesDomainCoreMode.resolve()
        val legacyCiphertext = String(charArrayOf('n', 'o', 't', '-', 'b', 'a', 's', 'e', '6', '4'))
        val legacyCombined = byteArrayOf(0x01, 0x02)
        val comparisons = mutableListOf<HermesShadowComparison>()
        HermesDomainCoreAdapter.comparisonOverride = comparisons::add
        HermesDomainCoreAdapter.abiVersionOverride = { 3u }
        HermesDomainCoreAdapter.coreVersionOverride = { "1.4.0" }

        val sealed = HermesDomainCoreAdapter.seal(ByteArray(1), ByteArray(32), ByteArray(0)) { legacyCiphertext }
        val combined = HermesDomainCoreAdapter.sealCombined(ByteArray(1), ByteArray(32), ByteArray(0)) { legacyCombined }

        if (mode == HermesDomainCoreMode.SHADOW) {
            assertSame(legacyCiphertext, sealed)
            assertSame(legacyCombined, combined)
            assertEquals(listOf("mismatch", "mismatch"), comparisons.map { it.outcome })
            assertTrue(comparisons.all { it.mismatchCategory == "native_error" })
            assertEquals(listOf("payload-keywrap", "ratchet"), comparisons.map { it.slice })
            comparisons.forEach { comparison ->
                assertTrue(comparison.legacyMicros in 0..600_000_000)
                assertTrue(comparison.rustMicros in 0..600_000_000)
            }
        } else {
            assertEquals(HermesDomainCoreMode.LEGACY, mode)
            assertSame(legacyCiphertext, sealed)
            assertSame(legacyCombined, combined)
            assertTrue(comparisons.isEmpty())
            verify(exactly = 0) { Log.w(any(), any<String>()) }
        }
    }

    @Test
    fun `special seal paths contain ABI unavailability in shadow and fail closed in rust`() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        val comparisons = mutableListOf<HermesShadowComparison>()
        HermesDomainCoreAdapter.comparisonOverride = comparisons::add
        HermesDomainCoreAdapter.abiVersionOverride = { 2u }
        HermesDomainCoreAdapter.coreVersionOverride = { error("must not query native version") }
        val legacyString = String(charArrayOf('l', 'e', 'g', 'a', 'c', 'y'))
        val legacyBytes = byteArrayOf(0x10, 0x20)

        System.setProperty("openburnbar.domain_core.hermes.mode", "shadow")
        val shadowMode = HermesDomainCoreMode.resolve()
        val shadowString = HermesDomainCoreAdapter.seal(ByteArray(1), ByteArray(32), ByteArray(0)) { legacyString }
        val shadowBytes = HermesDomainCoreAdapter.sealCombined(ByteArray(1), ByteArray(32), ByteArray(0)) { legacyBytes }

        if (shadowMode == HermesDomainCoreMode.SHADOW) {
            assertSame(legacyString, shadowString)
            assertSame(legacyBytes, shadowBytes)
            assertEquals(listOf("seal", "ratchet_seal"), comparisons.map { it.operation })
            assertTrue(comparisons.all { it.coreVersion == "0.0.0-abi-mismatch" })
            assertTrue(comparisons.all { it.mismatchCategory == "native_error" && it.rustMicros == 0L })
        } else {
            assertEquals(HermesDomainCoreMode.LEGACY, shadowMode)
            assertSame(legacyString, shadowString)
            assertSame(legacyBytes, shadowBytes)
            assertTrue(comparisons.isEmpty())
            verify(exactly = 0) { Log.w(any(), any<String>()) }
        }

        System.setProperty("openburnbar.domain_core.hermes.mode", "rust")
        val rustMode = HermesDomainCoreMode.resolve()
        var legacyCalls = 0
        if (rustMode == HermesDomainCoreMode.RUST) {
            assertThrows(IllegalStateException::class.java) {
                HermesDomainCoreAdapter.seal(ByteArray(1), ByteArray(32), ByteArray(0)) {
                    legacyCalls += 1
                    legacyString
                }
            }
            assertThrows(IllegalStateException::class.java) {
                HermesDomainCoreAdapter.sealCombined(ByteArray(1), ByteArray(32), ByteArray(0)) {
                    legacyCalls += 1
                    legacyBytes
                }
            }
            assertEquals(0, legacyCalls)
        } else {
            assertEquals(HermesDomainCoreMode.LEGACY, rustMode)
            val legacySealed = HermesDomainCoreAdapter.seal(ByteArray(1), ByteArray(32), ByteArray(0)) {
                legacyCalls += 1
                legacyString
            }
            val legacyCombined = HermesDomainCoreAdapter.sealCombined(ByteArray(1), ByteArray(32), ByteArray(0)) {
                legacyCalls += 1
                legacyBytes
            }
            assertSame(legacyString, legacySealed)
            assertSame(legacyBytes, legacyCombined)
            assertEquals(2, legacyCalls)
            assertTrue(comparisons.isEmpty())
            verify(exactly = 0) { Log.w(any(), any<String>()) }
        }
    }

    @Test
    fun `reset clears every native and evidence override`() {
        HermesDomainCoreAdapter.comparisonOverride = { }
        HermesDomainCoreAdapter.abiVersionOverride = { 3u }
        HermesDomainCoreAdapter.coreVersionOverride = { "1.0.0" }

        HermesDomainCoreAdapter.resetTestOverrides()

        assertNull(HermesDomainCoreAdapter.comparisonOverride)
        assertNull(HermesDomainCoreAdapter.abiVersionOverride)
        assertNull(HermesDomainCoreAdapter.coreVersionOverride)
    }

    @Test
    fun `rust mode propagates failure without invoking legacy`() {
        var legacyInvoked = false

        assertThrows(IllegalStateException::class.java) {
            HermesDomainCoreAdapter.selectValueWhenNativeAvailable(
                operation = "bounded_input",
                mode = HermesDomainCoreMode.RUST,
                legacy = {
                    legacyInvoked = true
                    byteArrayOf(0x01)
                },
                rust = { error("Rust failure") },
                equivalent = ByteArray::contentEquals,
            )
        }

        assertFalse(legacyInvoked)
    }

    @Test
    fun `hkdf length conversion rejects zero negative overflow and core overflow`() {
        assertTrue(HermesDomainCoreAdapter.checkedHkdfLength(32) == 32u)
        listOf(0, -1, 255 * 32 + 1, Int.MAX_VALUE).forEach { invalid ->
            assertThrows(IllegalArgumentException::class.java) {
                HermesDomainCoreAdapter.checkedHkdfLength(invalid)
            }
        }
    }
}
