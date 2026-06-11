@file:Suppress("FunctionNaming", "MagicNumber", "TooGenericExceptionCaught")
// detekt: JUnit backtick BDD test names intentionally contain spaces; crypto
// negatives deliberately catch broad exceptions to assert "rejected".

package com.openburnbar.data.media

import com.openburnbar.data.hermes.relay.HermesRelayCrypto
import com.openburnbar.data.hermes.relay.HermesRelayCryptoEc
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.security.GeneralSecurityException
import java.security.KeyPair
import java.security.interfaces.ECPublicKey
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * F7 — Kotlin twin of the Swift `MediaFrameSealSessionTests`: mirror-request
 * sealKeyV3 establishment, both-sides frame-key agreement, and the AAD
 * negatives (forged sender, viewer swap).
 */
class MediaFrameSealSessionTest {
    private fun x963(keyPair: KeyPair): ByteArray =
        HermesRelayCryptoEc.encodeUncompressedPublicKey(keyPair.public as ECPublicKey)

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
    }

    @After
    fun unmockAndroidBase64() {
        unmockkStatic(android.util.Base64::class)
    }

    private fun establish(
        recipient: KeyPair,
        sender: KeyPair,
        viewerId: String = "viewer-1",
    ): MediaFrameSealSession.Established =
        MediaFrameSealSession.establish(
            uid = "uid-1",
            connectionId = "conn-1",
            viewerId = viewerId,
            senderDeviceId = "android-device-1",
            senderPeerNodeId = "android-device-1",
            senderKeyId = "relay-v3-abcdef0123456789abcdef01",
            senderCounter = 9L,
            recipientPublicKeyBase64 = base64(x963(recipient)),
            senderPrivateKey = sender.private,
        )

    @Test
    fun `establish and open derive the same frame key on both sides`() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val established = establish(recipient, sender)

        assertEquals(32, established.key.size)
        assertEquals(HermesRelayCrypto.KEY_VERSION_V3, established.envelope.relayKeyVersion)
        assertEquals(9L, established.envelope.senderCounter)

        val opened =
            MediaFrameSealSession.open(
                envelope = established.envelope,
                uid = "uid-1",
                connectionId = "conn-1",
                viewerId = "viewer-1",
                recipientPrivateKey = recipient.private,
                pinnedSenderPublicKeyX963 = x963(sender),
            )
        assertArrayEquals(established.key, opened)

        // The derived key must open a frame the Mac sealed with the same
        // session secret + position-bound AAD.
        val plaintext = byteArrayOf(0x01, 0x02, 0x03, 0x04)
        val sealed =
            MediaFrameAead.seal(
                plaintext = plaintext,
                key = opened,
                streamClass = MediaStreamClass.SCREEN_VIDEO.raw,
                kind = 1u,
                gopID = 7u,
                frameIndex = 3u,
            )
        assertArrayEquals(
            plaintext,
            MediaFrameAead.open(
                envelope = sealed,
                key = established.key,
                streamClass = MediaStreamClass.SCREEN_VIDEO.raw,
                kind = 1u,
                gopID = 7u,
                frameIndex = 3u,
            ),
        )
    }

    @Test
    fun `a forged sender is refused by the pinned-key open`() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val forged = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val established = establish(recipient, sender)
        try {
            MediaFrameSealSession.open(
                envelope = established.envelope,
                uid = "uid-1",
                connectionId = "conn-1",
                viewerId = "viewer-1",
                recipientPrivateKey = recipient.private,
                pinnedSenderPublicKeyX963 = x963(forged),
            )
            fail("a forged sender must not open the media seal-key wrap")
        } catch (expected: GeneralSecurityException) {
            assertNotNull(expected)
        }
    }

    @Test
    fun `a viewer swap in the wrap AAD is refused`() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val established = establish(recipient, sender, viewerId = "viewer-1")
        try {
            MediaFrameSealSession.open(
                envelope = established.envelope,
                uid = "uid-1",
                connectionId = "conn-1",
                viewerId = "other-viewer",
                recipientPrivateKey = recipient.private,
                pinnedSenderPublicKeyX963 = x963(sender),
            )
            fail("a swapped viewerId must not open the media seal-key wrap")
        } catch (expected: GeneralSecurityException) {
            assertNotNull(expected)
        }
    }

    @Test
    fun `establishIfNegotiated fails closed when the default-off ramp is unreadable`() {
        // No Firebase in unit tests ⇒ the RC read throws ⇒ resolves false ⇒
        // null (legacy lane) even when the Mac advertises the capability.
        kotlinx.coroutines.runBlocking {
            assertEquals(
                null,
                MediaSealSessionEstablisher.establishIfNegotiated(
                    uid = "uid-1",
                    connectionId = "conn-1",
                    viewerId = "viewer-1",
                    macCapabilities = setOf(MediaFrameAeadNegotiation.CAPABILITY),
                ),
            )
        }
    }

    @Test
    fun `mediaSealKeyAAD is byte-identical to the swift parts order`() {
        assertArrayEquals(
            "OpenBurnBar-HermesRelay-v1|mediaSealKey|uid-1|conn-1|viewer-1|device-1|key-1|9"
                .toByteArray(Charsets.UTF_8),
            HermesRelayCrypto.mediaSealKeyAAD(
                uid = "uid-1",
                connectionId = "conn-1",
                viewerId = "viewer-1",
                senderDeviceId = "device-1",
                senderKeyId = "key-1",
                senderCounter = 9L,
            ),
        )
    }
}
