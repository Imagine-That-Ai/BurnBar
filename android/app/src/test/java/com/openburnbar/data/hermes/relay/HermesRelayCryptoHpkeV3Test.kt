@file:Suppress("FunctionNaming", "MagicNumber", "TooGenericExceptionCaught", "SwallowedException")
// detekt: JUnit backtick BDD test names intentionally contain spaces; crypto
// negatives deliberately catch broad exceptions to assert "rejected".

package com.openburnbar.data.hermes.relay

import com.openburnbar.test.requireClassLoaderResourceText
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPrivateKeySpec
import java.util.Base64
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * RFC 9180 HPKE **Auth mode** relay key-wrap **v3** contract test.
 *
 * Pins the Android v3 crypto (`HermesRelayCryptoHpkeV3` via the
 * `HermesRelayCrypto.wrapSymmetricKeyV3` / `unwrapSymmetricKeyV3` wire surface)
 * against the frozen suite `hpke-auth-p256-hkdfsha256-aes256gcm`:
 * DHKEM(P-256, HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM, mode_auth,
 * `info = "OpenBurnBar-HermesRelay-HPKE-v3|" ‖ keyAAD`, `aad = keyAAD`.
 *
 * Self round-trip + negative vectors prove the implementation in isolation;
 * cross-language interop is guaranteed by RFC 9180 and is asserted against the
 * shared canonical vector `hermes-relay/HermesGatewayWireVectorV3.json`.
 */
class HermesRelayCryptoHpkeV3Test {
    private companion object {
        const val X963_POINT_BYTES = 65
        const val RAW_SCALAR_BYTES = 32
        const val WRAPPED_KEY_BYTES = 48 // 32-byte content key + 16-byte GCM tag
        const val V3_VECTOR_RESOURCE = "hermes-relay/HermesGatewayWireVectorV3.json"
    }

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

    // ---- constants pinned to the frozen contract ----

    @Test
    fun v3_wire_markers_match_the_frozen_contract() {
        assertEquals(3, HermesRelayCrypto.KEY_VERSION_V3)
        assertEquals("hpke-auth-p256-hkdfsha256-aes256gcm", HermesRelayCrypto.ALGORITHM_V3)
    }

    // ---- self round-trip + structural shape ----

    @Test
    fun seal_then_open_round_trips_and_has_the_canonical_wire_shape() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val key = HermesRelayCrypto.generateSymmetricKey()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")

        val wrap =
            HermesRelayCrypto.wrapSymmetricKeyV3(
                keyData = key,
                recipientPublicKeyX963 = publicX963(recipient.public as ECPublicKey),
                senderPrivateKey = sender.private,
                aad = aad,
            )

        // enc = 65-byte X9.63 ephemeral key; wrappedKey = 48 bytes; sender diag = 65 bytes.
        assertEquals(X963_POINT_BYTES, decode(wrap.enc).size)
        assertEquals(0x04.toByte(), decode(wrap.enc)[0])
        assertEquals(WRAPPED_KEY_BYTES, decode(wrap.wrappedKey).size)
        assertArrayEquals(publicX963(sender.public as ECPublicKey), decode(wrap.senderPublicKey))

        val opened =
            HermesRelayCrypto.unwrapSymmetricKeyV3(
                encBase64 = wrap.enc,
                wrappedKeyBase64 = wrap.wrappedKey,
                privateKey = recipient.private,
                pinnedSenderPublicKeyX963 = publicX963(sender.public as ECPublicKey),
                aad = aad,
            )
        assertArrayEquals("v3 open must recover the sealed content key", key, opened)
    }

    @Test
    fun seal_is_randomized_but_both_envelopes_open_to_the_same_key() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val recipientPubX963 = publicX963(recipient.public as ECPublicKey)
        val senderPubX963 = publicX963(sender.public as ECPublicKey)
        val key = HermesRelayCrypto.generateSymmetricKey()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")

        val a = HermesRelayCrypto.wrapSymmetricKeyV3(key, recipientPubX963, sender.private, aad)
        val b = HermesRelayCrypto.wrapSymmetricKeyV3(key, recipientPubX963, sender.private, aad)
        assertNotEquals("fresh ephemeral per seal ⇒ distinct enc", a.enc, b.enc)
        assertNotEquals(a.wrappedKey, b.wrappedKey)

        assertArrayEquals(key, openWith(a, recipient.private, senderPubX963, aad))
        assertArrayEquals(key, openWith(b, recipient.private, senderPubX963, aad))
    }

    // ---- negative vectors: each mutates exactly one authenticated input ----

    @Test
    fun wrong_pinned_sender_is_rejected() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val forger = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        val wrap = wrapTo(recipient, sender, aad)
        // Pin a DIFFERENT sender key: AuthDecap's second DH + kem_context both
        // change, so the shared secret is wrong and AES-GCM tag verification fails.
        assertRejected {
            openWith(wrap, recipient.private, publicX963(forger.public as ECPublicKey), aad)
        }
    }

    @Test
    fun wrong_recipient_is_rejected() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val other = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        val wrap = wrapTo(recipient, sender, aad)
        assertRejected {
            openWith(wrap, other.private, publicX963(sender.public as ECPublicKey), aad)
        }
    }

    @Test
    fun wrong_aad_is_rejected() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val wrap = wrapTo(recipient, sender, HermesRelayCrypto.keyAAD("u1", "c1", "r1"))
        val wrongAad = HermesRelayCrypto.keyAAD("u1", "c1", "r2")
        assertRejected {
            openWith(wrap, recipient.private, publicX963(sender.public as ECPublicKey), wrongAad)
        }
    }

    @Test
    fun mutated_enc_is_rejected() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        val wrap = wrapTo(recipient, sender, aad)
        val mutatedEnc = encodeFlippedLastByte(wrap.enc)
        assertRejected {
            HermesRelayCrypto.unwrapSymmetricKeyV3(
                encBase64 = mutatedEnc,
                wrappedKeyBase64 = wrap.wrappedKey,
                privateKey = recipient.private,
                pinnedSenderPublicKeyX963 = publicX963(sender.public as ECPublicKey),
                aad = aad,
            )
        }
    }

    @Test
    fun mutated_wrappedKey_is_rejected() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        val wrap = wrapTo(recipient, sender, aad)
        val mutatedWrappedKey = encodeFlippedLastByte(wrap.wrappedKey)
        assertRejected {
            HermesRelayCrypto.unwrapSymmetricKeyV3(
                encBase64 = wrap.enc,
                wrappedKeyBase64 = mutatedWrappedKey,
                privateKey = recipient.private,
                pinnedSenderPublicKeyX963 = publicX963(sender.public as ECPublicKey),
                aad = aad,
            )
        }
    }

    @Test
    fun a_v3_envelope_cannot_be_opened_as_v2_domain_separation() {
        // Concatenate the v3 fields into a single blob and feed it to the v2
        // unwrap: v2 derives a different (single-suite, non-HPKE) wrapping key
        // over a different `info`, so a v3 envelope is unopenable as v2.
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        val wrap = wrapTo(recipient, sender, aad)
        val asV2Blob = encode(decode(wrap.enc) + decode(wrap.wrappedKey))
        assertRejected {
            HermesRelayCrypto.unwrapSymmetricKey(
                wrappedKeyBase64 = asV2Blob,
                privateKey = recipient.private,
                aad = aad,
                senderPublicKeyX963 = publicX963(sender.public as ECPublicKey),
            )
        }
    }

    // ---- v2 path stays green alongside v3 (no regression) ----

    @Test
    fun v2_authenticated_wrap_unwrap_still_round_trips() {
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val key = HermesRelayCrypto.generateSymmetricKey()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        val wrapped =
            HermesRelayCrypto.wrapSymmetricKey(
                keyData = key,
                recipientPublicKeyX963 = publicX963(recipient.public as ECPublicKey),
                aad = aad,
                senderPrivateKey = sender.private,
            )
        val unwrapped =
            HermesRelayCrypto.unwrapSymmetricKey(
                wrappedKeyBase64 = wrapped,
                privateKey = recipient.private,
                aad = aad,
                senderPublicKeyX963 = publicX963(sender.public as ECPublicKey),
            )
        assertArrayEquals(key, unwrapped)
    }

    // ---- shared canonical cross-language vector ----

    @Test
    fun shared_v3_vector_opens_when_the_vector_lane_hands_it_off() {
        val raw =
            runCatching {
                requireClassLoaderResourceText(javaClass.classLoader, V3_VECTOR_RESOURCE)
            }.getOrNull()
        assumeTrue(
            "shared canonical v3 vector ($V3_VECTOR_RESOURCE) is absent",
            raw != null,
        )
        val fixture = JSONObject(raw!!)
        assertEquals(1, fixture.getInt("schemaVersion"))
        assertEquals(3, fixture.getInt("relayKeyVersion"))
        assertEquals(HermesRelayCrypto.ALGORITHM_V3, fixture.getString("relayEncryption"))

        val cases = fixture.getJSONArray("cases")
        var opened = 0
        for (index in 0 until cases.length()) {
            val slot = cases.getJSONObject(index)
            if (slot.getString("expected") != "open" || !slot.has("payloadCiphertext")) {
                continue
            }
            val symKey =
                HermesRelayCrypto.unwrapSymmetricKeyV3(
                    encBase64 = slot.getString("enc"),
                    wrappedKeyBase64 = slot.getString("wrappedKey"),
                    privateKey = recipientPrivateKey(slot),
                    pinnedSenderPublicKeyX963 = decode(slot.getString("pinnedSenderPublicKeyX963")),
                    aad = slot.getString("keyAAD").toByteArray(Charsets.UTF_8),
                )
            assertArrayEquals(
                "v3 unwrap must recover the cross-language content key for ${slot.getString("name")}",
                decode(slot.getString("plaintextContentKey")),
                symKey,
            )
            val plain =
                HermesRelayCrypto.openBase64(
                    ciphertext = slot.getString("payloadCiphertext"),
                    keyData = symKey,
                    aad = slot.getString("payloadAAD").toByteArray(Charsets.UTF_8),
                )
            assertEquals(slot.getString("payloadPlaintext"), String(plain, Charsets.UTF_8))
            opened += 1
        }
        assertTrue("shared v3 vector should contain positive payload cases", opened >= 3)
    }

    // ---- helpers ----

    private fun wrapTo(
        recipient: java.security.KeyPair,
        sender: java.security.KeyPair,
        aad: ByteArray,
    ): HermesRelayCrypto.RelayKeyWrapV3Wire =
        HermesRelayCrypto.wrapSymmetricKeyV3(
            keyData = HermesRelayCrypto.generateSymmetricKey(),
            recipientPublicKeyX963 = publicX963(recipient.public as ECPublicKey),
            senderPrivateKey = sender.private,
            aad = aad,
        )

    private fun openWith(
        wrap: HermesRelayCrypto.RelayKeyWrapV3Wire,
        recipientPrivate: PrivateKey,
        pinnedSenderPubX963: ByteArray,
        aad: ByteArray,
    ): ByteArray =
        HermesRelayCrypto.unwrapSymmetricKeyV3(
            encBase64 = wrap.enc,
            wrappedKeyBase64 = wrap.wrappedKey,
            privateKey = recipientPrivate,
            pinnedSenderPublicKeyX963 = pinnedSenderPubX963,
            aad = aad,
        )

    private fun publicX963(key: ECPublicKey): ByteArray = HermesRelayCryptoEc.encodeUncompressedPublicKey(key)

    private fun decode(base64: String): ByteArray = Base64.getDecoder().decode(base64)

    private fun encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    private fun encodeFlippedLastByte(base64: String): String {
        val bytes = decode(base64)
        bytes[bytes.size - 1] = (bytes[bytes.size - 1].toInt() xor 0xFF).toByte()
        return encode(bytes)
    }

    private inline fun assertRejected(block: () -> Unit) {
        try {
            block()
            fail("expected the v3 open to be rejected, but it returned")
        } catch (expected: Exception) {
            assertTrue(true)
        }
    }

    /** Rebuild a P-256 private key from the raw 32-byte big-endian scalar. */
    private fun recipientPrivateKey(slot: JSONObject): PrivateKey {
        val raw =
            decode(
                if (slot.has("recipientPrivateKeyRaw")) {
                    slot.getString("recipientPrivateKeyRaw")
                } else {
                    slot.getString("recipientPrivateKey")
                },
            )
        assertEquals("recipient private key must be 32 bytes", RAW_SCALAR_BYTES, raw.size)
        val s = java.math.BigInteger(1, raw)
        val params =
            AlgorithmParameters.getInstance("EC").apply {
                init(ECGenParameterSpec("secp256r1"))
            }
        val ecParams = params.getParameterSpec(ECParameterSpec::class.java)
        return KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(s, ecParams))
    }
}
