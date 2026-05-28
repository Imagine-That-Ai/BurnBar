package com.openburnbar.data.computeruse

import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardAction
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntentKind
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockCredentialEnvelope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Test
import kotlin.math.roundToLong

class PhoneControlSenderTest {
    private val privateSeed = ByteArray(32) { index -> (index + 1).toByte() }

    @Test
    fun sendWritesSignedControlInputFrame() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val sender = PhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            peerNodeId = "android-phone-1",
            privateKeySeedProvider = { privateSeed },
            counterStore = InMemoryPhoneControlCounterStore(),
            nowMillis = { 1_700_000_000_123L },
            frameSink = { frames += it },
        )

        val authority = sender.send(
            PhoneControlIntent(
                kind = PhoneControlIntentKind.SCROLL,
                normalizedX = 0.4,
                normalizedY = 0.5,
                normalizedX2 = 0.4,
                normalizedY2 = 0.2,
            )
        )

        assertEquals(1, frames.size)
        val frame = frames.single()
        assertEquals(HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT, frame.type)
        assertEquals("uid-1", frame.uid)
        assertEquals("conn-1", frame.connectionId)
        assertEquals(MediaStreamClass.CONTROL_INPUT.raw, frame.control?.streamClass)
        val input = frame.control?.inputIntent
        assertNotNull(input)
        assertEquals(HermesRealtimeRelayInputIntentKind.SCROLL, input?.kind)
        assertEquals(0.4, input?.normalizedX ?: -1.0, 0.0)
        assertEquals(0.2, input?.normalizedY2 ?: -1.0, 0.0)
        assertNotNull(input?.clientIntentId)
        assertEquals("android-phone-1", input?.authority?.peerNodeId)
        assertEquals(1L, input?.authority?.counter)
        assertEquals(721_692_800.123, input?.authority?.timestamp ?: -1.0, 0.000_001)
        assertEquals(authority.intentHashBlake3, input?.authority?.intentHashBlake3)

        PhoneControlSigner.verify(
            intent = PhoneControlIntent(
                kind = PhoneControlIntentKind.SCROLL,
                normalizedX = 0.4,
                normalizedY = 0.5,
                normalizedX2 = 0.4,
                normalizedY2 = 0.2,
                clientIntentId = input?.clientIntentId,
            ),
            authority = authority,
            publicKey = PhoneControlSigner.publicKey(privateSeed),
            lastSeenCounter = 0,
            nowMillis = 1_700_000_000_123L,
        )
    }

    @Test
    fun sendWritesPointerClickMouseButton() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val sender = PhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            peerNodeId = "android-phone-1",
            privateKeySeedProvider = { privateSeed },
            counterStore = InMemoryPhoneControlCounterStore(),
            nowMillis = { 1_700_000_000_123L },
            frameSink = { frames += it },
        )

        val authority = sender.send(
            PhoneControlIntent(
                kind = PhoneControlIntentKind.POINTER_CLICK,
                mouseButton = 1,
            )
        )

        val input = frames.single().control?.inputIntent
        assertEquals(HermesRealtimeRelayInputIntentKind.POINTER_CLICK, input?.kind)
        assertEquals(1, input?.mouseButton)

        PhoneControlSigner.verify(
            intent = PhoneControlIntent(
                kind = PhoneControlIntentKind.POINTER_CLICK,
                mouseButton = 1,
                clientIntentId = input?.clientIntentId,
            ),
            authority = authority,
            publicKey = PhoneControlSigner.publicKey(privateSeed),
            lastSeenCounter = 0,
            nowMillis = 1_700_000_000_123L,
        )
    }

    @Test
    fun sendWritesPointerMoveDeltas() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val sender = PhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            peerNodeId = "android-phone-1",
            privateKeySeedProvider = { privateSeed },
            counterStore = InMemoryPhoneControlCounterStore(),
            nowMillis = { 1_700_000_000_123L },
            frameSink = { frames += it },
        )

        sender.send(
            PhoneControlIntent(
                kind = PhoneControlIntentKind.POINTER_MOVE,
                normalizedX2 = 16.0,
                normalizedY2 = -7.0,
            )
        )

        val input = frames.single().control?.inputIntent
        assertEquals(HermesRealtimeRelayInputIntentKind.POINTER_MOVE, input?.kind)
        assertEquals(16.0, input?.normalizedX2 ?: -1.0, 0.0)
        assertEquals(-7.0, input?.normalizedY2 ?: 1.0, 0.0)
    }

    @Test
    fun sendIncrementsCounterPerPeer() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val sender = PhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            peerNodeId = "android-phone-1",
            privateKeySeedProvider = { privateSeed },
            counterStore = InMemoryPhoneControlCounterStore(mapOf("android-phone-1" to 41L)),
            nowMillis = { 1_700_000_000_000L },
            frameSink = { frames += it },
        )

        val first = sender.send(PhoneControlIntent(kind = PhoneControlIntentKind.PANIC))
        val second = sender.send(PhoneControlIntent(kind = PhoneControlIntentKind.PANIC))

        assertEquals(42L, first.counter)
        assertEquals(43L, second.counter)
        assertEquals(42L, frames[0].control?.inputIntent?.authority?.counter)
        assertEquals(43L, frames[1].control?.inputIntent?.authority?.counter)
    }

    @Test
    fun sendWritesSignedClipboardRequestFrame() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val sender = PhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            peerNodeId = "android-phone-1",
            privateKeySeedProvider = { privateSeed },
            counterStore = InMemoryPhoneControlCounterStore(),
            nowMillis = { 1_700_000_000_123L },
            frameSink = { frames += it },
        )

        val wire = sender.send(
            PhoneControlClipboardRequest(
                requestId = "clipboard-1",
                action = PhoneControlClipboardAction.PASTE_TO_MAC,
                contentType = "text/plain",
                text = "hello",
                maxBytes = 65_536,
            )
        )

        assertEquals(1, frames.size)
        val frame = frames.single()
        assertEquals(HermesRealtimeRelayFrameType.CONTROL_CLIPBOARD_REQUEST, frame.type)
        assertEquals("uid-1", frame.uid)
        assertEquals("conn-1", frame.connectionId)
        assertEquals("clipboard-1", frame.requestId)
        assertEquals("control.clipboard", frame.control?.streamClass)
        val request = frame.control?.clipboardRequest
        assertNotNull(request)
        assertEquals(HermesRealtimeRelayClipboardAction.PASTE_TO_MAC, request?.action)
        assertEquals("text/plain", request?.contentType)
        assertEquals("hello", request?.text)
        assertEquals(65_536, request?.maxBytes)
        assertNotNull(request?.clientIntentId)
        assertEquals("android-phone-1", request?.authority?.peerNodeId)
        assertEquals(1L, request?.authority?.counter)
        assertEquals(wire.authority.intentHashBlake3, request?.authority?.intentHashBlake3)

        PhoneControlSigner.verifyClipboardRequest(
            request = PhoneControlClipboardRequest(
                requestId = request?.requestId ?: "",
                action = PhoneControlClipboardAction.PASTE_TO_MAC,
                contentType = request?.contentType ?: "",
                text = request?.text,
                maxBytes = request?.maxBytes ?: 0,
                clientIntentId = request?.clientIntentId,
            ),
            authority = wire.authority.toPhoneControlAuthority(),
            publicKey = PhoneControlSigner.publicKey(privateSeed),
            lastSeenCounter = 0,
            nowMillis = 1_700_000_000_123L,
        )
    }

    @Test
    fun sendWritesSignedRemoteUnlockCredentialFrame() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val sender = PhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            peerNodeId = "android-phone-1",
            privateKeySeedProvider = { privateSeed },
            counterStore = InMemoryPhoneControlCounterStore(),
            nowMillis = { 1_700_000_000_123L },
            frameSink = { frames += it },
        )
        val placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId = "",
            counter = 0,
            timestamp = 0.0,
            intentHashBlake3 = "",
            signatureEd25519 = "",
        )
        val envelope = HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
            requestId = "remote-unlock-credential",
            sessionId = "remote-unlock-session",
            clientIntentId = "client-intent",
            credentialKind = HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind.SAVED_PASSWORD,
            recipientKeyId = "hpke-key",
            algorithm = RemoteUnlockCredentialEnvelopeCrypto.ALGORITHM,
            ciphertextBase64 = "Y2lwaGVy",
            aadBase64 = "YWFk",
            redactedByteCount = 6,
            requestedAt = "2026-05-26T20:00:00.000Z",
            expiresAt = "2026-05-26T20:00:30.000Z",
            authority = placeholder,
        )

        val signedWire = sender.send(envelope)

        assertEquals(1, frames.size)
        val frame = frames.single()
        assertEquals(HermesRealtimeRelayFrameType.REMOTE_UNLOCK_CREDENTIAL, frame.type)
        assertEquals("remote-unlock-credential", frame.requestId)
        assertEquals("remote_unlock", frame.control?.streamClass)
        assertEquals("remote-unlock-session", frame.control?.sessionId)
        val credential = frame.control?.remoteUnlockCredential
        assertNotNull(credential)
        assertEquals(HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind.SAVED_PASSWORD, credential?.credentialKind)
        assertEquals("android-phone-1", credential?.authority?.peerNodeId)
        assertEquals(1L, credential?.authority?.counter)
        assertEquals(
            PhoneControlSigner.canonicalRemoteUnlockCredentialHashHex(envelope),
            credential?.authority?.intentHashBlake3,
        )
        assertEquals(signedWire.authority.signatureEd25519, credential?.authority?.signatureEd25519)
    }

    @Test
    fun sendFailsWhenSigningKeyMissing() {
        val sender = PhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            peerNodeId = "android-phone-1",
            privateKeySeedProvider = { null },
            counterStore = InMemoryPhoneControlCounterStore(),
            frameSink = {},
        )

        assertThrows(PhoneControlSender.SendError.SigningKeyMissing::class.java) {
            runBlocking {
                sender.send(PhoneControlIntent(kind = PhoneControlIntentKind.PANIC))
            }
        }
    }

    private fun com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope.toPhoneControlAuthority(): PhoneControlAuthorityEnvelope =
        PhoneControlAuthorityEnvelope(
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = ((timestamp + 978_307_200.0) * 1000.0).roundToLong(),
            intentHashBlake3 = intentHashBlake3,
            signatureEd25519 = signatureEd25519,
        )
}
