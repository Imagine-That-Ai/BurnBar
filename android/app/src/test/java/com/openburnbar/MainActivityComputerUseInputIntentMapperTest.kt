@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; epoch
// conversion fixtures are literal by design.

package com.openburnbar

import com.openburnbar.data.computeruse.PhoneControlAuthorityEnvelope
import com.openburnbar.data.computeruse.PhoneControlIntent
import com.openburnbar.data.computeruse.PhoneControlIntentKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Wire-bridge tests for [MainActivityComputerUseInputIntentMapper]: the
 * app-side intent and its signed authority must cross into the relay model
 * without losing a field, renaming a kind, or shifting the epoch.
 */
class MainActivityComputerUseInputIntentMapperTest {
    private fun authority(keyKind: String? = null) = PhoneControlAuthorityEnvelope(
        peerNodeId = "android-phone-1",
        counter = 12,
        timestampMillis = 978_307_200_000L + 1_500L,
        intentHashBlake3 = "deadbeef",
        signatureEd25519 = "c2ln",
        keyKind = keyKind,
    )

    @Test
    fun `map copies every intent field one to one`() {
        val intent = PhoneControlIntent(
            kind = PhoneControlIntentKind.DRAG_MOVE,
            displayId = "display-2",
            normalizedX = 0.1,
            normalizedY = 0.2,
            normalizedX2 = 0.3,
            normalizedY2 = 0.4,
            text = "typed",
            key = "c",
            modifiers = listOf("cmd", "shift"),
            mouseButton = 1,
            clientIntentId = "intent-77",
        )

        val relay = MainActivityComputerUseInputIntentMapper.map(intent, authority())

        assertEquals("DRAG_MOVE", relay.kind.name)
        assertEquals("display-2", relay.displayId)
        assertEquals(0.1, requireNotNull(relay.normalizedX), 0.0)
        assertEquals(0.2, requireNotNull(relay.normalizedY), 0.0)
        assertEquals(0.3, requireNotNull(relay.normalizedX2), 0.0)
        assertEquals(0.4, requireNotNull(relay.normalizedY2), 0.0)
        assertEquals("typed", relay.text)
        assertEquals("c", relay.key)
        assertEquals(listOf("cmd", "shift"), relay.modifiers)
        assertEquals(1, relay.mouseButton)
    }

    @Test
    fun `every phone control kind maps to the same named relay kind`() {
        for (kind in PhoneControlIntentKind.values()) {
            val relay = MainActivityComputerUseInputIntentMapper.map(
                PhoneControlIntent(kind = kind),
                authority(),
            )
            assertEquals("kind $kind must not be renamed crossing the bridge", kind.name, relay.kind.name)
        }
    }

    @Test
    fun `authority crosses with the swift reference epoch conversion`() {
        val relay = MainActivityComputerUseInputIntentMapper.map(
            PhoneControlIntent(kind = PhoneControlIntentKind.TAP),
            authority(),
        )

        assertEquals("android-phone-1", relay.authority.peerNodeId)
        assertEquals(12L, relay.authority.counter)
        // Unix millis → Swift reference seconds (2001-01-01 epoch).
        assertEquals(1.5, relay.authority.timestamp, 1e-9)
        assertEquals("deadbeef", relay.authority.intentHashBlake3)
        assertEquals("c2ln", relay.authority.signatureEd25519)
    }

    @Test
    fun `keyKind passes through for se-p256 and stays absent for legacy ed25519`() {
        val legacy = MainActivityComputerUseInputIntentMapper.map(
            PhoneControlIntent(kind = PhoneControlIntentKind.TAP),
            authority(keyKind = null),
        )
        // Pre-F2 byte identity: the relay envelope gains no keyKind field.
        assertNull(legacy.authority.keyKind)

        val hardware = MainActivityComputerUseInputIntentMapper.map(
            PhoneControlIntent(kind = PhoneControlIntentKind.TAP),
            authority(keyKind = "se-p256"),
        )
        assertEquals("se-p256", hardware.authority.keyKind)
    }
}
