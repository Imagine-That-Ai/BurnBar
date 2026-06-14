// counters and freshness windows are literal by design.

package com.openburnbar.data.computeruse

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Hostile-input matrix for [PhoneControlSignerVerify]: each gate (key kind,
 * key size, freshness, replay counter, intent hash, signature) must reject
 * independently and fail closed, in the documented order.
 */
class PhoneControlSignerVerifyTest {
    private val seed = ByteArray(32) { (it + 21).toByte() }
    private val publicKey = PhoneControlSigner.publicKey(seed)
    private val nowMillis = 1_700_000_000_000L

    private fun tapIntent() = PhoneControlIntent(
        kind = PhoneControlIntentKind.TAP,
        normalizedX = 0.5,
        normalizedY = 0.5,
        clientIntentId = "intent-v",
    )

    private fun signedAuthority(counter: Long = 5, timestampMillis: Long = nowMillis) =
        PhoneControlSignerSign.sign(tapIntent(), "android-phone-1", counter, timestampMillis, seed)

    private fun verify(
        authority: PhoneControlAuthorityEnvelope,
        key: ByteArray = publicKey,
        lastSeen: Long = 4,
        now: Long = nowMillis,
        freshness: Long = 5_000,
        intent: PhoneControlIntent = tapIntent(),
    ) = PhoneControlSignerVerify.verify(
        intent = intent,
        authority = authority,
        publicKey = key,
        lastSeenCounter = lastSeen,
        nowMillis = now,
        freshnessMillis = freshness,
    )

    @Test
    fun `a fresh in order untampered envelope verifies`() {
        verify(signedAuthority())
        // Skew exactly at the freshness bound is still acceptable (> rejects).
        verify(signedAuthority(), now = nowMillis + 5_000)
    }

    @Test
    fun `unknown keyKind fails closed before any other gate`() {
        // Even with a wrong-size key AND a stale timestamp, the unknown kind
        // must be the rejection — proving nothing downstream consumed state.
        val forged = signedAuthority().copy(keyKind = "rsa-4096")
        val error = assertThrows(PhoneControlVerifyError::class.java) {
            verify(forged, key = ByteArray(99), now = nowMillis + 100_000)
        }
        assertTrue(error is PhoneControlVerifyError.InvalidSignature)
    }

    @Test
    fun `absent and explicit ed25519 keyKind resolve identically`() {
        verify(signedAuthority())
        verify(signedAuthority().copy(keyKind = "ed25519"))
    }

    @Test
    fun `wrong size public key is rejected per key kind`() {
        assertThrows(PhoneControlVerifyError.InvalidPublicKey::class.java) {
            verify(signedAuthority(), key = ByteArray(33))
        }
        // For se-p256 a 32-byte Ed25519 key is the wrong custody class.
        assertThrows(PhoneControlVerifyError.InvalidPublicKey::class.java) {
            verify(signedAuthority().copy(keyKind = "se-p256"), key = ByteArray(32))
        }
    }

    @Test
    fun `stale and future timestamps are rejected with the observed skew`() {
        val past = assertThrows(PhoneControlVerifyError.StaleTimestamp::class.java) {
            verify(signedAuthority(), now = nowMillis + 5_001)
        }
        assertEquals(5_001L, past.skewMillis)
        // Clock skew is symmetric: an envelope from the future is just as stale.
        assertThrows(PhoneControlVerifyError.StaleTimestamp::class.java) {
            verify(signedAuthority(timestampMillis = nowMillis + 6_000))
        }
    }

    @Test
    fun `replayed and stale counters are rejected with both counters surfaced`() {
        val replay = assertThrows(PhoneControlVerifyError.CounterReplay::class.java) {
            verify(signedAuthority(counter = 5), lastSeen = 5)
        }
        assertEquals(5L, replay.lastSeen)
        assertEquals(5L, replay.attempted)
        assertThrows(PhoneControlVerifyError.CounterReplay::class.java) {
            verify(signedAuthority(counter = 3), lastSeen = 9)
        }
    }

    @Test
    fun `an intent that does not hash to the signed hash is rejected`() {
        val swapped = tapIntent().copy(normalizedX = 0.9)
        assertThrows(PhoneControlVerifyError.IntentHashMismatch::class.java) {
            verify(signedAuthority(), intent = swapped)
        }
    }

    @Test
    fun `tampered or undecodable signatures are rejected`() {
        assertThrows(PhoneControlVerifyError.InvalidSignature::class.java) {
            verify(signedAuthority().copy(signatureEd25519 = "&&& not base64 &&&"))
        }
        val other = PhoneControlSignerSign.sign(
            tapIntent(),
            "android-phone-1",
            5,
            nowMillis,
            ByteArray(32) { (it + 99).toByte() },
        )
        // A signature minted by a different key over the same payload.
        assertThrows(PhoneControlVerifyError.InvalidSignature::class.java) {
            verify(signedAuthority().copy(signatureEd25519 = other.signatureEd25519))
        }
    }

    @Test
    fun `tampered envelope fields break the signature binding`() {
        assertThrows(PhoneControlVerifyError::class.java) {
            // Counter forged upward after signing: hash/payload no longer match.
            verify(signedAuthority(counter = 5).copy(counter = 6), lastSeen = 4)
        }
        assertThrows(PhoneControlVerifyError::class.java) {
            verify(signedAuthority().copy(timestampMillis = nowMillis + 1))
        }
    }

    @Test
    fun `se-p256 envelopes verify with both published key encodings`() {
        val generator = java.security.KeyPairGenerator.getInstance("EC")
        generator.initialize(java.security.spec.ECGenParameterSpec("secp256r1"))
        val pair = generator.generateKeyPair()
        val identity = PhoneControlSigningIdentity.SecureEnclaveP256(
            pair.private,
            pair.public as? java.security.interfaces.ECPublicKey ?: error("expected EC public key"),
        )
        val authority = PhoneControlSignerSign.sign(tapIntent(), "android-se-1", 5, nowMillis, identity)
        val x963 = identity.publicKeyRepresentation

        verify(authority, key = x963)
        // Compact 64-byte X‖Y (no 0x04 prefix) is the second accepted form.
        verify(authority, key = x963.copyOfRange(1, 65))
    }
}
