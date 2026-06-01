package com.openburnbar.data.computeruse

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Test

private const val PERCENT_SCALE = 16
private const val SECONDS = 721_692_800.0
private const val VAL_32 = 32
private const val VAL_33 = 33

class PhoneControlSignerTest {
    private val privateSeed = ByteArray(32) { index -> (index + 1).toByte() }
    private val publicKey = PhoneControlSigner.publicKey(privateSeed)

    @Test
    fun signedIntentVerifies() {
        val intent =
            PhoneControlIntent(
                kind = PhoneControlIntentKind.TAP,
                normalizedX = 0.25,
                normalizedY = 0.75,
            )
        val authority =
            PhoneControlSignerSign.sign(
                intent = intent,
                peerNodeId = "android-phone-1",
                counter = 1,
                timestampMillis = 1_700_000_000_123L,
                privateKeySeed = privateSeed,
            )

        PhoneControlSignerVerify.verify(
            intent = intent,
            authority = authority,
            publicKey = publicKey,
            lastSeenCounter = 0,
            nowMillis = 1_700_000_000_124L,
        )
    }

    @Test
    fun canonicalJsonMatchesSwiftSortedOptionalShape() {
        val intent =
            PhoneControlIntent(
                kind = PhoneControlIntentKind.SHORTCUT,
                key = "c",
                modifiers = listOf("cmd"),
            )

        assertEquals(
            """{"key":"c","kind":"shortcut","modifiers":["cmd"]}""",
            PhoneControlSignerCanonicalJson.canonicalIntentJson(intent),
        )
    }

    @Test
    fun canonicalJsonIncludesClientIntentIdWhenPresent() {
        val intent =
            PhoneControlIntent(
                kind = PhoneControlIntentKind.TAP,
                normalizedX = 0.25,
                normalizedY = 0.75,
                clientIntentId = "intent-1",
            )

        assertEquals(
            """{"clientIntentId":"intent-1","kind":"tap","normalizedX":0.25,"normalizedY":0.75}""",
            PhoneControlSignerCanonicalJson.canonicalIntentJson(intent),
        )
    }

    @Test
    fun canonicalJsonIncludesDisplayAndMouseButtonInSwiftSortedShape() {
        val intent =
            PhoneControlIntent(
                kind = PhoneControlIntentKind.TAP,
                displayId = "display-1",
                normalizedX = 0.25,
                normalizedY = 0.75,
                mouseButton = 1,
                clientIntentId = "intent-1",
            )

        assertEquals(
            """{"clientIntentId":"intent-1","displayId":"display-1","kind":"tap","mouseButton":1,"normalizedX":0.25,"normalizedY":0.75}""",
            PhoneControlSignerCanonicalJson.canonicalIntentJson(intent),
        )
    }

    @Test
    fun signablePayloadIsStableAndBigEndian() {
        val payload =
            PhoneControlSignerPayload.signablePayload(
                intentHashHex = "abc",
                counter = 42,
                timestampMillis = 1_700_000_000_123L,
            )

        val suffixHex = payload.takeLast(PERCENT_SCALE).joinToString("") { "%02x".format(it) }
        assertEquals("000000000000002a0000018bcfe5687b", suffixHex)
    }

