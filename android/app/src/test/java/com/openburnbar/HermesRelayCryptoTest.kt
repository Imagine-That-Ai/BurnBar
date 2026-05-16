package com.openburnbar

import com.openburnbar.data.hermes.relay.HermesRelayCrypto
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.util.Base64
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Hermes relay crypto contract tests. The Android implementation must be
 * byte-for-byte compatible with iOS / macOS so a Mac host can decrypt
 * Android-originated requests and an Android client can decrypt
 * Mac-originated chunks. Every wire-visible constant and AAD string is
 * pinned here against the iOS source of truth at
 * `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift`.
 */
class HermesRelayCryptoTest {

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
    fun restoreStaticMocks() {
        unmockkStatic(android.util.Base64::class)
    }

    // --- AAD wire-string contract --------------------------------------

    @Test
    fun `request AAD matches iOS canonical shape`() {
        val bytes = HermesRelayCrypto.requestAAD("u1", "c1", "r1")
        assertEquals(
            "OpenBurnBar-HermesRelay-v1|request|u1|c1|r1",
            String(bytes, Charsets.UTF_8),
        )
    }

    @Test
    fun `key AAD matches iOS canonical shape`() {
        val bytes = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        assertEquals(
            "OpenBurnBar-HermesRelay-v1|key|u1|c1|r1",
            String(bytes, Charsets.UTF_8),
        )
    }

    @Test
    fun `chunk AAD matches iOS canonical shape including kind and sequence`() {
        val bytes = HermesRelayCrypto.chunkAAD(
            uid = "u1",
            connectionId = "c1",
            requestId = "r1",
            sequence = 7,
            kind = "sse",
        )
        assertEquals(
            "OpenBurnBar-HermesRelay-v1|chunk|u1|c1|r1|7|sse",
            String(bytes, Charsets.UTF_8),
        )
    }

    @Test
    fun `algorithm constant matches iOS algorithm tag`() {
        assertEquals("p256-hkdf-sha256-aesgcm", HermesRelayCrypto.ALGORITHM)
    }

    // --- Seal / open round-trip ---------------------------------------

    @Test
    fun `sealToBase64 round-trips with matching AAD`() {
        val key = HermesRelayCrypto.generateSymmetricKey()
        val aad = HermesRelayCrypto.requestAAD("u1", "c1", "r1")
        val plaintext = "{\"hello\":\"world\"}".toByteArray(Charsets.UTF_8)
        val cipher = HermesRelayCrypto.sealToBase64(plaintext, key, aad)
        val opened = HermesRelayCrypto.openBase64(cipher, key, aad)
        assertArrayEquals(plaintext, opened)
    }

    @Test(expected = javax.crypto.AEADBadTagException::class)
    fun `open rejects mismatched AAD`() {
        val key = HermesRelayCrypto.generateSymmetricKey()
        val sealAad = HermesRelayCrypto.requestAAD("u1", "c1", "r1")
        val openAad = HermesRelayCrypto.requestAAD("u1", "c1", "different")
        val cipher = HermesRelayCrypto.sealToBase64("p".toByteArray(), key, sealAad)
        HermesRelayCrypto.openBase64(cipher, key, openAad)
    }

    // --- Key wrap envelope --------------------------------------------

    @Test
    fun `wrapSymmetricKey envelope round-trips via the recipient private key`() {
        val recipient = HermesRelayCrypto.generateEphemeralKeyPair()
        val recipientPubX963 = HermesRelayCrypto.encodeUncompressedPublicKey(
            recipient.public as java.security.interfaces.ECPublicKey,
        )
        val keyData = HermesRelayCrypto.generateSymmetricKey()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        val wrapped = HermesRelayCrypto.wrapSymmetricKey(keyData, recipientPubX963, aad)
        val unwrapped = HermesRelayCrypto.unwrapSymmetricKey(wrapped, recipient.private, aad)
        assertArrayEquals(keyData, unwrapped)
    }

    @Test(expected = javax.crypto.AEADBadTagException::class)
    fun `unwrapSymmetricKey rejects mismatched AAD`() {
        val recipient = HermesRelayCrypto.generateEphemeralKeyPair()
        val recipientPubX963 = HermesRelayCrypto.encodeUncompressedPublicKey(
            recipient.public as java.security.interfaces.ECPublicKey,
        )
        val keyData = HermesRelayCrypto.generateSymmetricKey()
        val sealAad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        val openAad = HermesRelayCrypto.keyAAD("u1", "c1", "different")
        val wrapped = HermesRelayCrypto.wrapSymmetricKey(keyData, recipientPubX963, sealAad)
        HermesRelayCrypto.unwrapSymmetricKey(wrapped, recipient.private, openAad)
    }

