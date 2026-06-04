@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.hermes.relay

import com.openburnbar.test.requireClassLoaderResourceText
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPrivateKeySpec
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

private const val RAW_SCALAR_BYTES = 32
private const val X963_POINT_BYTES = 65

/**
 * v2 authenticated key-wrap cross-platform contract test. Pins the Android
 * realtime-relay crypto's **v2 capability** (HPKE-AuthEncap-shaped 2-DH,
 * `ikm = ECDH(r, eph) ‖ ECDH(r, S_pinned)`) against the canonical vector the
 * Swift suite emits in `HermesGatewayWireVector.json`. The gateway envelopes
 * are produced by the Swift source of truth at
 * `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift`;
 * any drift in the v2 derivation (IKM order, empty salt, `info` key shapes, or
 * sender-binding) fails this test immediately.
 *
 * Regenerate the fixture when the contract revision bumps, then copy it into
 * `android/app/src/test/resources/hermes-relay/HermesGatewayWireVector.json`.
 */
class HermesGatewayV2VectorTest {
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
        val raw =
            requireClassLoaderResourceText(
                javaClass.classLoader,
                "hermes-relay/HermesGatewayWireVector.json",
            )
        JSONObject(raw)
    }

    @Test
    fun fixture_uses_v2_revision_and_canonical_algorithm() {
        assertEquals("v2", fixture.getString("revision"))
        assertEquals(2, fixture.getInt("keyVersion"))
        assertEquals(HermesRelayCrypto.ALGORITHM, fixture.getString("algorithm"))
    }

    @Test
    fun v2_unwrap_event_slot_recovers_swift_symmetric_key_and_opens_payload() {
        assertSlotUnwrapsAndOpens(fixture.getJSONObject("event"), wrappedKeyField = "wrappedKey", expectedKeyField = "symmetricKey")
    }

    @Test
    fun v2_unwrap_message_slot_recovers_swift_symmetric_key_and_opens_payload() {
        assertSlotUnwrapsAndOpens(fixture.getJSONObject("message"), wrappedKeyField = "wrappedKey", expectedKeyField = "symmetricKey")
    }

    @Test
    fun v2_unwrap_modelSwitch_slot_recovers_swift_symmetric_key_and_opens_payload() {
        assertSlotUnwrapsAndOpens(fixture.getJSONObject("modelSwitch"), wrappedKeyField = "wrappedKey", expectedKeyField = "symmetricKey")
    }

    @Test
    fun v2_unwrap_attachment_recovers_bodyKey_and_opens_manifest_and_body() {
        val slot = fixture.getJSONObject("attachment")
        val recipientPriv = recipientPrivateKey(slot)
        val senderPubX963 = decodeX963(slot.getString("senderPublicKey"))

        val bodyKey =
            HermesRelayCrypto.unwrapSymmetricKey(
                wrappedKeyBase64 = slot.getString("wrappedKey"),
                privateKey = recipientPriv,
                aad = slot.getString("keyAAD").toByteArray(Charsets.UTF_8),
                senderPublicKeyX963 = senderPubX963,
            )
        assertArrayEquals(
            "v2 unwrap must recover the Swift bodyKey",
            java.util.Base64.getDecoder().decode(slot.getString("bodyKey")),
            bodyKey,
        )

        // One bodyKey seals manifest + body under distinct AADs.
        val manifest =
            HermesRelayCrypto.openBase64(
                ciphertext = slot.getString("manifestCiphertext"),
                keyData = bodyKey,
                aad = slot.getString("manifestAAD").toByteArray(Charsets.UTF_8),
            )
        assertEquals(slot.getString("manifestPlaintext"), String(manifest, Charsets.UTF_8))
        // MP-18: the manifest is JSON; assert the PRODUCTION field name `fileName`
        // (iOS/Android decoders never read `name`) so a drift back to `name` fails
        // here instead of silently passing the byte-compare above.
        val manifestJson = JSONObject(String(manifest, Charsets.UTF_8))
        assertEquals("quarterly-report.pdf", manifestJson.getString("fileName"))
        assertEquals("burnbar:home", manifestJson.getString("destinationId"))

        val body =
            HermesRelayCrypto.openBase64(
                ciphertext = slot.getString("bodyCiphertext"),
                keyData = bodyKey,
                aad = slot.getString("bodyAAD").toByteArray(Charsets.UTF_8),
            )
        assertEquals(slot.getString("bodyPlaintext"), String(body, Charsets.UTF_8))
    }

    @Test(expected = javax.crypto.AEADBadTagException::class)
    fun v2_unwrap_with_wrong_sender_key_throws_AEAD_tag_failure() {
        val slot = fixture.getJSONObject("event")
        val recipientPriv = recipientPrivateKey(slot)
        // Bind the WRONG pinned sender key (the recipient's own X9.63 here, any
        // non-sender key works). The forge defense: the second DH no longer
        // matches the seal, so AES-GCM tag verification fails.
        val wrongSenderPubX963 = decodeX963(slot.getString("recipientPublicKey"))
        HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKeyBase64 = slot.getString("wrappedKey"),
            privateKey = recipientPriv,
            aad = slot.getString("keyAAD").toByteArray(Charsets.UTF_8),
            senderPublicKeyX963 = wrongSenderPubX963,
        )
    }

    @Test(expected = javax.crypto.AEADBadTagException::class)
    fun v1_unwrap_of_a_v2_envelope_throws_because_the_sender_leg_is_unbound() {
        // Omitting the sender key drops to the v1 single-DH derivation, which
        // cannot reproduce the v2 wrapping key — proving v1 and v2 are distinct.
        val slot = fixture.getJSONObject("event")
        val recipientPriv = recipientPrivateKey(slot)
        HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKeyBase64 = slot.getString("wrappedKey"),
            privateKey = recipientPriv,
            aad = slot.getString("keyAAD").toByteArray(Charsets.UTF_8),
        )
    }

    @Test
    fun v2_wrap_unwrap_round_trips_with_pinned_sender_identity() {
        // Native re-seal/open round-trip proves the Android v2 wrap and unwrap
        // legs agree (kem_context + IKM concat parity) independent of the Swift
        // vector — the sender key must be pinned, never wire-asserted.
        val recipient = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sender = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val recipientPubX963 = publicX963(recipient.public)
        val senderPubX963 = publicX963(sender.public)
        val keyData = HermesRelayCrypto.generateSymmetricKey()
        val aad = HermesRelayCrypto.keyAAD("u1", "c1", "r1")

        val wrapped =
            HermesRelayCrypto.wrapSymmetricKey(
                keyData = keyData,
                recipientPublicKeyX963 = recipientPubX963,
                aad = aad,
                senderPrivateKey = sender.private,
            )
        val unwrapped =
            HermesRelayCrypto.unwrapSymmetricKey(
                wrappedKeyBase64 = wrapped,
                privateKey = recipient.private,
                aad = aad,
                senderPublicKeyX963 = senderPubX963,
            )
        assertArrayEquals(keyData, unwrapped)
    }

    @Test
    fun gatewayRelaySafetyCode_is_two_key_role_independent_and_128_bit() {
        // The same two base64 keys + locked code as the Swift + Python tests, so this
        // asserts byte-for-byte cross-language agreement of the safety-code transform.
        val agent = java.util.Base64.getDecoder().decode(
            "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEE="
        )
        val phone = java.util.Base64.getDecoder().decode(
            "QkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYI="
        )
        val code = HermesRelayCrypto.gatewayRelaySafetyCode(agent, phone)
        assertEquals("595F D4F3 50B3 70FA 2D8B 6F15 8004 3F80", code)
        assertEquals(8, code.split(" ").size)
        // Role-independent: swapping the argument order does not change the code.
        assertEquals(code, HermesRelayCrypto.gatewayRelaySafetyCode(phone, agent))
        // Swapping EITHER key changes the code (the single-key MITM MP-1 closes).
        val mutated = agent.copyOf().also { it[0] = (it[0].toInt() xor 0xFF).toByte() }
        org.junit.Assert.assertNotEquals(code, HermesRelayCrypto.gatewayRelaySafetyCode(mutated, phone))
        org.junit.Assert.assertNotEquals(code, HermesRelayCrypto.gatewayRelaySafetyCode(agent, mutated))
    }

    private fun assertSlotUnwrapsAndOpens(slot: JSONObject, wrappedKeyField: String, expectedKeyField: String) {
        val recipientPriv = recipientPrivateKey(slot)
        val senderPubX963 = decodeX963(slot.getString("senderPublicKey"))

        val symKey =
            HermesRelayCrypto.unwrapSymmetricKey(
                wrappedKeyBase64 = slot.getString(wrappedKeyField),
                privateKey = recipientPriv,
                aad = slot.getString("keyAAD").toByteArray(Charsets.UTF_8),
                senderPublicKeyX963 = senderPubX963,
            )
        assertArrayEquals(
            "v2 unwrap must equal the Swift symmetricKey",
            java.util.Base64.getDecoder().decode(slot.getString(expectedKeyField)),
            symKey,
        )

        val plain =
            HermesRelayCrypto.openBase64(
                ciphertext = slot.getString("payloadCiphertext"),
                keyData = symKey,
                aad = slot.getString("payloadAAD").toByteArray(Charsets.UTF_8),
            )
        assertEquals(slot.getString("plaintext"), String(plain, Charsets.UTF_8))
        // MP-27: when the sealed payload is a TEXT message ({text, actionId?, kind?}),
        // decode it through the production schema instead of as a raw string. A
        // model_switch seals {modelId} (no `text`), so skip the text decode there.
        val plaintextJson = JSONObject(slot.getString("plaintext"))
        if (plaintextJson.has("text")) {
            val parsed = HermesRelayCrypto.openGatewaySealedPayload(
                ciphertext = slot.getString("payloadCiphertext"),
                keyData = symKey,
                aad = slot.getString("payloadAAD").toByteArray(Charsets.UTF_8),
            )
            assertEquals(plaintextJson.getString("text"), parsed.text)
        }
        if (plaintextJson.has("destinationId")) {
            assertEquals("burnbar:home", plaintextJson.getString("destinationId"))
        }
    }

    private fun decodeX963(base64: String): ByteArray {
        val bytes = java.util.Base64.getDecoder().decode(base64)
        assertEquals("X9.63 public key must be 65 bytes", X963_POINT_BYTES, bytes.size)
        return bytes
    }

    private fun publicX963(key: java.security.PublicKey): ByteArray {
        val ecPublic =
            key as? java.security.interfaces.ECPublicKey
                ?: error("test fixture expected a P-256 EC public key")
        return HermesRelayCryptoEc.encodeUncompressedPublicKey(ecPublic)
    }

    /**
     * Reconstruct a P-256 private key from the raw big-endian 32-byte scalar
     * Swift emits as `recipientPrivateKey`. The JCE wants `s` as a BigInteger
     * plus the `secp256r1` parameter spec.
     */
    private fun recipientPrivateKey(slot: JSONObject): PrivateKey {
        val raw = java.util.Base64.getDecoder().decode(slot.getString("recipientPrivateKey"))
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
