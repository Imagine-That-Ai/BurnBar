package com.openburnbar

import com.openburnbar.data.hermes.relay.HermesRelayCrypto
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * End-to-end smoke tests for the relay crypto primitives. Spins up two
 * P-256 key pairs locally — one playing the "Mac host" role and one the
 * "Android client" — then verifies that a sealed envelope round-trips.
 */
class HermesRelayCryptoTest {

    @Test
    fun `seal and open round-trips with matching AAD`() {
        val client = HermesRelayCrypto.generateEphemeralKeyPair()
        val host = HermesRelayCrypto.generateEphemeralKeyPair()
        val clientShared = HermesRelayCrypto.ecdh(client.private, host.public)
        val hostShared = HermesRelayCrypto.ecdh(host.private, client.public)
        assertArrayEquals(
            "ECDH must produce identical shared secrets on both sides",
            clientShared, hostShared
        )

        val aad = HermesRelayCrypto.aad("chatCompletions", "req-1", "request")
        val key = HermesRelayCrypto.deriveKey(clientShared, aad)
        val plaintext = "{\"hello\":\"world\"}".toByteArray(Charsets.UTF_8)
        val sealed = HermesRelayCrypto.seal(plaintext, key, aad)

        val hostKey = HermesRelayCrypto.deriveKey(hostShared, aad)
        val opened = HermesRelayCrypto.open(sealed.nonce, sealed.ciphertext, hostKey, aad)
        assertArrayEquals(plaintext, opened)
    }

    @Test
    fun `aad changes derive a different key`() {
        val client = HermesRelayCrypto.generateEphemeralKeyPair()
        val host = HermesRelayCrypto.generateEphemeralKeyPair()
        val shared = HermesRelayCrypto.ecdh(client.private, host.public)

        val a = HermesRelayCrypto.deriveKey(shared, HermesRelayCrypto.aad("op", "id", "request"))
        val b = HermesRelayCrypto.deriveKey(shared, HermesRelayCrypto.aad("op", "id", "response"))
        assertNotEquals("Different AAD parts must derive different keys", a.encoded.toList(), b.encoded.toList())
    }

    @Test
    fun `x963 round-trip encodes a 65-byte uncompressed point`() {
        val pair = HermesRelayCrypto.generateEphemeralKeyPair()
        val encoded = HermesRelayCrypto.encodeUncompressedPublicKey(
            pair.public as java.security.interfaces.ECPublicKey
        )
        assertEquals(65, encoded.size)
        assertEquals(0x04.toByte(), encoded[0])

        val decoded = HermesRelayCrypto.decodeUncompressedPublicKey(encoded)
        val pubA = pair.public as java.security.interfaces.ECPublicKey
        val pubB = decoded as java.security.interfaces.ECPublicKey
        assertEquals(pubA.w.affineX, pubB.w.affineX)
        assertEquals(pubA.w.affineY, pubB.w.affineY)
    }

    @Test
    fun `aad wire format matches iOS contract exactly`() {
        // iOS writes: OpenBurnBar-HermesRelay-v1|<op>|<requestId>|<part>
        val bytes = HermesRelayCrypto.aad("chatCompletions", "abc-123", "request")
        assertEquals(
            "OpenBurnBar-HermesRelay-v1|chatCompletions|abc-123|request",
            String(bytes, Charsets.UTF_8)
        )
    }

    @Test(expected = javax.crypto.AEADBadTagException::class)
    fun `open rejects tampered ciphertext`() {
        val client = HermesRelayCrypto.generateEphemeralKeyPair()
        val host = HermesRelayCrypto.generateEphemeralKeyPair()
        val shared = HermesRelayCrypto.ecdh(client.private, host.public)
        val aad = HermesRelayCrypto.aad("op", "req", "request")
        val key = HermesRelayCrypto.deriveKey(shared, aad)
        val sealed = HermesRelayCrypto.seal("payload".toByteArray(), key, aad)
        val tampered = sealed.ciphertext.copyOf().also { it[0] = (it[0].toInt() xor 0x01).toByte() }
        HermesRelayCrypto.open(sealed.nonce, tampered, key, aad)
    }

    @Test(expected = javax.crypto.AEADBadTagException::class)
    fun `open rejects wrong AAD`() {
        val client = HermesRelayCrypto.generateEphemeralKeyPair()
        val host = HermesRelayCrypto.generateEphemeralKeyPair()
        val shared = HermesRelayCrypto.ecdh(client.private, host.public)
        val sealAad = HermesRelayCrypto.aad("op", "req", "request")
        val openAad = HermesRelayCrypto.aad("op", "req", "response")
        val key = HermesRelayCrypto.deriveKey(shared, sealAad)
        val sealed = HermesRelayCrypto.seal("payload".toByteArray(), key, sealAad)
        val openKey = HermesRelayCrypto.deriveKey(shared, openAad)
        HermesRelayCrypto.open(sealed.nonce, sealed.ciphertext, openKey, openAad)
    }

    @Test
    fun `deriveKey produces a 32-byte AES key`() {
        val pair = HermesRelayCrypto.generateEphemeralKeyPair()
        val shared = HermesRelayCrypto.ecdh(pair.private, pair.public)
        val key = HermesRelayCrypto.deriveKey(shared, HermesRelayCrypto.aad("x", "y", "z"))
        assertEquals(32, key.encoded.size)
        assertEquals("AES", key.algorithm)
    }
}
