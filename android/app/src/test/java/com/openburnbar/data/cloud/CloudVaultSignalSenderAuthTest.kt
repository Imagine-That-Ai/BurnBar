package com.openburnbar.data.cloud

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.signal.libsignal.protocol.IdentityKeyPair

/**
 * RR-7a at-rest sender-authentication parity — the Android mirror of Swift
 * `SignalAtRestSealerTests` (sender-auth cases) + `SignalAtRestFallbackPolicyTests`.
 *
 * The XEdDSA signature itself is non-deterministic, so the cross-platform KAT pins the
 * length-prefixed SIGNED-MESSAGE bytes (byte-identical to Swift
 * `OpenBurnBarSignalAtRest.senderAuthSignedMessage`) rather than the signature; the sign/verify
 * round-trip and the forge/strip/relocate rejections lock the rest of the contract.
 */
class CloudVaultSignalSenderAuthTest {
    private val binding =
        CloudVaultSignalBinding(uid = "uid-1", collection = "pensieve", docId = "doc-42", field = "body")

    /** Committed KAT for the canonical signed-message framing (computed independently, ASCII fixture). */
    private val katSignedMessageHex =
        "000000274f70656e4275726e4261722d5369676e616c2d4174526573742d53656e646572417574682d7631" +
            "000000684f70656e4275726e4261722d5369676e616c2d4174526573742d76317c4f70656e4275726e4261" +
            "722d5369676e616c2d4141442d76317c61742d726573747c636c6f75647661756c747c7569642d317c7c70" +
            "656e73696576657c646f632d34327c626f64797c7c310000000859326c7761475679000000020000000c64" +
            "65766963652d6b65792d310000000c633256686247566b4c54453d0000000c657363726f772d6b65792d31" +
            "0000000c633256686247566b4c54493d"

    @Test
    fun signedMessageMatchesCommittedKatFraming() {
        val info =
            "${CloudVaultCrypto.SIGNAL_AT_REST_INFO_PREFIX}OpenBurnBar-Signal-AAD-v1|at-rest|cloudvault|uid-1||pensieve|doc-42|body||1"
        val wraps =
            listOf(
                CloudVaultSignalAtRestWrap("device", "device-key-1", "pub1", "c2VhbGVkLTE="),
                CloudVaultSignalAtRestWrap("escrow", "escrow-key-1", "pub2", "c2VhbGVkLTI="),
            )
        val signed = CloudVaultCrypto.senderAuthSignedMessage(info = info, payloadCiphertextB64 = "Y2lwaGVy", wraps = wraps)
        assertEquals(katSignedMessageHex, signed.joinToString("") { "%02x".format(it.toInt() and 0xff) })
    }

    @Test
    fun signedMessageIsWrapOrderIndependent() {
        val info = "${CloudVaultCrypto.SIGNAL_AT_REST_INFO_PREFIX}canonical"
        val a = CloudVaultSignalAtRestWrap("device", "device-key-1", "pub1", "c2VhbGVkLTE=")
        val b = CloudVaultSignalAtRestWrap("escrow", "escrow-key-1", "pub2", "c2VhbGVkLTI=")
        // The signed message sorts wraps by the UTF-8 bytes of recipientIdentityKeyId, so the two
        // recipient orderings produce identical bytes (mirrors the Swift lexicographic sort).
        assertArrayEquals(
            CloudVaultCrypto.senderAuthSignedMessage(info, "cipher", listOf(a, b)),
            CloudVaultCrypto.senderAuthSignedMessage(info, "cipher", listOf(b, a)),
        )
    }

    @Test
    fun envelopeRoundTripsAndVerifiesSenderForEveryRecipient() {
        val device = identity()
        val escrow = identity()
        val plaintext = "cloudvault signal payload".toByteArray()
        val trusted = mapOf("device-key-1" to device.publicKeyData)
        val envelope =
            CloudVaultCrypto.sealSignalPayload(
                plaintext,
                recipients =
                listOf(
                    CloudVaultSignalRecipient("device", "device-key-1", device.publicKeyData),
                    CloudVaultSignalRecipient("escrow", "escrow-key-1", escrow.publicKeyData),
                ),
                binding = binding,
                senderIdentityKeyId = "device-key-1",
                senderIdentityPrivateKey = device.privateKeyData,
                senderIdentityPublicKey = device.publicKeyData,
            )

        assertEquals("device-key-1", envelope.senderAuth?.senderIdentityKeyId)
        assertArrayEquals(
            plaintext,
            CloudVaultCrypto.openSignalPayload(envelope, "device-key-1", device.privateKeyData, binding, trusted),
        )
        // The escrow recipient opens its own wrap but verifies the SAME sender signature.
        assertArrayEquals(
            plaintext,
            CloudVaultCrypto.openSignalPayload(envelope, "escrow-key-1", escrow.privateKeyData, binding, trusted),
        )
    }

