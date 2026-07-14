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
        val expected = String(charArrayOf('l', 'e', 'g', 'a', 'c', 'y'))
        val comparisons = mutableListOf<HermesShadowComparison>()
        HermesDomainCoreAdapter.comparisonOverride = comparisons::add
        HermesDomainCoreAdapter.abiVersionOverride = { error("secret native loader detail") }
        HermesDomainCoreAdapter.coreVersionOverride = { error("must not query version") }

        val actual = HermesDomainCoreAdapter.safetyCode(byteArrayOf(0x01), byteArrayOf(0x02)) { expected }

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
            ),
            comparisons.single(),
        )
        verify(exactly = 1) {
            Log.w("OpenBurnBarDomainCore", "domain_core.hermes.safety_code native_unavailable")
        }
    }

    @Test
    fun `shadow generic adapter records ABI mismatch without querying native version`() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        System.setProperty("openburnbar.domain_core.hermes.mode", "shadow")
        val expected = byteArrayOf(0x00, 0x7f, 0xff.toByte())
        val comparisons = mutableListOf<HermesShadowComparison>()
        HermesDomainCoreAdapter.comparisonOverride = comparisons::add
        HermesDomainCoreAdapter.abiVersionOverride = { 2u }
        HermesDomainCoreAdapter.coreVersionOverride = { error("must not query version") }

        val actual = HermesDomainCoreAdapter.open("sensitive ciphertext", byteArrayOf(0x01), byteArrayOf(0x02)) { expected }

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
        val expected = "OpenBurnBar-HermesRelay-HPKE-v3|aad".toByteArray()
        val comparisons = mutableListOf<HermesShadowComparison>()
        HermesDomainCoreAdapter.comparisonOverride = comparisons::add

        val actual = HermesDomainCoreAdapter.hpkeV3Info("aad".toByteArray()) { expected }

        assertArrayEquals(expected, actual)
        assertEquals("hpke_v3_info", comparisons.single().operation)
        assertEquals("hpke-info", comparisons.single().slice)
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
