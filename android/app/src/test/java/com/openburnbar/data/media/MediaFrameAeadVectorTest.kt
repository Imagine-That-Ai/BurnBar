// tweak offsets and byte flips are literal by design.

package com.openburnbar.data.media

import com.openburnbar.test.requireClassLoaderResourceText
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * F7 cross-language known-answer test: Kotlin opens the FROZEN Swift-sealed
 * `MediaFrameAEAD` fixture, proving the §3 wire invariant (envelope
 * `"OBMFA1" ‖ 0x01 ‖ AES-256-GCM combined`, AAD
 * `"OpenBurnBar-MediaFrameAEAD-v1|" ‖ streamClass ‖ 0x7C ‖ u8(kind) ‖
 * u32BE(gopID) ‖ u32BE(frameIndex)`, HKDF-SHA256 session key) is
 * byte-identical between CryptoKit and javax.crypto.
 *
 * Regenerate the fixture through the Swift emitter ONLY, then re-vendor:
 *
 *     BURNBAR_EMIT_AEAD_VECTORS=1 swift test --package-path OpenBurnBarCore \
 *       --filter MediaFrameAEADVectorTests
 *     cp OpenBurnBarCore/Tests/OpenBurnBarMediaTests/Fixtures/MediaFrameAEADVector.json \
 *        android/app/src/test/resources/media-aead/MediaFrameAEADVector.json
 */
class MediaFrameAeadVectorTest {
    private companion object {
        const val VECTOR_RESOURCE = "media-aead/MediaFrameAEADVector.json"
    }

    private val fixture: JSONObject by lazy {
        JSONObject(requireClassLoaderResourceText(javaClass.classLoader, VECTOR_RESOURCE))
    }

    private fun cases(): List<JSONObject> {
        val raw = fixture.getJSONArray("cases")
        return (0 until raw.length()).map(raw::getJSONObject)
    }

    // ---- frozen contract ----

    @Test
    fun `fixture pins the frozen v1 contract`() {
        assertEquals(1, fixture.getInt("schemaVersion"))
        assertEquals("MediaFrameAEAD", fixture.getString("primitive"))
        assertEquals("4f424d464131", fixture.getString("magicHex"))
        assertEquals(MediaFrameAead.MAGIC.toHexString(), fixture.getString("magicHex"))
        assertEquals(MediaFrameAead.VERSION.toInt(), fixture.getInt("version"))
        assertEquals("OpenBurnBar-MediaFrameAEAD-v1", fixture.getString("hkdfInfo"))
        assertEquals("OpenBurnBar-MediaFrameAEAD-v1|", fixture.getString("aadPrefix"))
        assertEquals(MediaFrameAeadNegotiation.CAPABILITY, fixture.getString("capability"))
        assertEquals(2, cases().size)
    }

    @Test
    fun `kotlin hkdf derives the exact swift session key`() {
        for (vector in cases()) {
            assertArrayEquals(
                vector.getString("name"),
                hexToBytes(vector.getString("derivedKeyHex")),
                sessionKey(vector),
            )
        }
    }

    @Test
    fun `kotlin aad bytes equal the swift aad bytes`() {
        for (vector in cases()) {
            val aad =
                MediaFrameAead.aad(
                    streamClass = vector.getString("streamClass"),
                    kind = vector.getInt("kind").toUByte(),
                    gopID = vector.getLong("gopID").toUInt(),
                    frameIndex = vector.getLong("frameIndex").toUInt(),
                )
            assertArrayEquals(vector.getString("name"), hexToBytes(vector.getString("aadHex")), aad)
        }
    }

    /** Swift seal → Kotlin open: the core cross-language proof. */
    @Test
    fun `kotlin opens every swift sealed envelope`() {
        for (vector in cases()) {
            val envelope = hexToBytes(vector.getString("envelopeHex"))
            assertTrue(vector.getString("name"), MediaFrameAead.isSealedEnvelope(envelope))
            assertArrayEquals(
                "${vector.getString("name")}: header must be magic ‖ version",
                MediaFrameAead.MAGIC + MediaFrameAead.VERSION,
                envelope.copyOfRange(0, MediaFrameAead.MAGIC.size + 1),
            )
            val opened = open(vector, envelope, sessionKey(vector))
            assertArrayEquals(
                vector.getString("name"),
                hexToBytes(vector.getString("plaintextHex")),
                opened,
            )
        }
    }

    // ---- frozen negatives ----

    @Test
    fun `tampered ciphertext fails to open`() {
        val vector = cases().first()
        val envelope = hexToBytes(vector.getString("envelopeHex"))
        envelope[envelope.size - 1] = (envelope[envelope.size - 1].toInt() xor 0xFF).toByte()
        assertThrows(MediaFrameAeadSealException.OpenFailed::class.java) {
            open(vector, envelope, sessionKey(vector))
        }
    }

    @Test
    fun `wrong frame index fails to open`() {
        val vector = cases().first()
        val envelope = hexToBytes(vector.getString("envelopeHex"))
        assertThrows(MediaFrameAeadSealException.OpenFailed::class.java) {
            open(vector, envelope, sessionKey(vector), frameIndex = vector.getLong("frameIndex").toUInt() + 1u)
        }
    }

    @Test
    fun `wrong stream class fails to open`() {
        val vector = cases().first()
        val envelope = hexToBytes(vector.getString("envelopeHex"))
        assertThrows(MediaFrameAeadSealException.OpenFailed::class.java) {
            open(vector, envelope, sessionKey(vector), streamClass = "control.surface.frame")
        }
    }

