// and counter fixtures are literal by design.

package com.openburnbar.data.computeruse

import com.google.crypto.tink.subtle.Ed25519Verify
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * F2 envelope-producer tests for [PhoneControlSignerSign]: every signing path
 * must bind the canonical payload hash, the counter, and the timestamp into a
 * signature the verify path (and the Swift/Node peers) accept, while legacy
 * Ed25519 envelopes stay byte-identical to pre-F2 (null `keyKind`).
 */
class PhoneControlSignerSignTest {
    private val seed = ByteArray(32) { (it + 11).toByte() }
    private val publicKey = PhoneControlSigner.publicKey(seed)
    private val identity = PhoneControlSigningIdentity.Ed25519(seed)
    private val nowMillis = 1_700_000_000_123L

    private fun tapIntent() = PhoneControlIntent(
        kind = PhoneControlIntentKind.TAP,
        normalizedX = 0.25,
        normalizedY = 0.75,
        clientIntentId = "intent-1",
    )

    @Test
    fun `sign binds the canonical intent hash and stays deterministic for ed25519`() {
        val first = PhoneControlSignerSign.sign(tapIntent(), "android-phone-1", 1, nowMillis, seed)
        val second = PhoneControlSignerSign.sign(tapIntent(), "android-phone-1", 1, nowMillis, seed)

        assertEquals(PhoneControlSignerCanonical.intentHashHex(tapIntent()), first.intentHashBlake3)
        // RFC 8032 Ed25519 is deterministic — replays of the same inputs are
        // byte-identical, the property the pre/post-F2 equivalence relies on.
        assertEquals(first, second)
        assertEquals("android-phone-1", first.peerNodeId)
        assertEquals(1L, first.counter)
        assertEquals(nowMillis, first.timestampMillis)
        // Legacy envelopes must not grow a keyKind field.
        assertNull(first.keyKind)
    }

    @Test
    fun `signed envelope signature verifies over the signable payload`() {
        val authority = PhoneControlSignerSign.sign(tapIntent(), "android-phone-1", 5, nowMillis, identity)
        val payload = PhoneControlSignerPayload.signablePayload(
            intentHashHex = authority.intentHashBlake3,
            counter = authority.counter,
            timestampMillis = authority.timestampMillis,
        )
        // Throws on a bad signature.
        Ed25519Verify(publicKey).verify(Base64.getDecoder().decode(authority.signatureEd25519), payload)
    }

    @Test
    fun `sign rejects a negative counter before producing anything`() {
        assertThrows(IllegalArgumentException::class.java) {
            PhoneControlSignerSign.sign(tapIntent(), "android-phone-1", -1, nowMillis, seed)
        }
    }

    @Test
    fun `clipboard request envelopes round trip through the verify path`() {
        val request = PhoneControlClipboardRequest(
            requestId = "req-1",
            action = PhoneControlClipboardAction.GRAB_FROM_MAC,
            clientIntentId = "intent-2",
        )
        val authority = PhoneControlSignerSign.signClipboardRequest(request, "android-phone-1", 3, nowMillis, seed)
        assertEquals(PhoneControlSignerCanonical.clipboardRequestHashHex(request), authority.intentHashBlake3)
        PhoneControlSignerVerify.verifyClipboardRequest(
            request = request,
            authority = authority,
            publicKey = publicKey,
            lastSeenCounter = 2,
            nowMillis = nowMillis + 1,
        )
    }

    @Test
    fun `system permission request envelopes bind their canonical hash and verify`() {
        val request = PhoneControlSystemPermissionRequest(
            requestId = "req-2",
            kind = PhoneControlSystemPermissionKind.SCREEN_RECORDING,
            action = PhoneControlSystemPermissionAction.PROMPT_AND_OPEN_SETTINGS,
            requestedAtMillis = nowMillis,
        )
        val authority = PhoneControlSignerSign.signSystemPermissionRequest(request, "android-phone-1", 4, nowMillis, identity)
        assertEquals(PhoneControlSignerCanonical.systemPermissionRequestHashHex(request), authority.intentHashBlake3)
        PhoneControlSignerVerify.verifySignedAuthority(
            authority = authority,
            publicKey = publicKey,
            lastSeenCounter = 3,
            nowMillis = nowMillis,
            freshnessMillis = 5_000,
            observedHash = PhoneControlSignerCanonical.systemPermissionRequestHashHex(request),
        )
    }

    @Test
    fun `local auth proof lowercases the hash converts epochs and signs its payload`() {
        val proof = PhoneControlSignerSign.signLocalAuthProof(
            deviceId = "device-1",
            signedIntentHash = "ABCDEF0123",
            authenticatedAtMillis = nowMillis,
            expiresAtSwiftReferenceSeconds = 721_693_100.0,
            privateKeySeed = seed,
            proofId = "proof-1",
        )

        assertEquals("proof-1", proof.proofId)
        assertEquals("device-1", proof.deviceId)
        // The hash is normalized to lowercase on the wire.
        assertEquals("abcdef0123", proof.signedIntentHash)
        assertEquals(AgentCapabilityGrantRequest.swiftReferenceSeconds(nowMillis), proof.authenticatedAt, 1e-9)
        assertEquals(721_693_100.0, proof.expiresAt, 1e-9)

        val payload = PhoneControlSignerPayload.localAuthProofPayload(
            proofId = "proof-1",
            deviceId = "device-1",
            signedIntentHash = "ABCDEF0123",
            authenticatedAtSwiftReferenceSeconds = proof.authenticatedAt,
            expiresAtSwiftReferenceSeconds = proof.expiresAt,
        )
        Ed25519Verify(publicKey).verify(Base64.getDecoder().decode(proof.signatureEd25519), payload)
    }

    @Test
    fun `p256 identity envelopes advertise the se-p256 key kind and verify`() {
        val generator = java.security.KeyPairGenerator.getInstance("EC")
        generator.initialize(java.security.spec.ECGenParameterSpec("secp256r1"))
        val pair = generator.generateKeyPair()
        val p256 = PhoneControlSigningIdentity.SecureEnclaveP256(
            pair.private,
            pair.public as? java.security.interfaces.ECPublicKey ?: error("expected EC public key"),
        )

        val authority = PhoneControlSignerSign.sign(tapIntent(), "android-se-1", 8, nowMillis, p256)
        assertEquals("se-p256", authority.keyKind)
        assertEquals(64, Base64.getDecoder().decode(authority.signatureEd25519).size)
        PhoneControlSignerVerify.verify(
            intent = tapIntent(),
            authority = authority,
            publicKey = p256.publicKeyRepresentation,
            lastSeenCounter = 7,
            nowMillis = nowMillis,
        )
    }
}
