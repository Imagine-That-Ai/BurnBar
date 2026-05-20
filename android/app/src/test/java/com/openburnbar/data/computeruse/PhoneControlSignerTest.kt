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
}
