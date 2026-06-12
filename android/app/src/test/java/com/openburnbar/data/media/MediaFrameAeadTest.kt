// byte offsets and tweak values are literal by design.

package com.openburnbar.data.media

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * F7 pure-Kotlin contract tests for [MediaFrameAead] — header layout, the
 * big-endian AAD lanes, HKDF derivation, and the fail-closed error order —
 * exercised without the frozen Swift fixture. The cross-language KAT lives in
 * [MediaFrameAeadVectorTest]; this suite pins the local primitive behavior.
 */
class MediaFrameAeadTest {
    private val key = MediaFrameAead.deriveSessionKey(
        sharedSecret = ByteArray(32) { (it * 3 + 1).toByte() },
        salt = "pairing-salt".toByteArray(Charsets.UTF_8),
    )
    private val streamClass = "media.screen.h264"
    private val kind: UByte = 1u
    private val gopId: UInt = 0x01020304u
    private val frameIndex: UInt = 0xA1B2C3D4u
    private val payload = ByteArray(48) { (it * 7).toByte() }

    // ── key derivation ──

    @Test
    fun `derived session key is 32 bytes deterministic and info separated`() {
        val secret = ByteArray(32) { (it * 3 + 1).toByte() }
        val salt = "pairing-salt".toByteArray(Charsets.UTF_8)
        assertEquals(32, key.size)
        assertArrayEquals(key, MediaFrameAead.deriveSessionKey(secret, salt))
        assertFalse(key.contentEquals(MediaFrameAead.deriveSessionKey(secret, "other".toByteArray(Charsets.UTF_8))))
        assertFalse(key.contentEquals(MediaFrameAead.deriveSessionKey(secret, salt, info = "OpenBurnBar-Other-v1")))
        assertEquals("OpenBurnBar-MediaFrameAEAD-v1", MediaFrameAead.DEFAULT_INFO)
    }

    // ── AAD layout ──

    @Test
    fun `aad lays out prefix streamClass pipe kind and big endian u32 lanes`() {
        val aad = MediaFrameAead.aad(streamClass, kind, gopId, frameIndex)
        val expected = "OpenBurnBar-MediaFrameAEAD-v1|".toByteArray(Charsets.UTF_8) +
            streamClass.toByteArray(Charsets.UTF_8) +
            byteArrayOf(0x7C) +
            byteArrayOf(0x01) + // kind u8
            byteArrayOf(0x01, 0x02, 0x03, 0x04) + // gopID u32 big-endian
            byteArrayOf(0xA1.toByte(), 0xB2.toByte(), 0xC3.toByte(), 0xD4.toByte()) // frameIndex u32 big-endian
        assertArrayEquals(expected, aad)
    }

    @Test
    fun `aad differs for every identity lane`() {
        val base = MediaFrameAead.aad(streamClass, kind, gopId, frameIndex)
        assertFalse(base.contentEquals(MediaFrameAead.aad("media.camera.h264", kind, gopId, frameIndex)))
        assertFalse(base.contentEquals(MediaFrameAead.aad(streamClass, 2u, gopId, frameIndex)))
        assertFalse(base.contentEquals(MediaFrameAead.aad(streamClass, kind, gopId + 1u, frameIndex)))
        assertFalse(base.contentEquals(MediaFrameAead.aad(streamClass, kind, gopId, frameIndex + 1u)))
    }

    // ── envelope structure + round trip ──

    @Test
    fun `sealed envelope is magic version nonce ciphertext tag and round trips`() {
        val sealed = MediaFrameAead.seal(payload, key, streamClass, kind, gopId, frameIndex)
        // magic(6) + version(1) + nonce(12) + ciphertext(len) + tag(16)
        assertEquals(6 + 1 + 12 + payload.size + 16, sealed.size)
        assertArrayEquals(MediaFrameAead.MAGIC + MediaFrameAead.VERSION, sealed.copyOfRange(0, 7))
        assertTrue(MediaFrameAead.isSealedEnvelope(sealed))
        assertArrayEquals(payload, MediaFrameAead.open(sealed, key, streamClass, kind, gopId, frameIndex))
    }

