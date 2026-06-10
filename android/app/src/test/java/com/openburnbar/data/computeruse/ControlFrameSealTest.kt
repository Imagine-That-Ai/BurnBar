@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; AEAD
// byte offsets and tweak values are literal by design.

package com.openburnbar.data.computeruse

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * F10 pure-Kotlin contract tests for [ControlFrameSeal] — the §3 wire
 * invariants (header layout, AAD byte layout, HKDF key derivation, fail-closed
 * error order) exercised without the frozen Swift fixture. The cross-language
 * KAT lives in [ControlFrameSealVectorTest]; this suite pins the local
 * primitive behavior the KAT builds on.
 */
class ControlFrameSealTest {
    private val key = ControlFrameSeal.deriveSessionKey(
        hpkeSessionKey = ByteArray(32) { (it + 1).toByte() },
        salt = "request-salt".toByteArray(Charsets.UTF_8),
    )
    private val peer = "ios-se-7f3a"
    private val frameType = "control.clipboard.request"
    private val plaintext = """{"clipboardRequest":{"text":"shh"}}""".toByteArray(Charsets.UTF_8)

    // ── key derivation ──

    @Test
    fun `derived session key is 32 bytes and deterministic`() {
        val again = ControlFrameSeal.deriveSessionKey(
            hpkeSessionKey = ByteArray(32) { (it + 1).toByte() },
            salt = "request-salt".toByteArray(Charsets.UTF_8),
        )
        assertEquals(32, key.size)
        assertArrayEquals(key, again)
    }

    @Test
    fun `derived key is domain separated by salt and info`() {
        val ikm = ByteArray(32) { (it + 1).toByte() }
        val salt = "request-salt".toByteArray(Charsets.UTF_8)
        val otherSalt = ControlFrameSeal.deriveSessionKey(ikm, "other-salt".toByteArray(Charsets.UTF_8))
        val otherInfo = ControlFrameSeal.deriveSessionKey(ikm, salt, info = "OpenBurnBar-SomethingElse-v1")
        assertFalse(key.contentEquals(otherSalt))
        assertFalse(key.contentEquals(otherInfo))
        assertEquals("OpenBurnBar-ControlFrameSeal-v1", ControlFrameSeal.DEFAULT_INFO)
    }

    // ── AAD layout ──

    @Test
    fun `aad is prefix peer pipe frameType bytes exactly`() {
        val expected = "OpenBurnBar-ControlFrameSeal-v1|".toByteArray(Charsets.UTF_8) +
            peer.toByteArray(Charsets.UTF_8) +
            byteArrayOf(0x7C) +
            frameType.toByteArray(Charsets.UTF_8)
        assertArrayEquals(expected, ControlFrameSeal.aad(peer, frameType))
    }

    @Test
    fun `aad binds both the controller and the frame type`() {
        assertFalse(ControlFrameSeal.aad(peer, frameType).contentEquals(ControlFrameSeal.aad("ios-se-OTHER", frameType)))
        assertFalse(ControlFrameSeal.aad(peer, frameType).contentEquals(ControlFrameSeal.aad(peer, "control.approval.response")))
    }

    // ── envelope structure ──

    @Test
    fun `sealed envelope is magic version nonce ciphertext tag`() {
        val sealed = ControlFrameSeal.seal(plaintext, key, peer, frameType)
        // magic(6) + version(1) + nonce(12) + ciphertext(len) + tag(16)
        assertEquals(6 + 1 + 12 + plaintext.size + 16, sealed.size)
        assertArrayEquals(ControlFrameSeal.MAGIC + ControlFrameSeal.VERSION, sealed.copyOfRange(0, 7))
        assertTrue(ControlFrameSeal.isSealedEnvelope(sealed))
    }

    @Test
    fun `two seals of the same plaintext never reuse a nonce`() {
        val first = ControlFrameSeal.seal(plaintext, key, peer, frameType)
        val second = ControlFrameSeal.seal(plaintext, key, peer, frameType)
        val firstNonce = first.copyOfRange(7, 19)
        val secondNonce = second.copyOfRange(7, 19)
        assertFalse("AES-GCM nonce must be fresh per seal", firstNonce.contentEquals(secondNonce))
        assertNotEquals(first.toList(), second.toList())
    }

