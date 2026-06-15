package com.openburnbar.data.cloud

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 2.5 G4 — rotation/rewrap cross-device handoff KAT (Android mirror of Swift
 * `CloudVaultRotationHandoffKATTests`).
 *
 * The rotation/rewrap worker requires live Firestore/Functions/Storage and is not unit-testable;
 * this KAT pins the pure crypto contract it delegates to per document
 * (`CloudVaultCrypto.rewrapCloudVaultDocument`): after rotation the NEW key opens, the OLD wrap is
 * gone (old key fails closed via the vaultKeyID guard), a stale pre-rotation ciphertext fails
 * closed, and the Signal identity transition (v1 -> v2) the rotation event records is well-formed.
 * Uses the AES-256-GCM symmetric vault path, so the Signal envelope/relay-key versions are
 * untouched (flag-OFF).
 */
class AndroidCloudVaultRotationHandoffKatTest {
    @Test
    fun rotationHandoffNewKeyOpensOldWrapGoneStaleClaimFailsClosed() {
        val oldKey = ByteArray(32) { 0x41.toByte() }
        val newKey = ByteArray(32) { 0x42.toByte() }
        val oldVaultKeyID = CloudVaultCrypto.vaultKeyID(oldKey)
        val newVaultKeyID = CloudVaultCrypto.vaultKeyID(newKey)
        assertNotEquals(oldVaultKeyID, newVaultKeyID)

        val uid = "user-1"
        val collection = "session_logs"
        val docID = "doc-1"
        val payloadContext = CloudVaultAADContext(uid = uid, collection = collection, docID = docID, field = "sealedPayload")

        // Seal a document under the OLD vault key (the pre-rotation state).
        val payloadPlaintext = """{"body":"pre-rotation secret"}""".toByteArray()
        val staleEnvelope = CloudVaultCrypto.sealPayload(payloadPlaintext, oldKey, oldVaultKeyID)
        val document =
            mapOf<String, Any?>(
                "vaultKeyID" to oldVaultKeyID,
                "sealedPayload" to CloudVaultCrypto.sealedPayloadMap(staleEnvelope),
                "sealedDisplayLabel" to CloudVaultCrypto.sealedTextMap(CloudVaultCrypto.sealText("release policy", oldKey)),
                "plainStatus" to "active",
            )

        // REWRAP — exactly what the rotation worker performs per document on handoff.
        val rewrapJobId = "rewrap_${newVaultKeyID.take(12)}"
        val result =
            CloudVaultCrypto.rewrapCloudVaultDocument(
                data = document,
                uid = uid,
                collection = collection,
                docID = docID,
                oldKey = oldKey,
                newKey = newKey,
                newVaultKeyID = newVaultKeyID,
                vaultGeneration = 2,
                rotationJobId = rewrapJobId,
            )

        assertEquals(newVaultKeyID, result.data["vaultKeyID"])
        assertEquals(2, result.data["vaultGeneration"])
        assertEquals(rewrapJobId, result.data["rewrapJobId"])
        assertEquals("active", result.data["plainStatus"])
        assertTrue(result.changedFields.contains("sealedPayload"))

        // NEW key opens the resealed envelope.
        val resealed = requireNotNull(CloudVaultCrypto.sealedPayloadFromMap(result.data["sealedPayload"] as? Map<*, *>))
        assertEquals(newVaultKeyID, resealed.vaultKeyID)
        assertNotEquals(oldVaultKeyID, resealed.vaultKeyID)
        assertArrayEquals(payloadPlaintext, CloudVaultCrypto.openPayload(resealed, newKey, payloadContext))

        // OLD wrap is gone: the OLD key no longer opens the resealed payload. The vaultKeyID guard
        // fires (presented key's id != envelope's new id) — a structured "Vault key mismatch", not a
        // raw AEAD failure.
        val oldKeyError =
            assertThrows(IllegalArgumentException::class.java) {
                CloudVaultCrypto.openPayload(resealed, oldKey, payloadContext)
            }
        assertEquals("Vault key mismatch", oldKeyError.message)

        // STALE pre-rotation claim fails closed: a reader holding the OLD ciphertext and presenting
        // the NEW key cannot open it — the vaultKeyID guard rejects it, not silent.
        val staleError =
            assertThrows(IllegalArgumentException::class.java) {
                CloudVaultCrypto.openPayload(staleEnvelope, newKey, payloadContext)
            }
        assertEquals("Vault key mismatch", staleError.message)
    }

    @Test
    fun signalIdentityHandoffProducesADistinctNewIdentityForTheSameDevice() {
        // The handoff publishes a NEW Signal identity key (keyVersion N+1) for the same device. The
        // rotation EVENT shape/bounds (fromKeyVersion < toKeyVersion, rewrapJobId-when-required) are
        // enforced by buildRotationEventDoc, covered in the TS signalPrekeyDirectory suite. Here we
        // pin the identity transition itself: the canonical id + a materially-different keypair.
        val oldIdentity = AndroidSignalIdentityKeypair.generate("mac-1", 1)
        val newIdentity = AndroidSignalIdentityKeypair.generate("mac-1", 2)

        assertEquals("mac-1_1", oldIdentity.identityKeyId)
        assertEquals("mac-1_2", newIdentity.identityKeyId)
        assertTrue(oldIdentity.keyVersion < newIdentity.keyVersion)
        assertFalse(oldIdentity.publicKeyData.contentEquals(newIdentity.publicKeyData))
    }
}
