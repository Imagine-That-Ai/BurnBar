package com.openburnbar.data.cloud

import com.google.android.gms.tasks.Tasks
import com.google.firebase.firestore.CollectionReference
import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidSignalIdentityKeyStoreTest {
    // The exact keys().hasOnly([...]) set from firestore.rules:3511-3543 (minus the
    // server-managed createdAt/updatedAt, which publishIfNeeded adds at write time).
    private val rulesIdentityKeys =
        setOf(
            "deviceId", "platform", "identityKeyId", "publicKeyFingerprint", "publicKeyData",
            "keyVersion", "keyVersionLabel", "algorithm", "createdAt", "updatedAt",
        )

    @Test
    fun publishedIdentityDocMatchesL41RulesShape() {
        val identity = AndroidSignalIdentityKeypair.generate("android-testdevice", 1)
        val doc = AndroidSignalIdentityKeyStore.signalIdentityPublicKeyDoc("android-testdevice", identity, "Android")

        // Every emitted key must be within the rules hasOnly set (no drift).
        for (key in doc.keys) {
            assertTrue("unexpected key '$key' not in L41 identity rules hasOnly set", rulesIdentityKeys.contains(key))
        }
        assertEquals("android-testdevice", doc["deviceId"])
        assertEquals("Android", doc["platform"])
        assertEquals("android-testdevice_1", doc["identityKeyId"])
        assertEquals(1, doc["keyVersion"])
        assertEquals("1", doc["keyVersionLabel"])
        assertEquals(CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION, doc["algorithm"])

        // publicKeyData must satisfy the rules regex ^[A-Za-z0-9+/=]{40,96}$.
        val publicKeyData = doc["publicKeyData"]
        check(publicKeyData is String)
        assertTrue("publicKeyData must be canonical base64 length 40-96", Regex("^[A-Za-z0-9+/=]{40,96}$").matches(publicKeyData))

        // publicKeyFingerprint must be <= 128 chars (rules bound).
        val publicKeyFingerprint = doc["publicKeyFingerprint"]
        check(publicKeyFingerprint is String)
        assertTrue(publicKeyFingerprint.length <= 128)
    }

    @Test
    fun identityKeyIdBindsDeviceAndVersion() {
        assertEquals("android-abc_2", AndroidSignalIdentityKeypair.identityKeyId("android-abc", 2))
    }

    @Test
    fun publishIfNeededRefusesAStoredKeyThatDiffersFromTheLocalKey() {
        val identity = AndroidSignalIdentityKeypair.generate("android-testdevice", 1)
        val stored = mockk<DocumentSnapshot> {
            every { exists() } returns true
            every { getString("publicKeyData") } returns "c3RhbGUta2V5"
        }
        val identityRef = mockk<DocumentReference> { every { get() } returns Tasks.forResult(stored) }
        val identities = mockk<CollectionReference> { every { document(identity.identityKeyId) } returns identityRef }
        val userRef = mockk<DocumentReference> { every { collection("signal_identity_public_keys") } returns identities }
        val users = mockk<CollectionReference> { every { document("uid-1") } returns userRef }
        val firestore = mockk<FirebaseFirestore> { every { collection("users") } returns users }

        val error = assertThrows(IllegalStateException::class.java) {
            runBlocking {
                AndroidSignalIdentityKeyStore.publishIfNeeded(
                    uid = "uid-1",
                    deviceId = "android-testdevice",
                    identity = identity,
                    firestore = firestore,
                )
            }
        }

        assertEquals(
            "Device identity public key conflict for android-testdevice_1: stored key differs from the local key.",
            error.message,
        )
    }
}