    @Test
    fun `round trip opens to the original plaintext`() {
        val sealed = ControlFrameSeal.seal(plaintext, key, peer, frameType)
        assertArrayEquals(plaintext, ControlFrameSeal.open(sealed, key, peer, frameType))
    }

    // ── fail closed ──

    @Test
    fun `seal and open require a 32 byte key`() {
        val shortKey = ByteArray(16) { 1 }
        assertThrows(IllegalArgumentException::class.java) {
            ControlFrameSeal.seal(plaintext, shortKey, peer, frameType)
        }
        assertThrows(IllegalArgumentException::class.java) {
            ControlFrameSeal.open(ByteArray(64), shortKey, peer, frameType)
        }
    }

    @Test
    fun `header failures surface in swift check order`() {
        val sealed = ControlFrameSeal.seal(plaintext, key, peer, frameType)
        // Length first — even with garbage magic, a short envelope is TooShort.
        assertThrows(ControlFrameSealException.EnvelopeTooShort::class.java) {
            ControlFrameSeal.open(ByteArray(35), key, peer, frameType)
        }
        val badMagic = sealed.copyOf().also { it[0] = (it[0].toInt() xor 0xFF).toByte() }
        assertThrows(ControlFrameSealException.InvalidMagic::class.java) {
            ControlFrameSeal.open(badMagic, key, peer, frameType)
        }
        val badVersion = sealed.copyOf().also { it[6] = 9 }
        val error = assertThrows(ControlFrameSealException.UnsupportedVersion::class.java) {
            ControlFrameSeal.open(badVersion, key, peer, frameType)
        }
        assertEquals(9, error.version)
    }

    @Test
    fun `any aad or ciphertext mismatch throws OpenFailed`() {
        val sealed = ControlFrameSeal.seal(plaintext, key, peer, frameType)
        assertThrows(ControlFrameSealException.OpenFailed::class.java) {
            ControlFrameSeal.open(sealed, key, "ios-se-IMPOSTOR", frameType)
        }
        assertThrows(ControlFrameSealException.OpenFailed::class.java) {
            ControlFrameSeal.open(sealed, key, peer, "control.approval.response")
        }
        val tampered = sealed.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 0x01).toByte() }
        assertThrows(ControlFrameSealException.OpenFailed::class.java) {
            ControlFrameSeal.open(tampered, key, peer, frameType)
        }
    }

    @Test
    fun `isSealedEnvelope detects only the OBCFS1 magic`() {
        assertTrue(ControlFrameSeal.isSealedEnvelope("OBCFS1-and-more".toByteArray(Charsets.UTF_8)))
        assertFalse(ControlFrameSeal.isSealedEnvelope("OBMFA1".toByteArray(Charsets.UTF_8)))
        assertFalse(ControlFrameSeal.isSealedEnvelope("OBCF".toByteArray(Charsets.UTF_8)))
        assertFalse(ControlFrameSeal.isSealedEnvelope(ByteArray(0)))
        assertArrayEquals("OBCFS1".toByteArray(Charsets.US_ASCII), ControlFrameSeal.MAGIC)
    }

    @Test
    fun `negotiation seals only when both peers advertise the capability`() {
        assertEquals("control_seal_v1", ControlFrameSealNegotiation.CAPABILITY)
        assertTrue(ControlFrameSealNegotiation.resolveSealingEnabled(localSupports = true, remoteSupports = true))
        assertFalse(ControlFrameSealNegotiation.resolveSealingEnabled(localSupports = true, remoteSupports = false))
        assertFalse(ControlFrameSealNegotiation.resolveSealingEnabled(localSupports = false, remoteSupports = true))
        assertFalse(ControlFrameSealNegotiation.resolveSealingEnabled(localSupports = false, remoteSupports = false))
    }
}