    @Test
    fun `two seals of the same frame never reuse a nonce`() {
        val first = MediaFrameAead.seal(payload, key, streamClass, kind, gopId, frameIndex)
        val second = MediaFrameAead.seal(payload, key, streamClass, kind, gopId, frameIndex)
        assertFalse(first.copyOfRange(7, 19).contentEquals(second.copyOfRange(7, 19)))
    }

    // ── fail closed ──

    @Test
    fun `seal and open require a 32 byte key`() {
        assertThrows(IllegalArgumentException::class.java) {
            MediaFrameAead.seal(payload, ByteArray(31), streamClass, kind, gopId, frameIndex)
        }
        assertThrows(IllegalArgumentException::class.java) {
            MediaFrameAead.open(ByteArray(64), ByteArray(31), streamClass, kind, gopId, frameIndex)
        }
    }

    @Test
    fun `a sealed frame opens only at its exact stream position`() {
        val sealed = MediaFrameAead.seal(payload, key, streamClass, kind, gopId, frameIndex)
        assertThrows(MediaFrameAeadSealException.OpenFailed::class.java) {
            MediaFrameAead.open(sealed, key, "media.camera.h264", kind, gopId, frameIndex)
        }
        assertThrows(MediaFrameAeadSealException.OpenFailed::class.java) {
            MediaFrameAead.open(sealed, key, streamClass, 2u, gopId, frameIndex)
        }
        assertThrows(MediaFrameAeadSealException.OpenFailed::class.java) {
            MediaFrameAead.open(sealed, key, streamClass, kind, gopId + 1u, frameIndex)
        }
        assertThrows(MediaFrameAeadSealException.OpenFailed::class.java) {
            // A replayed frame spliced into a later slot must not decrypt.
            MediaFrameAead.open(sealed, key, streamClass, kind, gopId, frameIndex + 1u)
        }
    }

    @Test
    fun `header failures surface in swift check order with the version surfaced`() {
        val sealed = MediaFrameAead.seal(payload, key, streamClass, kind, gopId, frameIndex)
        assertThrows(MediaFrameAeadSealException.EnvelopeTooShort::class.java) {
            MediaFrameAead.open(sealed.copyOfRange(0, 35), key, streamClass, kind, gopId, frameIndex)
        }
        val badMagic = sealed.copyOf().also { it[0] = (it[0].toInt() xor 0xFF).toByte() }
        assertThrows(MediaFrameAeadSealException.InvalidMagic::class.java) {
            MediaFrameAead.open(badMagic, key, streamClass, kind, gopId, frameIndex)
        }
        val badVersion = sealed.copyOf().also { it[6] = 0xFE.toByte() }
        val error = assertThrows(MediaFrameAeadSealException.UnsupportedVersion::class.java) {
            MediaFrameAead.open(badVersion, key, streamClass, kind, gopId, frameIndex)
        }
        // The version byte is reported unsigned, never sign-extended.
        assertEquals(0xFE, error.version)
    }

    @Test
    fun `isSealedEnvelope detects only the OBMFA1 magic`() {
        assertArrayEquals("OBMFA1".toByteArray(Charsets.US_ASCII), MediaFrameAead.MAGIC)
        assertTrue(MediaFrameAead.isSealedEnvelope("OBMFA1tail".toByteArray(Charsets.UTF_8)))
        assertFalse(MediaFrameAead.isSealedEnvelope("OBCFS1".toByteArray(Charsets.UTF_8)))
        assertFalse(MediaFrameAead.isSealedEnvelope(ByteArray(0)))
    }

    @Test
    fun `negotiation seals only when both peers advertise the capability`() {
        assertEquals("media_frame_aead_v1", MediaFrameAeadNegotiation.CAPABILITY)
        assertTrue(MediaFrameAeadNegotiation.resolveSealingEnabled(localSupports = true, remoteSupports = true))
        assertFalse(MediaFrameAeadNegotiation.resolveSealingEnabled(localSupports = true, remoteSupports = false))
        assertFalse(MediaFrameAeadNegotiation.resolveSealingEnabled(localSupports = false, remoteSupports = true))
        assertFalse(MediaFrameAeadNegotiation.resolveSealingEnabled(localSupports = false, remoteSupports = false))
    }
}
