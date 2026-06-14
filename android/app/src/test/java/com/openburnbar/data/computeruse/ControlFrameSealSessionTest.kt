// negatives deliberately catch broad exceptions to assert "rejected".

package com.openburnbar.data.computeruse

import com.openburnbar.data.hermes.relay.HermesRelayCrypto
import com.openburnbar.data.hermes.relay.HermesRelayCryptoEc
import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayloadCodec
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntent
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntentKind
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.security.GeneralSecurityException
import java.security.KeyPair
import java.security.interfaces.ECPublicKey
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * F10 — Kotlin twin of the Swift `ControlFrameSealSessionTests`: the
 * classify-time sealKeyV3 establishment, both-sides key agreement, the sealed
 * payload shell, and the fail-closed open negatives (retype, cross-controller,
 * tamper, forged sender).
 */
class ControlFrameSealSessionTest {
    private fun x963(keyPair: KeyPair): ByteArray = HermesRelayCryptoEc.encodeUncompressedPublicKey(keyPair.public as? ECPublicKey ?: error("expected EC public key"))

    private fun base64(bytes: ByteArray): String = java.util.Base64.getEncoder().encodeToString(bytes)

    @Before
    fun mockAndroidBase64() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            java.util.Base64.getEncoder().encodeToString(firstArg())
        }
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            java.util.Base64.getDecoder().decode(firstArg<String>())
        }
        ControlSealSessionEstablisher.clearForTests()
    }

    @After
    fun unmockAndroidBase64() {
        unmockkStatic(android.util.Base64::class)
        ControlSealSessionEstablisher.clearForTests()
    }

    private fun establish(
        recipient: KeyPair,
        sender: KeyPair,
        peerNodeId: String = "android-phone-controller",
        connectionId: String = "conn-1",
    ): ControlFrameSealSession.Established = ControlFrameSealSession.establish(
        uid = "uid-1",
        connectionId = connectionId,
        peerNodeId = peerNodeId,
        senderDeviceId = "android-device-1",
        senderPeerNodeId = "android-device-1",
        senderKeyId = "relay-v3-abcdef0123456789abcdef01",
        senderCounter = 7L,
        recipientPublicKeyBase64 = base64(x963(recipient)),
        senderPrivateKey = sender.private,
    )

    private fun innerPayload() = HermesRealtimeRelayControlPayload(
        streamClass = MediaStreamClass.CONTROL_INPUT.raw,
        sessionId = "session-1",
        inputIntent =
        HermesRealtimeRelayInputIntent(
            kind = HermesRealtimeRelayInputIntentKind.TAP,
            displayId = "display-1",
            normalizedX = 0.25,
            normalizedY = 0.75,
            clientIntentId = "intent-1",
            authority =
            HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId = "android-phone-controller",
                counter = 42,
                timestamp = 721_692_800.123,
                intentHashBlake3 = "f".repeat(64),
                signatureEd25519 = "signature",
            ),
        ),
    )

    @Test
    fun `establish and open derive the same seal key on both sides`() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val established = establish(recipient, sender)

        assertEquals(32, established.key.size)
        assertEquals("android-device-1", established.envelope.senderDeviceId)
        assertEquals("android-device-1", established.envelope.senderPeerNodeId)
        assertEquals("relay-v3-abcdef0123456789abcdef01", established.envelope.senderKeyId)
        assertEquals(7L, established.envelope.senderCounter)
        assertEquals(HermesRelayCrypto.KEY_VERSION_V3, established.envelope.relayKeyVersion)

        val opened =
            ControlFrameSealSession.open(
                envelope = established.envelope,
                uid = "uid-1",
                connectionId = "conn-1",
                peerNodeId = "android-phone-controller",
                recipientPrivateKey = recipient.private,
                pinnedSenderPublicKeyX963 = x963(sender),
            )
        assertArrayEquals(established.key, opened)
    }

    @Test
    fun `a forged sender is refused by the pinned-key open`() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val forged = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val established = establish(recipient, sender)
        try {
            ControlFrameSealSession.open(
                envelope = established.envelope,
                uid = "uid-1",
                connectionId = "conn-1",
                peerNodeId = "android-phone-controller",
                recipientPrivateKey = recipient.private,
                pinnedSenderPublicKeyX963 = x963(forged),
            )
            fail("a forged sender must not open the seal-key wrap")
        } catch (expected: GeneralSecurityException) {
            assertNotNull(expected)
        }
    }

    @Test
    fun `a controller peerNodeId swap in the wrap AAD is refused`() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val established = establish(recipient, sender, peerNodeId = "android-phone-controller")
        try {
            ControlFrameSealSession.open(
                envelope = established.envelope,
                uid = "uid-1",
                connectionId = "conn-1",
                peerNodeId = "other-controller",
                recipientPrivateKey = recipient.private,
                pinnedSenderPublicKeyX963 = x963(sender),
            )
            fail("a swapped controller peerNodeId must not open the seal-key wrap")
        } catch (expected: GeneralSecurityException) {
            assertNotNull(expected)
        }
    }

    @Test
    fun `sealed shells expose only streamClass and round trip the inner payload`() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val key = establish(recipient, sender).key
        val payload = innerPayload()

        val shell =
            ControlFrameSealSession.sealPayload(
                payload = payload,
                key = key,
                peerNodeId = "android-phone-controller",
                frameType = "control.input.intent",
            )
        assertEquals(payload.streamClass, shell.streamClass)
        assertNull(shell.inputIntent)
        assertNull(shell.sessionId)
        assertNotNull(shell.sealedFrameBase64)

        // The wire bytes of the shell carry NOTHING but routing + ciphertext.
        val shellJson =
            Json.parseToJsonElement(
                HermesRealtimeRelayControlPayloadCodec.encodeToBytes(shell).toString(Charsets.UTF_8),
            ).jsonObject
        assertEquals(setOf("streamClass", "sealedFrameBase64"), shellJson.keys)

        val opened =
            ControlFrameSealSession.openPayload(
                payload = shell,
                key = key,
                peerNodeId = "android-phone-controller",
                frameType = "control.input.intent",
            )
        assertEquals(payload, opened)
    }

    @Test
    fun `a retyped sealed shell is refused`() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val key = establish(recipient, sender).key
        val shell =
            ControlFrameSealSession.sealPayload(
                payload = innerPayload(),
                key = key,
                peerNodeId = "android-phone-controller",
                frameType = "control.input.intent",
            )
        try {
            ControlFrameSealSession.openPayload(
                payload = shell,
                key = key,
                peerNodeId = "android-phone-controller",
                frameType = "control.clipboard.request",
            )
            fail("a frame retype must fail the seal AAD")
        } catch (expected: ControlFrameSealException.OpenFailed) {
            assertNotNull(expected)
        }
    }

    @Test
    fun `a cross-controller sealed shell is refused`() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val key = establish(recipient, sender).key
        val shell =
            ControlFrameSealSession.sealPayload(
                payload = innerPayload(),
                key = key,
                peerNodeId = "android-phone-controller",
                frameType = "control.input.intent",
            )
        try {
            ControlFrameSealSession.openPayload(
                payload = shell,
                key = key,
                peerNodeId = "another-controller",
                frameType = "control.input.intent",
            )
            fail("a cross-controller replay must fail the seal AAD")
        } catch (expected: ControlFrameSealException.OpenFailed) {
            assertNotNull(expected)
        }
    }

    @Test
    fun `a tampered sealed shell is refused and a missing shell fails closed`() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val key = establish(recipient, sender).key
        val shell =
            ControlFrameSealSession.sealPayload(
                payload = innerPayload(),
                key = key,
                peerNodeId = "android-phone-controller",
                frameType = "control.input.intent",
            )
        val sealed = java.util.Base64.getDecoder().decode(shell.sealedFrameBase64)
        sealed[sealed.size - 1] = (sealed[sealed.size - 1].toInt() xor 0x01).toByte()
        try {
            ControlFrameSealSession.openPayload(
                payload = shell.copy(sealedFrameBase64 = java.util.Base64.getEncoder().encodeToString(sealed)),
                key = key,
                peerNodeId = "android-phone-controller",
                frameType = "control.input.intent",
            )
            fail("a tampered shell must fail the GCM tag")
        } catch (expected: ControlFrameSealException.OpenFailed) {
            assertNotNull(expected)
        }
        try {
            ControlFrameSealSession.openPayload(
                payload = HermesRealtimeRelayControlPayload(streamClass = "control.input"),
                key = key,
                peerNodeId = "android-phone-controller",
                frameType = "control.input.intent",
            )
            fail("a shell without sealedFrameBase64 must fail closed")
        } catch (expected: ControlFrameSealSession.SessionException.SealedPayloadMissing) {
            assertNotNull(expected)
        }
    }

    @Test
    fun `controlSealKeyAAD is byte-identical to the swift parts order`() {
        assertArrayEquals(
            "OpenBurnBar-HermesRelay-v1|controlSealKey|uid-1|conn-1|peer-1|device-1|key-1|7"
                .toByteArray(Charsets.UTF_8),
            HermesRelayCrypto.controlSealKeyAAD(
                uid = "uid-1",
                connectionId = "conn-1",
                peerNodeId = "peer-1",
                senderDeviceId = "device-1",
                senderKeyId = "key-1",
                senderCounter = 7L,
            ),
        )
    }

    @Test
    fun `sealing frame sink seals every PhoneControlSender control payload`() = runBlocking {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val established = establish(recipient, sender)
        val session =
            ControlSealSessionEstablisher.Session(
                envelope = established.envelope,
                key = established.key,
                controllerPeerNodeId = "android-phone-1",
            )

        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val baseSink: suspend (HermesRealtimeRelayFrame) -> Unit = { frames += it }
        val controlSender =
            PhoneControlSender(
                uid = "uid-1",
                connectionId = "conn-1",
                peerNodeId = "android-phone-1",
                signingIdentityProvider = {
                    PhoneControlSigningIdentity.Ed25519(ByteArray(32) { index -> (index + 1).toByte() })
                },
                counterStore = InMemoryPhoneControlCounterStore(),
                nowMillis = { 1_700_000_000_123L },
                frameSink = ControlSealSessionEstablisher.sealingFrameSink(baseSink, session),
            )

        controlSender.send(
            PhoneControlIntent(kind = PhoneControlIntentKind.TAP, normalizedX = 0.5, normalizedY = 0.5),
        )

        val frame = frames.single()
        // The shell hides the signed intent; only routing survives in clear.
        assertEquals(MediaStreamClass.CONTROL_INPUT.raw, frame.control?.streamClass)
        assertNull(frame.control?.inputIntent)
        assertNotNull(frame.control?.sealedFrameBase64)

        // The Mac-side open (same key, AAD bound to the frame's wire type)
        // recovers the signed intent intact.
        val opened =
            ControlFrameSealSession.openPayload(
                payload = frame.control ?: error("expected control frame"),
                key = session.key,
                peerNodeId = "android-phone-1",
                frameType = "control.input.intent",
            )
        assertEquals(HermesRealtimeRelayInputIntentKind.TAP, opened.inputIntent?.kind)
        assertEquals("android-phone-1", opened.inputIntent?.authority?.peerNodeId)
        assertTrue(opened.inputIntent?.authority?.signatureEd25519.orEmpty().isNotEmpty())
    }

    @Test
    fun `establishIfNegotiated fails closed when the default-off ramp is unreadable`() = runBlocking {
        // No Firebase in unit tests ⇒ the RC read throws ⇒ resolves false ⇒
        // null (legacy lane) even when the Mac advertises the capability.
        assertNull(
            ControlSealSessionEstablisher.establishIfNegotiated(
                uid = "uid-1",
                connectionId = "conn-1",
                controllerPeerNodeId = "android-phone-1",
                macCapabilities = setOf(ControlFrameSealNegotiation.CAPABILITY),
            ),
        )
        assertNull(ControlSealSessionEstablisher.activeSession("conn-1"))
    }

    @Test
    fun `session registry hands the classify-time session to other senders on the connection`() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val established = establish(recipient, sender)
        val session =
            ControlSealSessionEstablisher.Session(
                envelope = established.envelope,
                key = established.key,
                controllerPeerNodeId = "android-phone-1",
            )
        assertNull(ControlSealSessionEstablisher.activeSession("conn-1"))
        ControlSealSessionEstablisher.register(session, "conn-1")
        assertEquals(session, ControlSealSessionEstablisher.activeSession("conn-1"))
        assertNull(ControlSealSessionEstablisher.activeSession("conn-2"))
    }
}
