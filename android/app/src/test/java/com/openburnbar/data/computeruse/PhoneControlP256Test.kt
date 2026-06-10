@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; DER tag
// bytes and coordinate widths are literal by design.

package com.openburnbar.data.computeruse

import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * F2 wire-format tests for [PhoneControlP256]: the 65-byte X9.63 public-key
 * form, the DER ↔ raw `r‖s` ECDSA signature codec, and the dual-encoding
 * verifier. ECDSA is non-deterministic, so signatures are always verified —
 * never compared byte-for-byte.
 */
class PhoneControlP256Test {
    private fun newKeyPair() = KeyPairGenerator.getInstance("EC")
        .apply { initialize(ECGenParameterSpec("secp256r1")) }
        .generateKeyPair()

    private fun derSign(payload: ByteArray, keyPair: java.security.KeyPair): ByteArray = Signature.getInstance("SHA256withECDSA").run {
        initSign(keyPair.private)
        update(payload)
        sign()
    }

    // ── public key wire form ──

    @Test
    fun `x963 representation is 65 bytes with the 0x04 uncompressed prefix`() {
        val publicKey = newKeyPair().public as ECPublicKey
        val x963 = PhoneControlP256.x963Representation(publicKey)
        assertEquals(65, x963.size)
        assertEquals(0x04.toByte(), x963[0])
    }

    @Test
    fun `x963 bytes round trip through publicKeyFromRepresentation`() {
        val publicKey = newKeyPair().public as ECPublicKey
        val x963 = PhoneControlP256.x963Representation(publicKey)
        val rebuilt = PhoneControlP256.publicKeyFromRepresentation(x963)
        assertEquals(publicKey.w, requireNotNull(rebuilt).w)
        assertArrayEquals(x963, PhoneControlP256.x963Representation(rebuilt))
    }

    @Test
    fun `compact 64 byte raw XY form also rebuilds the same point`() {
        val publicKey = newKeyPair().public as ECPublicKey
        val x963 = PhoneControlP256.x963Representation(publicKey)
        val compact = x963.copyOfRange(1, 65)
        val rebuilt = PhoneControlP256.publicKeyFromRepresentation(compact)
        assertEquals(publicKey.w, requireNotNull(rebuilt).w)
    }

    @Test
    fun `malformed public key bytes return null instead of throwing`() {
        assertNull(PhoneControlP256.publicKeyFromRepresentation(ByteArray(0)))
        assertNull(PhoneControlP256.publicKeyFromRepresentation(ByteArray(32)))
        assertNull(PhoneControlP256.publicKeyFromRepresentation(ByteArray(66)))
        // 65 bytes but a compressed-form prefix is rejected.
        val badPrefix = ByteArray(65).also { it[0] = 0x02 }
        assertNull(PhoneControlP256.publicKeyFromRepresentation(badPrefix))
    }

    // ── DER ↔ raw signature codec ──

    @Test
    fun `der to raw signature is 64 bytes and round trips through raw to der`() {
        val keyPair = newKeyPair()
        val payload = "phone-control-payload".toByteArray(Charsets.UTF_8)
        repeat(16) {
            val der = derSign(payload, keyPair)
            val raw = PhoneControlP256.derToRawSignature(der)
            assertEquals(64, raw.size)
            // raw → DER must verify under plain JCA, proving the codec emits
            // canonical minimal two's-complement INTEGERs.
            val verifier = Signature.getInstance("SHA256withECDSA")
            verifier.initVerify(keyPair.public)
            verifier.update(payload)
            assertTrue(verifier.verify(PhoneControlP256.rawToDerSignature(raw)))
        }
    }

    @Test
    fun `derToRawSignature rejects malformed der`() {
        assertThrows(IllegalArgumentException::class.java) {
            PhoneControlP256.derToRawSignature(ByteArray(0))
        }
        assertThrows(IllegalArgumentException::class.java) {
            // Not a SEQUENCE.
            PhoneControlP256.derToRawSignature(byteArrayOf(0x02, 0x01, 0x01))
        }
        val keyPair = newKeyPair()
        val der = derSign("x".toByteArray(), keyPair)
        assertThrows(IllegalArgumentException::class.java) {
            // Trailing bytes after the second INTEGER.
            PhoneControlP256.derToRawSignature(der + byteArrayOf(0x00))
        }
    }

    @Test
    fun `rawToDerSignature requires exactly 64 bytes`() {
        assertThrows(IllegalArgumentException::class.java) {
            PhoneControlP256.rawToDerSignature(ByteArray(63))
        }
        assertThrows(IllegalArgumentException::class.java) {
            PhoneControlP256.rawToDerSignature(ByteArray(65))
        }
    }

    // ── verifier dual acceptance ──

    @Test
    fun `verifySignature accepts both the raw wire form and strict der`() {
        val keyPair = newKeyPair()
        val publicKey = keyPair.public as ECPublicKey
        val payload = "intent-hash|counter|timestamp".toByteArray(Charsets.UTF_8)
        val der = derSign(payload, keyPair)
        val raw = PhoneControlP256.derToRawSignature(der)

        assertTrue(PhoneControlP256.verifySignature(publicKey, raw, payload))
        assertTrue(PhoneControlP256.verifySignature(publicKey, der, payload))
    }

    @Test
    fun `verifySignature rejects tampered payloads keys and signatures`() {
        val keyPair = newKeyPair()
        val publicKey = keyPair.public as ECPublicKey
        val payload = "intent-hash|counter|timestamp".toByteArray(Charsets.UTF_8)
        val raw = PhoneControlP256.derToRawSignature(derSign(payload, keyPair))

        assertFalse(PhoneControlP256.verifySignature(publicKey, raw, payload + 0x01))
        val otherKey = newKeyPair().public as ECPublicKey
        assertFalse(PhoneControlP256.verifySignature(otherKey, raw, payload))
        val flipped = raw.copyOf().also { it[10] = (it[10].toInt() xor 0xFF).toByte() }
        assertFalse(PhoneControlP256.verifySignature(publicKey, flipped, payload))
        // Garbage that is neither raw nor DER returns false, never throws.
        assertFalse(PhoneControlP256.verifySignature(publicKey, ByteArray(10), payload))
    }
}
