@file:Suppress("FunctionNaming", "MagicNumber", "TooGenericExceptionCaught")
// detekt: JUnit backtick BDD test names intentionally contain spaces; crypto
// negatives catch broad exceptions to assert the exact rejection class.

package com.openburnbar.data.hermes.relay

import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.util.Base64
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class HermesRatchetCryptoTest {
    private var cachedResponderInitialKeyPair: HermesRatchetKeyPair? = null

    @Before
    fun mockAndroidBase64ForJvm() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            Base64.getEncoder().encodeToString(firstArg<ByteArray>())
        }
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            Base64.getDecoder().decode(firstArg<String>())
        }
    }

    @After
    fun restore() {
        unmockkStatic(android.util.Base64::class)
    }

    @Test
    fun `wire constants and KDF labels match Swift ratchet v1`() {
        assertEquals(1, HermesRatchetCrypto.VERSION)
        assertEquals("OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM", HermesRatchetCrypto.ALGORITHM)
        assertEquals("OpenBurnBar-HermesRatchet-v1-AAD", HermesRatchetCrypto.AAD_DOMAIN)
        assertEquals("OpenBurnBar-HermesRatchet-v1-root", HermesRatchetCrypto.ROOT_INFO)
        assertEquals("OpenBurnBar-HermesRatchet-v1-chain", HermesRatchetCrypto.CHAIN_LABEL)
        assertEquals("OpenBurnBar-HermesRatchet-v1-message", HermesRatchetCrypto.MESSAGE_LABEL)
    }

    @Test
    fun `AAD uses Swift length-prefixed fields and UInt64 big-endian integers`() {
        val header =
            HermesRatchetHeader(
                sessionID = "session-1",
                senderDeviceID = "alice",
                receiverDeviceID = "bob",
                ratchetPublicKeyBase64 = "ratchet-public",
                previousChainLength = 3,
                messageNumber = 7,
                epoch = 11,
            )
        val actual = HermesRatchetCrypto.envelopeAAD(header, "ad".toByteArray(Charsets.UTF_8))
        val expected =
            "OpenBurnBar-HermesRatchet-v1-AAD".toByteArray(Charsets.UTF_8) +
                part("ad") +
                part("OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM") +
                part("session-1") +
                part("alice") +
                part("bob") +
                part("ratchet-public") +
                uint64(1) +
                uint64(3) +
                uint64(7) +
                uint64(11)
        assertArrayEquals(expected, actual)
    }

    @Test
    fun `round trip and reply perform DH ratchet`() {
        val alice = makeInitiator()
        val bob = makeResponder()
        val ad = "uid=u1|client=c1|destination=home".toByteArray(Charsets.UTF_8)

        val first = HermesRatchetCrypto.encrypt("hello".toByteArray(Charsets.UTF_8), alice, ad)
        assertEquals(0, first.header.messageNumber)
        assertEquals(0, first.header.previousChainLength)
        assertEquals(0, first.header.epoch)

        val opened = HermesRatchetCrypto.decrypt(first, bob, ad)
        assertEquals("hello", opened.toString(Charsets.UTF_8))
        assertEquals(1, bob.epoch)
        assertEquals(1, bob.receiveMessageNumber)
        assertEquals(0, bob.sendMessageNumber)

        val reply = HermesRatchetCrypto.encrypt("ack".toByteArray(Charsets.UTF_8), bob, ad)
        assertEquals(0, reply.header.messageNumber)
        assertEquals(0, reply.header.previousChainLength)
        assertEquals(1, reply.header.epoch)

        val openedReply = HermesRatchetCrypto.decrypt(reply, alice, ad)
        assertEquals("ack", openedReply.toString(Charsets.UTF_8))
        assertEquals(1, alice.epoch)
    }

    @Test
    fun `out of order receive uses bounded skipped message keys`() {
        val alice = makeInitiator()
        val bob = makeResponder(maxSkip = 4)
        val one = HermesRatchetCrypto.encrypt("1".toByteArray(Charsets.UTF_8), alice)
        val two = HermesRatchetCrypto.encrypt("2".toByteArray(Charsets.UTF_8), alice)

        val openedTwo = HermesRatchetCrypto.decrypt(two, bob)
        assertEquals("2", openedTwo.toString(Charsets.UTF_8))
        assertEquals(1, bob.skippedMessageKeys.size)

        val openedOne = HermesRatchetCrypto.decrypt(one, bob)
        assertEquals("1", openedOne.toString(Charsets.UTF_8))
        assertTrue(bob.skippedMessageKeys.isEmpty())
    }

    @Test
    fun `associated data tamper fails authentication`() {
        val alice = makeInitiator()
        val bob = makeResponder()
        val envelope =
            HermesRatchetCrypto.encrypt(
                "secret".toByteArray(Charsets.UTF_8),
                alice,
                "destination=home".toByteArray(Charsets.UTF_8),
            )

        assertRatchetError(HermesRatchetError.AUTHENTICATION_FAILED) {
            HermesRatchetCrypto.decrypt(envelope, bob, "destination=other".toByteArray(Charsets.UTF_8))
        }
    }

    @Test
    fun `replay after successful open fails authentication`() {
        val alice = makeInitiator()
        val bob = makeResponder()
        val envelope = HermesRatchetCrypto.encrypt("once".toByteArray(Charsets.UTF_8), alice)
        HermesRatchetCrypto.decrypt(envelope, bob)

        assertRatchetError(HermesRatchetError.AUTHENTICATION_FAILED) {
            HermesRatchetCrypto.decrypt(envelope, bob)
        }
    }

    @Test
    fun `skip limit prevents unbounded skipped key storage`() {
        val alice = makeInitiator()
        val bob = makeResponder(maxSkip = 1)
        HermesRatchetCrypto.encrypt("0".toByteArray(Charsets.UTF_8), alice)
        HermesRatchetCrypto.encrypt("1".toByteArray(Charsets.UTF_8), alice)
        val third = HermesRatchetCrypto.encrypt("2".toByteArray(Charsets.UTF_8), alice)

        assertRatchetError(HermesRatchetError.TOO_MANY_SKIPPED_KEYS) {
            HermesRatchetCrypto.decrypt(third, bob)
        }
    }

    @Test
    fun `header tamper fails before decrypt`() {
        val alice = makeInitiator()
        val bob = makeResponder()
        val envelope = HermesRatchetCrypto.encrypt("hello".toByteArray(Charsets.UTF_8), alice)
        val tampered =
            HermesRatchetEnvelope(
                header = envelope.header.copy(sessionID = "wrong-session"),
                ciphertextBase64 = envelope.ciphertextBase64,
            )

        assertRatchetError(HermesRatchetError.INVALID_ENVELOPE) {
            HermesRatchetCrypto.decrypt(tampered, bob)
        }
    }

    @Test
    fun `header authenticated fields cannot be relabeled`() {
        val alice = makeInitiator()
        val bob = makeResponder()
        val envelope = HermesRatchetCrypto.encrypt("hello".toByteArray(Charsets.UTF_8), alice)
        val tampered =
            HermesRatchetEnvelope(
                header = envelope.header.copy(epoch = envelope.header.epoch + 1),
                ciphertextBase64 = envelope.ciphertextBase64,
            )

        assertRatchetError(HermesRatchetError.AUTHENTICATION_FAILED) {
            HermesRatchetCrypto.decrypt(tampered, bob)
        }
    }

    @Test
    fun `Python known vector decrypts and matches KDF`() {
        val sharedSecret = hexToBytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        val initiatorInitial =
            HermesRatchetKeyPair(
                privateKeyBase64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM=",
                publicKeyBase64 = "BF7L5NGmMwpEyPfvlR1L8WXmxrch762phftBZhvG5/1shzRkDEmY/343SwbOGmSi7NgqsDY4T7g9mnmxJ6J9UDI=",
            )
        val responderInitial =
            HermesRatchetKeyPair(
                privateKeyBase64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAU=",
                publicKeyBase64 = "BFFZC3pRUUDS14TIVghmj9/vjIL9H1vlJCFVSg3D0DPt4MF9qJBKcn2K4b82v4p5Jg0BLwDU2AiI0dC7RP2hbaQ=",
            )
        val initiator =
            HermesRatchetCrypto.initiatorState(
                sessionID = "session-alpha",
                localDeviceID = "agent-device",
                remoteDeviceID = "phone-device",
                sharedSecret = sharedSecret,
                remoteInitialRatchetPublicKeyBase64 = responderInitial.publicKeyBase64,
                localInitialRatchetKeyPair = initiatorInitial,
            )
        assertEquals("kRRkcvhOvnCbQllS0YhJ6o3JesOS8deAaGWc2lRLizc=", initiator.rootKeyBase64)

        val responder =
            HermesRatchetCrypto.responderState(
                sessionID = "session-alpha",
                localDeviceID = "phone-device",
                remoteDeviceID = "agent-device",
                sharedSecret = sharedSecret,
                localInitialRatchetKeyPair = responderInitial,
            )
        val envelope =
            HermesRatchetEnvelope(
                header =
                    HermesRatchetHeader(
                        sessionID = "session-alpha",
                        senderDeviceID = "agent-device",
                        receiverDeviceID = "phone-device",
                        ratchetPublicKeyBase64 = initiatorInitial.publicKeyBase64,
                        previousChainLength = 0,
                        messageNumber = 0,
                        epoch = 0,
                    ),
                ciphertextBase64 = "AAECAwQFBgcICQoLtJG1Ei/8I6FXnVOkbdEygdSRtj69G1Aais9OzfKL9Vhx",
            )

        val opened =
            HermesRatchetCrypto.decrypt(
                envelope,
                responder,
                "gateway-message:session-alpha".toByteArray(Charsets.UTF_8),
        )
        assertEquals("hello from python", opened.toString(Charsets.UTF_8))
        assertEquals("yIl48A/RFS5oRS6PiDlDWZt+m8+NNjoV5Mfrpc5+w0s=", responder.receivingChainKeyBase64)
    }

    private fun makeInitiator(maxSkip: Int = HermesRatchetCrypto.DEFAULT_MAX_SKIP): HermesRatchetSessionState {
        val sharedSecret = ByteArray(32) { 7 }
        return HermesRatchetCrypto.initiatorState(
            sessionID = "session-1",
            localDeviceID = "alice",
            remoteDeviceID = "bob",
            sharedSecret = sharedSecret,
            remoteInitialRatchetPublicKeyBase64 = responderInitialKeyPair().publicKeyBase64,
            maxSkip = maxSkip,
        )
    }

    private fun makeResponder(maxSkip: Int = HermesRatchetCrypto.DEFAULT_MAX_SKIP): HermesRatchetSessionState {
        return HermesRatchetCrypto.responderState(
            sessionID = "session-1",
            localDeviceID = "bob",
            remoteDeviceID = "alice",
            sharedSecret = ByteArray(32) { 7 },
            localInitialRatchetKeyPair = responderInitialKeyPair(),
            maxSkip = maxSkip,
        )
    }

    private fun responderInitialKeyPair(): HermesRatchetKeyPair {
        return cachedResponderInitialKeyPair ?: HermesRatchetCrypto.generateKeyPair().also {
            cachedResponderInitialKeyPair = it
        }
    }

    private fun assertRatchetError(expected: HermesRatchetError, block: () -> Unit) {
        val error =
            try {
                block()
                null
            } catch (exception: HermesRatchetException) {
                exception
            }
        assertEquals("expected HermesRatchetException", expected, error?.error)
    }

    private fun part(value: String): ByteArray = uint64(value.toByteArray(Charsets.UTF_8).size) + value.toByteArray(Charsets.UTF_8)

    private fun hexToBytes(hex: String): ByteArray {
        require(hex.length % 2 == 0)
        return ByteArray(hex.length / 2) { index ->
            hex.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private fun uint64(value: Int): ByteArray {
        val out = ByteArray(8)
        val longValue = value.toLong()
        for (index in out.indices) {
            val shift = (7 - index) * 8
            out[index] = (longValue ushr shift and 0xffL).toByte()
        }
        return out
    }
}