    @Test
    fun serverForgedEnvelopeIsRejectedBySenderAuth() {
        // Models P0-1: a malicious server holds the victim's PUBLIC identity key (recipient) and
        // forges an envelope sealed to it, signed by the server's OWN (untrusted) key. The reader
        // pins only the victim device key, so the forgery is rejected.
        val victim = identity()
        val server = identity()
        val forged =
            CloudVaultCrypto.sealSignalPayload(
                "forged approval policy".toByteArray(),
                recipients = listOf(CloudVaultSignalRecipient("device", "victim-device_1", victim.publicKeyData)),
                binding = binding,
                senderIdentityKeyId = "victim-device_1", // server LIES about who sent it
                senderIdentityPrivateKey = server.privateKeyData, // but can only sign with its own key
                senderIdentityPublicKey = server.publicKeyData,
            )
        val error =
            assertThrows(CloudVaultSignalSenderAuthException.SenderSignatureInvalid::class.java) {
                CloudVaultCrypto.openSignalPayload(
                    forged,
                    "victim-device_1",
                    victim.privateKeyData,
                    binding,
                    trustedSenderPublicKeys = mapOf("victim-device_1" to victim.publicKeyData),
                )
            }
        assertTrue(error is CloudVaultSignalSenderAuthException.SenderSignatureInvalid)
    }

    @Test
    fun strippedSenderBlockIsRejected() {
        val device = identity()
        val envelope =
            CloudVaultCrypto.sealSignalPayload(
                "secret".toByteArray(),
                recipients = listOf(CloudVaultSignalRecipient("device", "device-key-1", device.publicKeyData)),
                binding = binding,
                senderIdentityKeyId = "device-key-1",
                senderIdentityPrivateKey = device.privateKeyData,
                senderIdentityPublicKey = device.publicKeyData,
            )
        val stripped = envelope.copy(senderAuth = null)
        assertThrows(CloudVaultSignalSenderAuthException.SenderAuthMissing::class.java) {
            CloudVaultCrypto.openSignalPayload(
                stripped,
                "device-key-1",
                device.privateKeyData,
                binding,
                trustedSenderPublicKeys = mapOf("device-key-1" to device.publicKeyData),
            )
        }
    }

    @Test
    fun untrustedSenderIsRejected() {
        val device = identity()
        val envelope =
            CloudVaultCrypto.sealSignalPayload(
                "secret".toByteArray(),
                recipients = listOf(CloudVaultSignalRecipient("device", "device-key-1", device.publicKeyData)),
                binding = binding,
                senderIdentityKeyId = "device-key-1",
                senderIdentityPrivateKey = device.privateKeyData,
                senderIdentityPublicKey = device.publicKeyData,
            )
        // No pinned sender keys: the sender is not trusted, so the envelope is rejected.
        assertThrows(CloudVaultSignalSenderAuthException.SenderNotTrusted::class.java) {
            CloudVaultCrypto.openSignalPayload(envelope, "device-key-1", device.privateKeyData, binding, emptyMap())
        }
    }

    @Test
    fun ciphertextTamperFailsSenderAuthBeforeAead() {
        val device = identity()
        val envelope =
            CloudVaultCrypto.sealSignalPayload(
                "tamper me".toByteArray(),
                recipients = listOf(CloudVaultSignalRecipient("device", "device-key-1", device.publicKeyData)),
                binding = binding,
                senderIdentityKeyId = "device-key-1",
                senderIdentityPrivateKey = device.privateKeyData,
                senderIdentityPublicKey = device.publicKeyData,
            )
        // Tamper the ciphertext but keep the (now stale) sender signature: the signature covers the
        // ciphertext, so verification fails closed BEFORE any AEAD attempt.
        val mutated =
            envelope.copy(
                ciphertextLayer =
                envelope.ciphertextLayer.copy(
                    payloadCiphertextB64 = envelope.ciphertextLayer.payloadCiphertextB64.dropLast(1) + "A",
                ),
            )
        assertThrows(CloudVaultSignalSenderAuthException.SenderSignatureInvalid::class.java) {
            CloudVaultCrypto.openSignalPayload(
                mutated,
                "device-key-1",
                device.privateKeyData,
                binding,
                trustedSenderPublicKeys = mapOf("device-key-1" to device.publicKeyData),
            )
        }
    }

    @Test
    fun fallbackPolicyFailsClosedForForgedStrippedRelocated() {
        for (complete in listOf(false, true)) {
            assertFalse(
                SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback(
                    CloudVaultSignalSenderAuthException.SenderSignatureInvalid(),
                    complete,
                ),
            )
            assertFalse(
                SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback(
                    CloudVaultSignalSenderAuthException.SenderAuthMissing(),
                    complete,
                ),
            )
            // A relocated/replayed envelope surfaces as the binding-guard IllegalArgumentException.
            assertFalse(
                SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback(IllegalArgumentException("binding mismatch"), complete),
            )
        }
    }

    @Test
    fun fallbackPolicyTreatsUnknownSenderConditionally() {
        val err = CloudVaultSignalSenderAuthException.SenderNotTrusted("device-x")
        assertTrue(SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback(err, senderSetComplete = false))
        assertFalse(SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback(err, senderSetComplete = true))
    }

    @Test
    fun fallbackPolicyPreservesLegacyForStructuralErrors() {
        // A structural error (e.g. "Missing Signal recipient wrap") is not a sender downgrade.
        assertTrue(SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback(IllegalStateException("Missing Signal recipient wrap"), true))
    }

    private fun identity(): AndroidSignalIdentityKeypair {
        val pair = IdentityKeyPair.generate()
        return AndroidSignalIdentityKeypair(
            identityKeyId = "id_1",
            publicKeyData = pair.publicKey.publicKey.serialize(),
            privateKeyData = pair.privateKey.serialize(),
            keyVersion = 1,
        )
    }
}
