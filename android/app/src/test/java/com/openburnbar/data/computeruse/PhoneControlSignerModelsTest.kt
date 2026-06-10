@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; epoch
// conversion constants are literal by design.

package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardAction
import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction
import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Wire-contract tests for the phone-control model layer: enum wire values,
 * the app→relay enum bridges, the Unix-millis → Swift-reference-seconds
 * conversions, and the verify-error surfaces other platforms match on.
 */
class PhoneControlSignerModelsTest {
    /** Swift `Date(timeIntervalSinceReferenceDate:)` epoch: 2001-01-01T00:00:00Z. */
    private val swiftEpochMillis = 978_307_200_000L

    @Test
    fun `intent kinds carry the canonical snake case wire values`() {
        val expected = mapOf(
            PhoneControlIntentKind.TAP to "tap",
            PhoneControlIntentKind.DRAG_START to "drag_start",
            PhoneControlIntentKind.DRAG_MOVE to "drag_move",
            PhoneControlIntentKind.DRAG_END to "drag_end",
            PhoneControlIntentKind.TYPE to "type",
            PhoneControlIntentKind.SHORTCUT to "shortcut",
            PhoneControlIntentKind.SCROLL to "scroll",
            PhoneControlIntentKind.POINTER_MOVE to "pointer_move",
            PhoneControlIntentKind.POINTER_CLICK to "pointer_click",
            PhoneControlIntentKind.PANIC to "panic",
        )
        assertEquals(expected.keys, PhoneControlIntentKind.values().toSet())
        expected.forEach { (kind, wire) -> assertEquals(wire, kind.wireValue) }
    }

    @Test
    fun `clipboard request defaults and relay action bridge`() {
        val request = PhoneControlClipboardRequest(requestId = "req-1", action = PhoneControlClipboardAction.PASTE_TO_MAC)
        assertEquals("text/plain", request.contentType)
        assertEquals(65_536, request.maxBytes)
        assertNull(request.text)
        assertEquals(HermesRealtimeRelayClipboardAction.PASTE_TO_MAC, request.toRelayAction())
        assertEquals(
            HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC,
            request.copy(action = PhoneControlClipboardAction.GRAB_FROM_MAC).toRelayAction(),
        )
        assertEquals("paste_to_mac", PhoneControlClipboardAction.PASTE_TO_MAC.wireValue)
        assertEquals("grab_from_mac", PhoneControlClipboardAction.GRAB_FROM_MAC.wireValue)
    }

    @Test
    fun `every system permission kind bridges to the same named relay kind`() {
        for (kind in PhoneControlSystemPermissionKind.values()) {
            assertEquals(kind.name, kind.toRelayKind().name)
        }
        assertEquals("screen_recording", PhoneControlSystemPermissionKind.SCREEN_RECORDING.wireValue)
        assertEquals("full_disk_access", PhoneControlSystemPermissionKind.FULL_DISK_ACCESS.wireValue)
        assertEquals(
            PhoneControlSystemPermissionKind.values().size,
            HermesRealtimeRelaySystemPermissionKind.values().size,
        )
    }

    @Test
    fun `every system permission action bridges to the same named relay action`() {
        for (action in PhoneControlSystemPermissionAction.values()) {
            assertEquals(action.name, action.toRelayAction().name)
        }
        assertEquals("prompt_and_open_settings", PhoneControlSystemPermissionAction.PROMPT_AND_OPEN_SETTINGS.wireValue)
        assertEquals("retry_failed_tool", PhoneControlSystemPermissionAction.RETRY_FAILED_TOOL.wireValue)
        assertEquals(
            PhoneControlSystemPermissionAction.values().size,
            HermesRealtimeRelaySystemPermissionAction.values().size,
        )
    }

    @Test
    fun `system permission request converts unix millis to swift reference seconds`() {
        val request = PhoneControlSystemPermissionRequest(
            requestId = "req-1",
            kind = PhoneControlSystemPermissionKind.CAMERA,
            action = PhoneControlSystemPermissionAction.PROMPT,
            requestedAtMillis = swiftEpochMillis,
        )
        assertEquals(0.0, request.requestedAtSwiftReferenceSeconds, 1e-9)
        assertEquals(
            721_692_800.123,
            request.copy(requestedAtMillis = 1_700_000_000_123L).requestedAtSwiftReferenceSeconds,
            1e-6,
        )
    }

    @Test
    fun `authority envelope converts timestamps and defaults the F2 fields off the wire`() {
        val envelope = PhoneControlAuthorityEnvelope(
            peerNodeId = "android-phone-1",
            counter = 7,
            timestampMillis = swiftEpochMillis + 1_500L,
            intentHashBlake3 = "abc",
            signatureEd25519 = "sig",
        )
        assertEquals(1.5, envelope.swiftDateReferenceSeconds, 1e-9)
        // Pre-F2 byte identity: both optional fields must default to absent.
        assertNull(envelope.keyKind)
        assertNull(envelope.attestationHashBlake3)
    }

    @Test
    fun `verify errors carry the diagnostic state they were rejected on`() {
        val replay = PhoneControlVerifyError.CounterReplay(lastSeen = 9, attempted = 9)
        assertEquals(9L, replay.lastSeen)
        assertEquals(9L, replay.attempted)
        assertTrue(requireNotNull(replay.message).contains("lastSeen=9"))
        assertTrue(requireNotNull(replay.message).contains("attempted=9"))

        val stale = PhoneControlVerifyError.StaleTimestamp(skewMillis = 6_001)
        assertEquals(6_001L, stale.skewMillis)
        assertTrue(requireNotNull(stale.message).contains("6001ms"))

        assertEquals("invalid public key", PhoneControlVerifyError.InvalidPublicKey.message)
        assertEquals("invalid signature", PhoneControlVerifyError.InvalidSignature.message)
        assertEquals("intent hash mismatch", PhoneControlVerifyError.IntentHashMismatch.message)
    }
}