    @Test
    fun tamperedIntentFailsBeforeSignatureCheck() {
        val original =
            PhoneControlIntent(
                kind = PhoneControlIntentKind.TAP,
                normalizedX = 0.1,
                normalizedY = 0.2,
            )
        val signed =
            PhoneControlSignerSign.sign(
                intent = original,
                peerNodeId = "android-phone-1",
                counter = 4,
                timestampMillis = 1_700_000_000_000L,
                privateKeySeed = privateSeed,
            )
        val tampered = original.copy(normalizedX = 0.9)

        assertThrows(PhoneControlVerifyError.IntentHashMismatch::class.java) {
            PhoneControlSignerVerify.verify(
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
        val signed =
            PhoneControlSignerSign.sign(
                intent = intent,
                peerNodeId = "android-phone-1",
                counter = 5,
                timestampMillis = 1_700_000_000_000L,
                privateKeySeed = privateSeed,
            )

        assertThrows(PhoneControlVerifyError.CounterReplay::class.java) {
            PhoneControlSignerVerify.verify(
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
        val signed =
            PhoneControlSignerSign.sign(
                intent = intent,
                peerNodeId = "android-phone-1",
                counter = 6,
                timestampMillis = 1_700_000_000_000L,
                privateKeySeed = privateSeed,
            )

        assertThrows(PhoneControlVerifyError.StaleTimestamp::class.java) {
            PhoneControlSignerVerify.verify(
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
        val signed =
            PhoneControlSignerSign.sign(
                intent = intent,
                peerNodeId = "android-phone-1",
                counter = 7,
                timestampMillis = 1_700_000_000_000L,
                privateKeySeed = privateSeed,
            )
        val otherPublicKey = PhoneControlSigner.publicKey(ByteArray(VAL_32) { index -> (index + VAL_33).toByte() })

        assertThrows(PhoneControlVerifyError.InvalidSignature::class.java) {
            PhoneControlSignerVerify.verify(
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
        val original =
            PhoneControlIntent(
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
        val request =
            PhoneControlClipboardRequest(
                requestId = "clipboard-1",
                action = PhoneControlClipboardAction.PASTE_TO_MAC,
                contentType = "text/plain",
                text = "hello",
                maxBytes = 65_536,
                clientIntentId = "intent-1",
            )

        assertEquals(
            """{"action":"paste_to_mac","clientIntentId":"intent-1","contentType":"text/plain","maxBytes":65536,"requestId":"clipboard-1","text":"hello"}""",
            PhoneControlSignerCanonicalJson.canonicalClipboardRequestJson(request),
        )
    }

    @Test
    fun signedClipboardRequestVerifies() {
        val request =
            PhoneControlClipboardRequest(
                requestId = "clipboard-2",
                action = PhoneControlClipboardAction.GRAB_FROM_MAC,
                contentType = "text/plain",
                maxBytes = 65_536,
                clientIntentId = "intent-2",
            )
        val authority =
            PhoneControlSignerSign.signClipboardRequest(
                request = request,
                peerNodeId = "android-phone-1",
                counter = 8,
                timestampMillis = 1_700_000_000_123L,
                privateKeySeed = privateSeed,
            )

        PhoneControlSignerVerify.verifyClipboardRequest(
            request = request,
            authority = authority,
            publicKey = publicKey,
            lastSeenCounter = 7,
            nowMillis = 1_700_000_000_124L,
        )
    }

    @Test
    fun replayedClipboardCounterFailsVerification() {
        val request =
            PhoneControlClipboardRequest(
                requestId = "clipboard-replay",
                action = PhoneControlClipboardAction.PASTE_TO_MAC,
                contentType = "text/plain",
                text = "hello",
                maxBytes = 65_536,
                clientIntentId = "intent-replay",
            )
        val authority =
            PhoneControlSignerSign.signClipboardRequest(
                request = request,
                peerNodeId = "android-phone-1",
                counter = 12,
                timestampMillis = 1_700_000_000_123L,
                privateKeySeed = privateSeed,
            )

        assertThrows(PhoneControlVerifyError.CounterReplay::class.java) {
            PhoneControlSignerVerify.verifyClipboardRequest(
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
        val original =
            PhoneControlClipboardRequest(
                requestId = "clipboard-3",
                action = PhoneControlClipboardAction.PASTE_TO_MAC,
                text = "first",
                clientIntentId = "intent-3",
            )
        val signed =
            PhoneControlSignerSign.signClipboardRequest(
                request = original,
                peerNodeId = "android-phone-1",
                counter = 9,
                timestampMillis = 1_700_000_000_000L,
                privateKeySeed = privateSeed,
            )
        val tampered = original.copy(text = "second")

        assertThrows(PhoneControlVerifyError.IntentHashMismatch::class.java) {
            PhoneControlSignerVerify.verifyClipboardRequest(
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
        val authority =
            PhoneControlAuthorityEnvelope(
                peerNodeId = "android-phone-1",
                counter = 1,
                timestampMillis = 1_700_000_000_000L,
                intentHashBlake3 = "hash",
                signatureEd25519 = "sig",
            )

        assertEquals(SECONDS, authority.swiftDateReferenceSeconds, 0.0)
    }

    @Test
    fun agentContextTargetSigningAndVerification() {
        val target =
            PhoneControlAgentContextTarget(
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
        val signed =
            PhoneControlSignerSign.signAgentContextTarget(
                target = target,
                peerNodeId = "android-phone-1",
                counter = 42,
                timestampMillis = 1_700_000_000_000L,
                privateKeySeed = privateSeed,
            )

        PhoneControlSignerVerify.verifyAgentContextTarget(
            target = target,
            authority = signed,
            publicKey = publicKey,
            lastSeenCounter = 40,
            nowMillis = 1_700_000_000_000L,
        )
    }
}
