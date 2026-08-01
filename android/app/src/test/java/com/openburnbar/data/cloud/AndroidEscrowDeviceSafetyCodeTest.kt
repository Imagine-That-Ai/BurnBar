package com.openburnbar.data.cloud

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidEscrowDeviceSafetyCodeTest {
    @Test
    fun `safety code matches the server and Swift golden vector`() {
        assertEquals(
            "8295 F5F1 8C01 2628 D201 F79C 26F0 A9EC",
            AndroidEscrowDeviceSafetyCode.format(PUBLIC_KEY_BASE64),
        )
    }

    @Test
    fun `stored fingerprint must match the published public key`() {
        assertTrue(
            AndroidEscrowDeviceSafetyCode.isFingerprintBoundTo(
                FINGERPRINT_BASE64,
                PUBLIC_KEY_BASE64,
            ),
        )
        val mismatched = Base64.getEncoder().encodeToString(ByteArray(32) { 0x5A })
        assertFalse(
            AndroidEscrowDeviceSafetyCode.isFingerprintBoundTo(
                mismatched,
                PUBLIC_KEY_BASE64,
            ),
        )
    }

    @Test
    fun `invalid or off curve keys fail closed`() {
        assertNull(AndroidEscrowDeviceSafetyCode.format(null))
        assertNull(AndroidEscrowDeviceSafetyCode.format("not base64"))
        val offCurve = Base64.getEncoder().encodeToString(byteArrayOf(0x04) + ByteArray(64) { 0xAB.toByte() })
        assertNull(AndroidEscrowDeviceSafetyCode.format(offCurve))
        assertFalse(AndroidEscrowDeviceSafetyCode.isFingerprintBoundTo(FINGERPRINT_BASE64, offCurve))
    }

    private companion object {
        const val PUBLIC_KEY_BASE64 =
            "BF8kD8cxysQZYfK+E5P47VMA2Kyf7qQ8SSJh0QB3RkparBtbyeL7XrAue1wanXNo0KUc5OzpAtUWp6oWSYrKzfM="
        const val FINGERPRINT_BASE64 = "gpX18YwBJijSAfecJvCp7Fmc5wM+uzmwJxbbGcoGoAw="
    }
}