    @Test
    fun `wrapSymmetricKey envelope is at least ephemeralPub + nonce + ciphertext + tag bytes`() {
        val recipient = HermesRelayCrypto.generateEphemeralKeyPair()
        val recipientPubX963 = HermesRelayCrypto.encodeUncompressedPublicKey(
            recipient.public as java.security.interfaces.ECPublicKey,
        )
        val keyData = HermesRelayCrypto.generateSymmetricKey()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        val wrapped = HermesRelayCrypto.wrapSymmetricKey(keyData, recipientPubX963, aad)
        val bytes = Base64.getDecoder().decode(wrapped)
        // 65 ephemeralPubX963 + 12 GCM IV + 32 ciphertext + 16 tag = 125.
        assertEquals(125, bytes.size)
        assertEquals(0x04.toByte(), bytes[0])
    }

    @Test
    fun `unwrap fails with the wrong recipient private key`() {
        val a = HermesRelayCrypto.generateEphemeralKeyPair()
        val b = HermesRelayCrypto.generateEphemeralKeyPair()
        val pubA = HermesRelayCrypto.encodeUncompressedPublicKey(
            a.public as java.security.interfaces.ECPublicKey,
        )
        val keyData = HermesRelayCrypto.generateSymmetricKey()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        val wrapped = HermesRelayCrypto.wrapSymmetricKey(keyData, pubA, aad)
        val outcome = runCatching {
            HermesRelayCrypto.unwrapSymmetricKey(wrapped, b.private, aad)
        }
        assertNotNull("expected failure when unwrapping with the wrong key", outcome.exceptionOrNull())
    }

    // --- X9.63 key encoding -------------------------------------------

    @Test
    fun `x963 round-trip encodes a 65-byte uncompressed point`() {
        val pair = HermesRelayCrypto.generateEphemeralKeyPair()
        val encoded = HermesRelayCrypto.encodeUncompressedPublicKey(
            pair.public as java.security.interfaces.ECPublicKey,
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
    fun `ecdh on swapped keypairs produces identical shared secrets`() {
        val client = HermesRelayCrypto.generateEphemeralKeyPair()
        val host = HermesRelayCrypto.generateEphemeralKeyPair()
        val clientShared = HermesRelayCrypto.ecdh(client.private, host.public)
        val hostShared = HermesRelayCrypto.ecdh(host.private, client.public)
        assertArrayEquals(clientShared, hostShared)
        assertEquals(32, clientShared.size)
    }

    // --- HKDF key wrap sharedInfo cross-check --------------------------

    @Test
    fun `two wraps of the same key produce distinct envelopes`() {
        val recipient = HermesRelayCrypto.generateEphemeralKeyPair()
        val recipientPubX963 = HermesRelayCrypto.encodeUncompressedPublicKey(
            recipient.public as java.security.interfaces.ECPublicKey,
        )
        val keyData = HermesRelayCrypto.generateSymmetricKey()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        val one = HermesRelayCrypto.wrapSymmetricKey(keyData, recipientPubX963, aad)
        val two = HermesRelayCrypto.wrapSymmetricKey(keyData, recipientPubX963, aad)
        assertNotEquals("ephemeralPub randomisation must produce distinct wrappings", one, two)
        // Both still unwrap to the same key.
        assertArrayEquals(keyData, HermesRelayCrypto.unwrapSymmetricKey(one, recipient.private, aad))
        assertArrayEquals(keyData, HermesRelayCrypto.unwrapSymmetricKey(two, recipient.private, aad))
    }

    @Test
    fun `sealed payload combined shape is nonce then ciphertext then tag`() {
        val key = HermesRelayCrypto.generateSymmetricKey()
        val aad = HermesRelayCrypto.requestAAD("u", "c", "r")
        val plaintext = ByteArray(16) { it.toByte() }
        val combined = Base64.getDecoder().decode(
            HermesRelayCrypto.sealToBase64(plaintext, key, aad)
        )
        // iOS combined: nonce(12) || ciphertext(N) || tag(16).
        assertEquals(12 + plaintext.size + 16, combined.size)
        assertTrue(combined.size > 28)
    }
}
