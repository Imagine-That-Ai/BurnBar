package com.openburnbar.data.computeruse

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PhoneControlSignerTest {
    private val privateSeed = ByteArray(32) { index -> (index + 1).toByte() }
    private val publicKey = PhoneControlSigner.publicKey(privateSeed)

    @Test
    fun signedIntentVerifies() {
        val intent = PhoneControlIntent(
            kind = PhoneControlIntentKind.TAP,
            normalizedX = 0.25,
            normalizedY = 0.75,
        )
        val authority = PhoneControlSigner.sign(
            intent = intent,
            peerNodeId = "android-phone-1",
            counter = 1,
            timestampMillis = 1_700_000_000_123L,
            privateKeySeed = privateSeed,
        )

        PhoneControlSigner.verify(
            intent = intent,
            authority = authority,
            publicKey = publicKey,
            lastSeenCounter = 0,
            nowMillis = 1_700_000_000_124L,
        )
    }

    @Test
    fun canonicalJsonMatchesSwiftSortedOptionalShape() {
        val intent = PhoneControlIntent(
            kind = PhoneControlIntentKind.SHORTCUT,
            key = "c",
            modifiers = listOf("cmd"),
        )

        assertEquals(
            """{"key":"c","kind":"shortcut","modifiers":["cmd"]}""",
            PhoneControlSigner.canonicalIntentJson(intent),
        )
    }

    @Test
    fun canonicalJsonIncludesClientIntentIdWhenPresent() {
        val intent = PhoneControlIntent(
            kind = PhoneControlIntentKind.TAP,
            normalizedX = 0.25,
            normalizedY = 0.75,
            clientIntentId = "intent-1",
        )

        assertEquals(
            """{"clientIntentId":"intent-1","kind":"tap","normalizedX":0.25,"normalizedY":0.75}""",
            PhoneControlSigner.canonicalIntentJson(intent),
        )
    }

    @Test
    fun canonicalJsonIncludesDisplayAndMouseButtonInSwiftSortedShape() {
        val intent = PhoneControlIntent(
            kind = PhoneControlIntentKind.TAP,
            displayId = "display-1",
            normalizedX = 0.25,
            normalizedY = 0.75,
            mouseButton = 1,
            clientIntentId = "intent-1",
        )

        assertEquals(
            """{"clientIntentId":"intent-1","displayId":"display-1","kind":"tap","mouseButton":1,"normalizedX":0.25,"normalizedY":0.75}""",
            PhoneControlSigner.canonicalIntentJson(intent),
        )
    }

    @Test
    fun signablePayloadIsStableAndBigEndian() {
        val payload = PhoneControlSigner.signablePayload(
            intentHashHex = "abc",
            counter = 42,
            timestampMillis = 1_700_000_000_123L,
        )

        val suffixHex = payload.takeLast(16).joinToString("") { "%02x".format(it) }
        assertEquals("000000000000002a0000018bcfe5687b", suffixHex)
    }

    @Test
    fun tamperedIntentFailsBeforeSignatureCheck() {
        val original = PhoneControlIntent(
            kind = PhoneControlIntentKind.TAP,
            normalizedX = 0.1,
            normalizedY = 0.2,
        )
        val signed = PhoneControlSigner.sign(
            intent = original,
            peerNodeId = "android-phone-1",
            counter = 4,
            timestampMillis = 1_700_000_000_000L,
            privateKeySeed = privateSeed,
        )
        val tampered = original.copy(normalizedX = 0.9)

        assertThrows(PhoneControlVerifyError.IntentHashMismatch::class.java) {
            PhoneControlSigner.verify(
                intent = tampered,
                authority = signed,
                publicKey = publicKey,
                lastSeenCounter = 3,
                nowMillis = 1_700_000_000_000L,
            )
        }
    }

    @Test
    fun replayCounterIsRejected() {
        val intent = PhoneControlIntent(kind = PhoneControlIntentKind.PANIC)
        val signed = PhoneControlSigner.sign(
            intent = intent,
            peerNodeId = "android-phone-1",
            counter = 5,
            timestampMillis = 1_700_000_000_000L,
            privateKeySeed = privateSeed,
        )

        assertThrows(PhoneControlVerifyError.CounterReplay::class.java) {
            PhoneControlSigner.verify(
                intent = intent,
                authority = signed,
                publicKey = publicKey,
                lastSeenCounter = 5,
                nowMillis = 1_700_000_000_000L,
            )
        }
    }

    @Test
    fun staleTimestampIsRejected() {
        val intent = PhoneControlIntent(kind = PhoneControlIntentKind.PANIC)
        val signed = PhoneControlSigner.sign(
            intent = intent,
            peerNodeId = "android-phone-1",
            counter = 6,
            timestampMillis = 1_700_000_000_000L,
            privateKeySeed = privateSeed,
        )

        assertThrows(PhoneControlVerifyError.StaleTimestamp::class.java) {
            PhoneControlSigner.verify(
                intent = intent,
                authority = signed,
                publicKey = publicKey,
                lastSeenCounter = 0,
                nowMillis = 1_700_000_006_000L,
            )
        }
    }

    @Test
    fun foreignPublicKeyIsRejected() {
        val intent = PhoneControlIntent(kind = PhoneControlIntentKind.PANIC)
        val signed = PhoneControlSigner.sign(
            intent = intent,
            peerNodeId = "android-phone-1",
            counter = 7,
            timestampMillis = 1_700_000_000_000L,
            privateKeySeed = privateSeed,
        )
        val otherPublicKey = PhoneControlSigner.publicKey(ByteArray(32) { index -> (index + 33).toByte() })

        assertThrows(PhoneControlVerifyError.InvalidSignature::class.java) {
            PhoneControlSigner.verify(
                intent = intent,
                authority = signed,
                publicKey = otherPublicKey,
                lastSeenCounter = 0,
                nowMillis = 1_700_000_000_000L,
            )
        }
    }

    @Test
    fun dragEndpointIsCoveredByHash() {
        val original = PhoneControlIntent(
            kind = PhoneControlIntentKind.SCROLL,
            normalizedX = 0.4,
            normalizedY = 0.5,
            normalizedX2 = 0.4,
            normalizedY2 = 0.2,
        )
        val changed = original.copy(normalizedY2 = 0.8)

        assertNotEquals(
            PhoneControlSigner.canonicalIntentHashHex(original),
            PhoneControlSigner.canonicalIntentHashHex(changed),
        )
    }

    @Test
    fun clipboardCanonicalJsonMatchesSwiftSortedShape() {
        val request = PhoneControlClipboardRequest(
            requestId = "clipboard-1",
            action = PhoneControlClipboardAction.PASTE_TO_MAC,
            contentType = "text/plain",
            text = "hello",
            maxBytes = 65_536,
            clientIntentId = "intent-1",
        )

        assertEquals(
            """{"action":"paste_to_mac","clientIntentId":"intent-1","contentType":"text/plain","maxBytes":65536,"requestId":"clipboard-1","text":"hello"}""",
            PhoneControlSigner.canonicalClipboardRequestJson(request),
        )
    }

    @Test
    fun signedClipboardRequestVerifies() {
        val request = PhoneControlClipboardRequest(
            requestId = "clipboard-2",
            action = PhoneControlClipboardAction.GRAB_FROM_MAC,
            contentType = "text/plain",
            maxBytes = 65_536,
            clientIntentId = "intent-2",
        )
        val authority = PhoneControlSigner.signClipboardRequest(
            request = request,
            peerNodeId = "android-phone-1",
            counter = 8,
            timestampMillis = 1_700_000_000_123L,
            privateKeySeed = privateSeed,
        )

        PhoneControlSigner.verifyClipboardRequest(
            request = request,
            authority = authority,
            publicKey = publicKey,
            lastSeenCounter = 7,
            nowMillis = 1_700_000_000_124L,
        )
    }

    @Test
    fun replayedClipboardCounterFailsVerification() {
        val request = PhoneControlClipboardRequest(
            requestId = "clipboard-replay",
            action = PhoneControlClipboardAction.PASTE_TO_MAC,
            contentType = "text/plain",
            text = "hello",
            maxBytes = 65_536,
            clientIntentId = "intent-replay",
        )
        val authority = PhoneControlSigner.signClipboardRequest(
            request = request,
            peerNodeId = "android-phone-1",
            counter = 12,
            timestampMillis = 1_700_000_000_123L,
            privateKeySeed = privateSeed,
        )

        assertThrows(PhoneControlVerifyError.CounterReplay::class.java) {
            PhoneControlSigner.verifyClipboardRequest(
                request = request,
                authority = authority,
                publicKey = publicKey,
                lastSeenCounter = 12,
                nowMillis = 1_700_000_000_123L,
            )
        }
    }

    @Test
    fun tamperedClipboardTextFailsBeforeSignatureCheck() {
        val original = PhoneControlClipboardRequest(
            requestId = "clipboard-3",
            action = PhoneControlClipboardAction.PASTE_TO_MAC,
            text = "first",
            clientIntentId = "intent-3",
        )
        val signed = PhoneControlSigner.signClipboardRequest(
            request = original,
            peerNodeId = "android-phone-1",
            counter = 9,
            timestampMillis = 1_700_000_000_000L,
            privateKeySeed = privateSeed,
        )
        val tampered = original.copy(text = "second")

        assertThrows(PhoneControlVerifyError.IntentHashMismatch::class.java) {
            PhoneControlSigner.verifyClipboardRequest(
                request = tampered,
                authority = signed,
                publicKey = publicKey,
                lastSeenCounter = 8,
                nowMillis = 1_700_000_000_000L,
            )
        }
    }

    @Test
    fun swiftDateReferenceSecondsMatchesFoundationDateEncoding() {
        val authority = PhoneControlAuthorityEnvelope(
            peerNodeId = "android-phone-1",
            counter = 1,
            timestampMillis = 1_700_000_000_000L,
            intentHashBlake3 = "hash",
            signatureEd25519 = "sig",
        )

        assertEquals(721_692_800.0, authority.swiftDateReferenceSeconds, 0.0)
    }

    @Test
    fun agentContextTargetSigningAndVerification() {
        val target = PhoneControlAgentContextTarget(
            requestId = "req-123",
            sessionId = "session-456",
            runtime = "codex",
            threadId = "thread-789",
            displayId = "main",
            normalizedX = 0.25,
            normalizedY = 0.75,
            normalizedRect = null,
            instruction = "Use this context",
            focusContext = null,
            clientIntentId = "intent-abc",
            requestedAt = 123456789.0,
        )
        val signed = PhoneControlSigner.signAgentContextTarget(
            target = target,
            peerNodeId = "android-phone-1",
            counter = 42,
            timestampMillis = 1_700_000_000_000L,
            privateKeySeed = privateSeed,
        )

        PhoneControlSigner.verifyAgentContextTarget(
            target = target,
            authority = signed,
            publicKey = publicKey,
            lastSeenCounter = 40,
            nowMillis = 1_700_000_000_000L,
        )
    }
}