    @Test
    fun `wrong key fails to open`() {
        val vector = cases().first()
        val envelope = hexToBytes(vector.getString("envelopeHex"))
        val wrongKey =
            MediaFrameAead.deriveSessionKey(
                sharedSecret = hexToBytes(vector.getString("sharedSecretHex")),
                salt = "a-different-session".toByteArray(Charsets.UTF_8),
            )
        assertThrows(MediaFrameAeadSealException.OpenFailed::class.java) {
            open(vector, envelope, wrongKey)
        }
    }

    @Test
    fun `header mutations fail closed in the swift check order`() {
        val vector = cases().first()
        val key = sessionKey(vector)
        val envelope = hexToBytes(vector.getString("envelopeHex"))

        assertThrows(MediaFrameAeadSealException.EnvelopeTooShort::class.java) {
            open(vector, envelope.copyOfRange(0, 30), key)
        }
        val wrongMagic = envelope.copyOf()
        wrongMagic[0] = (wrongMagic[0].toInt() xor 0xFF).toByte()
        assertThrows(MediaFrameAeadSealException.InvalidMagic::class.java) {
            open(vector, wrongMagic, key)
        }
        val wrongVersion = envelope.copyOf()
        wrongVersion[MediaFrameAead.MAGIC.size] = 2
        assertThrows(MediaFrameAeadSealException.UnsupportedVersion::class.java) {
            open(vector, wrongVersion, key)
        }
    }

    // ---- pure-Kotlin round trip ----

    @Test
    fun `pure kotlin round trip seals with the frozen header and opens`() {
        val vector = cases().first()
        val key = sessionKey(vector)
        val plaintext = "kotlin-sealed media frame payload".toByteArray(Charsets.UTF_8)
        val sealed =
            MediaFrameAead.seal(
                plaintext = plaintext,
                key = key,
                streamClass = "media.screen.video",
                kind = 0x01.toUByte(),
                gopID = 7u,
                frameIndex = 11u,
            )
        assertTrue(MediaFrameAead.isSealedEnvelope(sealed))
        assertArrayEquals(
            MediaFrameAead.MAGIC + MediaFrameAead.VERSION,
            sealed.copyOfRange(0, MediaFrameAead.MAGIC.size + 1),
        )
        assertFalse("frame bytes must not appear in cleartext", containsSubsequence(sealed, plaintext))
        val opened =
            MediaFrameAead.open(
                envelope = sealed,
                key = key,
                streamClass = "media.screen.video",
                kind = 0x01.toUByte(),
                gopID = 7u,
                frameIndex = 11u,
            )
        assertArrayEquals(plaintext, opened)
        // A Kotlin-sealed frame replayed in a different position must not open.
        assertThrows(MediaFrameAeadSealException.OpenFailed::class.java) {
            MediaFrameAead.open(
                envelope = sealed,
                key = key,
                streamClass = "media.screen.video",
                kind = 0x01.toUByte(),
                gopID = 7u,
                frameIndex = 12u,
            )
        }
    }

    @Test
    fun `isSealedEnvelope rejects non sealed bytes`() {
        assertFalse(MediaFrameAead.isSealedEnvelope("plain".toByteArray(Charsets.UTF_8)))
        assertFalse(MediaFrameAead.isSealedEnvelope(ByteArray(0)))
    }

    @Test
    fun `negotiation requires both peers`() {
        assertTrue(MediaFrameAeadNegotiation.resolveSealingEnabled(localSupports = true, remoteSupports = true))
        assertFalse(MediaFrameAeadNegotiation.resolveSealingEnabled(localSupports = true, remoteSupports = false))
        assertFalse(MediaFrameAeadNegotiation.resolveSealingEnabled(localSupports = false, remoteSupports = true))
        assertEquals("media_frame_aead_v1", MediaFrameAeadNegotiation.CAPABILITY)
    }

    // ---- helpers ----

    private fun sessionKey(vector: JSONObject): ByteArray = MediaFrameAead.deriveSessionKey(
        sharedSecret = hexToBytes(vector.getString("sharedSecretHex")),
        salt = hexToBytes(vector.getString("saltHex")),
    )

    private fun open(vector: JSONObject, envelope: ByteArray, key: ByteArray, streamClass: String? = null, frameIndex: UInt? = null): ByteArray =
        MediaFrameAead.open(
            envelope = envelope,
            key = key,
            streamClass = streamClass ?: vector.getString("streamClass"),
            kind = vector.getInt("kind").toUByte(),
            gopID = vector.getLong("gopID").toUInt(),
            frameIndex = frameIndex ?: vector.getLong("frameIndex").toUInt(),
        )

    private fun hexToBytes(value: String): ByteArray {
        require(value.length % 2 == 0) { "odd-length hex: $value" }
        return ByteArray(value.length / 2) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private fun ByteArray.toHexString(): String = joinToString("") { "%02x".format(it) }

    private fun containsSubsequence(haystack: ByteArray, needle: ByteArray): Boolean {
        if (needle.isEmpty() || haystack.size < needle.size) return false
        outer@ for (start in 0..(haystack.size - needle.size)) {
            for (offset in needle.indices) {
                if (haystack[start + offset] != needle[offset]) continue@outer
            }
            return true
        }
        return false
    }
}
