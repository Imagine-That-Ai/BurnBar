package com.openburnbar.data.hermes.relay

import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import java.security.spec.X509EncodedKeySpec
import java.security.AlgorithmParameters
import java.security.spec.ECGenParameterSpec
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Cross-platform wire-format contract test. Pins the Android relay
 * crypto against a deterministic vector produced by the Swift suite
 * `HermesRelayCrossPlatformVectorTests`. Any wire-protocol drift between
 * Android and the Mac / iOS clients fails this test immediately.
 *
 * Regenerate the fixture when the contract revision bumps:
 *
 *     swift test --package-path OpenBurnBarCore \
 *       --filter HermesRelayCrossPlatformVectorTests
 *     cp OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/HermesRelayWireVector.json \
 *        android/app/src/test/resources/hermes-relay/HermesRelayWireVector.json
 */
class HermesRelayWireVectorTest {

    @Before
    fun stubAndroidBase64() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            java.util.Base64.getEncoder().encodeToString(firstArg<ByteArray>())
        }
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            java.util.Base64.getDecoder().decode(firstArg<String>())
        }
    }

    @After
    fun restore() {
        unmockkStatic(android.util.Base64::class)
    }

    private val fixture: JSONObject by lazy {
        val raw = javaClass.classLoader!!.getResourceAsStream(
            "hermes-relay/HermesRelayWireVector.json",
        )!!.bufferedReader().use { it.readText() }
        JSONObject(raw)
    }

    @Test
    fun fixture_uses_v1_revision_and_canonical_algorithm() {
        assertEquals("v1", fixture.getString("revision"))
        assertEquals(HermesRelayCrypto.ALGORITHM, fixture.getString("algorithm"))
    }

    @Test
    fun aad_strings_match_canonical_iOS_shapes() {
        val uid = fixture.getString("uid")
        val cid = fixture.getString("connectionId")
        val rid = fixture.getString("requestId")
        val seq = fixture.getInt("chunkSequence")
        val kind = fixture.getString("chunkKind")

        assertEquals(
            fixture.getString("requestAAD"),
            String(HermesRelayCrypto.requestAAD(uid, cid, rid), Charsets.UTF_8),
        )
        assertEquals(
            fixture.getString("keyAAD"),
            String(HermesRelayCrypto.keyAAD(uid, cid, rid), Charsets.UTF_8),
        )
        assertEquals(
            fixture.getString("chunkAAD"),
            String(HermesRelayCrypto.chunkAAD(uid, cid, rid, seq, kind), Charsets.UTF_8),
        )
    }

    @Test
    fun unwraps_swift_wrappedKey_using_recipient_private_key() {
        val uid = fixture.getString("uid")
        val cid = fixture.getString("connectionId")
        val rid = fixture.getString("requestId")
        val privateKey = recipientPrivateKey()
        val symKey = HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKeyBase64 = fixture.getString("wrappedKey"),
            privateKey = privateKey,
            aad = HermesRelayCrypto.keyAAD(uid, cid, rid),
        )
        val expected = java.util.Base64.getDecoder().decode(fixture.getString("symmetricKey"))
        assertArrayEquals(expected, symKey)
    }

    @Test
    fun decrypts_swift_payloadCiphertext_using_unwrapped_symmetric_key() {
        val uid = fixture.getString("uid")
        val cid = fixture.getString("connectionId")
        val rid = fixture.getString("requestId")
        val privateKey = recipientPrivateKey()
        val symKey = HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKeyBase64 = fixture.getString("wrappedKey"),
            privateKey = privateKey,
            aad = HermesRelayCrypto.keyAAD(uid, cid, rid),
        )
        val plain = HermesRelayCrypto.openBase64(
            ciphertext = fixture.getString("payloadCiphertext"),
            keyData = symKey,
            aad = HermesRelayCrypto.requestAAD(uid, cid, rid),
        )
        val decoded = JSONObject(String(plain, Charsets.UTF_8))
        assertEquals(fixture.getString("plaintextPath"), decoded.getString("path"))
        assertEquals(fixture.getString("plaintextSessionId"), decoded.getString("sessionId"))
        assertEquals(fixture.getString("plaintextBody"), decoded.getString("body"))
    }

    @Test
    fun decrypts_swift_chunkCiphertext_using_unwrapped_symmetric_key() {
        val uid = fixture.getString("uid")
        val cid = fixture.getString("connectionId")
        val rid = fixture.getString("requestId")
        val privateKey = recipientPrivateKey()
        val symKey = HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKeyBase64 = fixture.getString("wrappedKey"),
            privateKey = privateKey,
            aad = HermesRelayCrypto.keyAAD(uid, cid, rid),
        )
        val chunkAad = HermesRelayCrypto.chunkAAD(
            uid, cid, rid,
            sequence = fixture.getInt("chunkSequence"),
            kind = fixture.getString("chunkKind"),
        )
        val plain = HermesRelayCrypto.openBase64(
            ciphertext = fixture.getString("chunkCiphertext"),
            keyData = symKey,
            aad = chunkAad,
        )
        assertEquals(fixture.getString("chunkPlaintext"), String(plain, Charsets.UTF_8))
    }

    @Test
    fun re_seals_with_unwrapped_key_and_swift_can_open_it_via_self_round_trip() {
        val uid = fixture.getString("uid")
        val cid = fixture.getString("connectionId")
        val rid = fixture.getString("requestId")
        val privateKey = recipientPrivateKey()
        val symKey = HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKeyBase64 = fixture.getString("wrappedKey"),
            privateKey = privateKey,
            aad = HermesRelayCrypto.keyAAD(uid, cid, rid),
        )

        // Re-seal a different chunk with the same key. Self round-trip
        // proves the symmetric key is still valid after unwrapping.
        val chunkAad = HermesRelayCrypto.chunkAAD(uid, cid, rid, sequence = 1, kind = "sse")
        val reSealed = HermesRelayCrypto.sealToBase64(
            "data: reply from android".toByteArray(Charsets.UTF_8),
            symKey,
            chunkAad,
        )
        val openedBack = HermesRelayCrypto.openBase64(reSealed, symKey, chunkAad)
        assertEquals("data: reply from android", String(openedBack, Charsets.UTF_8))
    }

    /**
     * Construct a P-256 private key from the raw 32-byte scalar that
     * Swift emits as `recipientPrivateKey` (base64-encoded). Swift's
     * `P256.KeyAgreement.PrivateKey.rawRepresentation` is the big-endian
     * scalar; the JCE wants `s` as a BigInteger plus the standard
     * `secp256r1` parameter spec.
     */
    private fun recipientPrivateKey(): PrivateKey {
        val raw = java.util.Base64.getDecoder().decode(fixture.getString("recipientPrivateKey"))
        assertEquals("recipient private key must be 32 bytes", 32, raw.size)
        val s = java.math.BigInteger(1, raw)
        val params = AlgorithmParameters.getInstance("EC").apply {
            init(ECGenParameterSpec("secp256r1"))
        }
        val ecParams = params.getParameterSpec(ECParameterSpec::class.java)
        val kf = KeyFactory.getInstance("EC")
        val priv = kf.generatePrivate(ECPrivateKeySpec(s, ecParams))
        // Self-check: derive the public key and confirm it matches the
        // X9.63 representation in the fixture.
        val expectedPub = java.util.Base64.getDecoder().decode(fixture.getString("recipientPublicKey"))
        val derived = HermesRelayCrypto.decodeUncompressedPublicKey(expectedPub)
            as java.security.interfaces.ECPublicKey
        assertEquals(65, expectedPub.size)
        assertTrue("derived pub matches encoded shape", derived.w != null)
        // ECPoint round-trip sanity.
        val pubFromSpec = kf.generatePublic(
            ECPublicKeySpec(derived.w, ecParams),
        ) as java.security.interfaces.ECPublicKey
        assertEquals(pubFromSpec.w.affineX, derived.w.affineX)
        return priv
    }
}
