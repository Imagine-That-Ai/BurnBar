@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; KAT
// tweak offsets and byte flips are literal by design.

package com.openburnbar.data.computeruse

import com.openburnbar.test.requireClassLoaderResourceText
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * F10 cross-language known-answer test: Kotlin opens the FROZEN Swift-sealed
 * `ControlFrameSeal` fixture, proving the §3 wire invariant (envelope
 * `"OBCFS1" ‖ 0x01 ‖ AES-256-GCM combined`, AAD
 * `"OpenBurnBar-ControlFrameSeal-v1|" ‖ peerNodeId ‖ 0x7C ‖ frameType`,
 * HKDF-SHA256 session key) is byte-identical between CryptoKit and
 * javax.crypto.
 *
 * Regenerate the fixture through the Swift emitter ONLY, then re-vendor:
 *
 *     BURNBAR_EMIT_AEAD_VECTORS=1 swift test --package-path OpenBurnBarCore \
 *       --filter ControlFrameSealVectorTests
 *     cp OpenBurnBarCore/Tests/OpenBurnBarComputerUseCoreTests/Fixtures/ControlFrameSealVector.json \
 *        android/app/src/test/resources/control-seal/ControlFrameSealVector.json
 */
class ControlFrameSealVectorTest {
    private companion object {
        const val VECTOR_RESOURCE = "control-seal/ControlFrameSealVector.json"
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
        assertEquals("ControlFrameSeal", fixture.getString("primitive"))
        assertEquals("4f4243465331", fixture.getString("magicHex"))
        assertEquals(ControlFrameSeal.MAGIC.toHexString(), fixture.getString("magicHex"))
        assertEquals(ControlFrameSeal.VERSION.toInt(), fixture.getInt("version"))
        assertEquals("OpenBurnBar-ControlFrameSeal-v1", fixture.getString("hkdfInfo"))
        assertEquals("OpenBurnBar-ControlFrameSeal-v1|", fixture.getString("aadPrefix"))
        assertEquals(ControlFrameSealNegotiation.CAPABILITY, fixture.getString("capability"))
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
                ControlFrameSeal.aad(
                    peerNodeId = vector.getString("peerNodeId"),
                    frameType = vector.getString("frameType"),
                )
            assertArrayEquals(vector.getString("name"), hexToBytes(vector.getString("aadHex")), aad)
        }
    }

    /** Swift seal → Kotlin open: the core cross-language proof. */
    @Test
    fun `kotlin opens every swift sealed envelope`() {
        for (vector in cases()) {
            val envelope = hexToBytes(vector.getString("envelopeHex"))
            assertTrue(vector.getString("name"), ControlFrameSeal.isSealedEnvelope(envelope))
            assertArrayEquals(
                "${vector.getString("name")}: header must be magic ‖ version",
                ControlFrameSeal.MAGIC + ControlFrameSeal.VERSION,
                envelope.copyOfRange(0, ControlFrameSeal.MAGIC.size + 1),
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
        assertThrows(ControlFrameSealException.OpenFailed::class.java) {
            open(vector, envelope, sessionKey(vector))
        }
    }

    @Test
    fun `wrong peer node id fails to open`() {
        val vector = cases().first()
        val envelope = hexToBytes(vector.getString("envelopeHex"))
        assertThrows(ControlFrameSealException.OpenFailed::class.java) {
            open(vector, envelope, sessionKey(vector), peerNodeId = "ios-se-IMPOSTOR")
        }
    }

    @Test
    fun `wrong frame type fails to open`() {
        val vector = cases().first()
        val envelope = hexToBytes(vector.getString("envelopeHex"))
        assertThrows(ControlFrameSealException.OpenFailed::class.java) {
            open(vector, envelope, sessionKey(vector), frameType = "control.approval.response")
        }
    }

    @Test
    fun `wrong key fails to open`() {
        val vector = cases().first()
        val envelope = hexToBytes(vector.getString("envelopeHex"))
        val wrongKey =
            ControlFrameSeal.deriveSessionKey(
                hpkeSessionKey = hexToBytes(vector.getString("hpkeSessionKeyHex")),
                salt = "a-different-request".toByteArray(Charsets.UTF_8),
            )
        assertThrows(ControlFrameSealException.OpenFailed::class.java) {
            open(vector, envelope, wrongKey)
        }
    }

    @Test
    fun `header mutations fail closed in the swift check order`() {
        val vector = cases().first()
        val key = sessionKey(vector)
        val envelope = hexToBytes(vector.getString("envelopeHex"))

        assertThrows(ControlFrameSealException.EnvelopeTooShort::class.java) {
            open(vector, envelope.copyOfRange(0, 30), key)
        }
        val wrongMagic = envelope.copyOf()
        wrongMagic[0] = (wrongMagic[0].toInt() xor 0xFF).toByte()
        assertThrows(ControlFrameSealException.InvalidMagic::class.java) {
            open(vector, wrongMagic, key)
        }
        val wrongVersion = envelope.copyOf()
        wrongVersion[ControlFrameSeal.MAGIC.size] = 2
        assertThrows(ControlFrameSealException.UnsupportedVersion::class.java) {
            open(vector, wrongVersion, key)
        }
    }

    // ---- pure-Kotlin round trip ----

    @Test
    fun `pure kotlin round trip seals with the frozen header and opens`() {
        val vector = cases().first()
        val key = sessionKey(vector)
        val plaintext = """{"clipboardRequest":{"text":"kotlin secret"}}""".toByteArray(Charsets.UTF_8)
        val sealed =
            ControlFrameSeal.seal(
                plaintext = plaintext,
                key = key,
                peerNodeId = "ios-se-abc",
                frameType = "control.clipboard.request",
            )
        assertTrue(ControlFrameSeal.isSealedEnvelope(sealed))
        assertArrayEquals(
            ControlFrameSeal.MAGIC + ControlFrameSeal.VERSION,
            sealed.copyOfRange(0, ControlFrameSeal.MAGIC.size + 1),
        )
        assertFalse("control JSON must not appear in cleartext", containsSubsequence(sealed, plaintext))
        val opened =
            ControlFrameSeal.open(
                envelope = sealed,
                key = key,
                peerNodeId = "ios-se-abc",
                frameType = "control.clipboard.request",
            )
        assertArrayEquals(plaintext, opened)
        // A Kotlin-sealed frame replayed across peers must not open.
        assertThrows(ControlFrameSealException.OpenFailed::class.java) {
            ControlFrameSeal.open(
                envelope = sealed,
                key = key,
                peerNodeId = "ios-se-OTHER",
                frameType = "control.clipboard.request",
            )
        }
    }

    @Test
    fun `isSealedEnvelope rejects non sealed bytes`() {
        assertFalse(ControlFrameSeal.isSealedEnvelope("plain".toByteArray(Charsets.UTF_8)))
        assertFalse(ControlFrameSeal.isSealedEnvelope(ByteArray(0)))
    }

    @Test
    fun `negotiation requires both peers`() {
        assertTrue(ControlFrameSealNegotiation.resolveSealingEnabled(localSupports = true, remoteSupports = true))
        assertFalse(ControlFrameSealNegotiation.resolveSealingEnabled(localSupports = true, remoteSupports = false))
        assertFalse(ControlFrameSealNegotiation.resolveSealingEnabled(localSupports = false, remoteSupports = true))
        assertEquals("control_seal_v1", ControlFrameSealNegotiation.CAPABILITY)
    }

    // ---- helpers ----

    private fun sessionKey(vector: JSONObject): ByteArray = ControlFrameSeal.deriveSessionKey(
        hpkeSessionKey = hexToBytes(vector.getString("hpkeSessionKeyHex")),
        salt = hexToBytes(vector.getString("saltHex")),
    )

    private fun open(vector: JSONObject, envelope: ByteArray, key: ByteArray, peerNodeId: String? = null, frameType: String? = null): ByteArray =
        ControlFrameSeal.open(
            envelope = envelope,
            key = key,
            peerNodeId = peerNodeId ?: vector.getString("peerNodeId"),
            frameType = frameType ?: vector.getString("frameType"),
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
