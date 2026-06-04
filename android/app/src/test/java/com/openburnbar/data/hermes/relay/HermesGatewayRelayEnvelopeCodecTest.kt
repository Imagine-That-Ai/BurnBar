@file:Suppress("FunctionNaming")

package com.openburnbar.data.hermes.relay

import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.util.Base64
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class HermesGatewayRelayEnvelopeCodecTest {
    @Before
    fun stubAndroidBase64() {
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
    fun gateway_message_seals_and_opens_with_hpke_v3_when_preferred() {
        val phone = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val agent = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val plaintext = """{"text":"Hermes replied.","destinationId":"burnbar:home"}"""

        val envelope =
            HermesGatewayRelayEnvelopeCodec.sealMessagePayload(
                plaintext = plaintext.toByteArray(Charsets.UTF_8),
                uid = "uid-1",
                clientId = "client-1",
                messageId = "m-1",
                recipientPublicKeyX963 = publicX963(phone.public),
                senderPrivateKey = agent.private,
                preferredRelayKeyVersion = HermesRelayCrypto.KEY_VERSION_V3,
            )

        assertEquals(HermesRelayCrypto.KEY_VERSION_V3, envelope.relayKeyVersion)
        assertEquals(HermesRelayCrypto.ALGORITHM_V3, envelope.relayEncryption)
        assertFalse(envelope.enc.isNullOrBlank())
        assertEquals(
            Base64.getEncoder().encodeToString(publicX963(agent.public)),
            envelope.senderPublicKey,
        )

        val opened =
            HermesGatewayRelayEnvelopeCodec.openMessagePayload(
                envelope = envelope,
                uid = "uid-1",
                clientId = "client-1",
                messageId = "m-1",
                recipientPrivateKey = phone.private,
                pinnedSenderPublicKeyX963 = publicX963(agent.public),
            )
        val json = JSONObject(String(opened, Charsets.UTF_8))
        assertEquals("Hermes replied.", json.getString("text"))
        assertEquals("burnbar:home", json.getString("destinationId"))
    }

    @Test
    fun gateway_event_can_fallback_to_authenticated_v2() {
        val agent = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val phone = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val plaintext = """{"text":"open","kind":"chat","destinationId":"burnbar:home","replayCounter":1}"""

        val envelope =
            HermesGatewayRelayEnvelopeCodec.sealEventPayload(
                plaintext = plaintext.toByteArray(Charsets.UTF_8),
                uid = "uid-1",
                clientId = "client-1",
                eventId = "e-1",
                recipientPublicKeyX963 = publicX963(agent.public),
                senderPrivateKey = phone.private,
                preferredRelayKeyVersion = HermesRelayCrypto.GATEWAY_KEY_VERSION,
            )

        assertEquals(HermesRelayCrypto.GATEWAY_KEY_VERSION, envelope.relayKeyVersion)
        assertEquals(HermesRelayCrypto.ALGORITHM, envelope.relayEncryption)
        assertTrue(envelope.enc == null)

        val opened =
            HermesGatewayRelayEnvelopeCodec.openEventPayload(
                envelope = envelope,
                uid = "uid-1",
                clientId = "client-1",
                eventId = "e-1",
                recipientPrivateKey = agent.private,
                pinnedSenderPublicKeyX963 = publicX963(phone.public),
            )
        assertEquals(plaintext, String(opened, Charsets.UTF_8))
    }

    @Test
    fun gateway_v3_open_binds_the_pinned_sender_not_the_wire_sender_text() {
        val phone = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val agent = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val attacker = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val envelope =
            HermesGatewayRelayEnvelopeCodec.sealMessagePayload(
                plaintext = """{"text":"forged?","destinationId":"burnbar:home"}""".toByteArray(Charsets.UTF_8),
                uid = "uid-1",
                clientId = "client-1",
                messageId = "m-2",
                recipientPublicKeyX963 = publicX963(phone.public),
                senderPrivateKey = agent.private,
                preferredRelayKeyVersion = HermesRelayCrypto.KEY_VERSION_V3,
            )

        assertRejected {
            HermesGatewayRelayEnvelopeCodec.openMessagePayload(
                envelope =
                    envelope.copy(
                        senderPublicKey =
                            Base64.getEncoder().encodeToString(publicX963(attacker.public)),
                    ),
                uid = "uid-1",
                clientId = "client-1",
                messageId = "m-2",
                recipientPrivateKey = phone.private,
                pinnedSenderPublicKeyX963 = publicX963(attacker.public),
            )
        }
    }

    @Test
    fun gateway_v3_open_requires_enc() {
        val phone = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val agent = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val envelope =
            HermesGatewayRelayEnvelopeCodec.sealMessagePayload(
                plaintext = """{"text":"missing enc","destinationId":"burnbar:home"}""".toByteArray(Charsets.UTF_8),
                uid = "uid-1",
                clientId = "client-1",
                messageId = "m-3",
                recipientPublicKeyX963 = publicX963(phone.public),
                senderPrivateKey = agent.private,
            )

        assertRejected {
            HermesGatewayRelayEnvelopeCodec.openMessagePayload(
                envelope = envelope.copy(enc = null),
                uid = "uid-1",
                clientId = "client-1",
                messageId = "m-3",
                recipientPrivateKey = phone.private,
                pinnedSenderPublicKeyX963 = publicX963(agent.public),
            )
        }
    }

    private fun publicX963(key: java.security.PublicKey): ByteArray {
        val ecPublic = key as? java.security.interfaces.ECPublicKey ?: error("test expected a P-256 public key")
        return HermesRelayCryptoEc.encodeUncompressedPublicKey(ecPublic)
    }

    private inline fun assertRejected(block: () -> Unit) {
        try {
            block()
            fail("expected gateway envelope open to reject")
        } catch (expected: Exception) {
            assertTrue(true)
        }
    }
}
