package com.openburnbar.data.cloud

import com.google.android.gms.tasks.Tasks
import com.google.firebase.firestore.CollectionReference
import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import com.google.firebase.firestore.Transaction
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.slot
import io.mockk.unmockkObject
import io.mockk.verify
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test

/**
 * Unit coverage for [AndroidEscrowDeviceRegistry] public-key publication: an
 * already-registered device short-circuits on the cache-servable read, while a
 * missing document goes through a Firestore transaction so a concurrent
 * identical create is validated instead of replayed as a rules-rejected
 * immutable-key update.
 */
class AndroidEscrowDeviceRegistryPublishTest {
    private companion object {
        const val UID = "uid-1"
        const val DEVICE_ID = "android-test-device"
        const val KEY_VERSION = 1
    }

    private val transaction = mockk<Transaction>()
    private val publicKeyRef = mockk<DocumentReference>()
    private val deviceRef = mockk<DocumentReference>()
    private val firestore = buildFirestore()
    private val securityClient = mockk<ComputerUseSecurityCallableClient>(relaxed = true)
    private val registry = AndroidEscrowDeviceRegistry(firestore = firestore, securityClient = securityClient)

    @Before
    fun stubSignalIdentityKeyStore() {
        // Signal identity publication is best-effort inside registerSelf and is
        // backed by the Android Keystore, which does not exist under local JVM
        // JaCoCo. The registry wraps it in runCatching, so a deterministic throw
        // keeps these tests focused on escrow public-key publication.
        mockkObject(AndroidSignalIdentityKeyStore)
        every { AndroidSignalIdentityKeyStore.loadOrCreate(any(), any()) } throws IllegalStateException("Android Keystore is unavailable in JVM tests.")
    }

    @After
    fun restoreSignalIdentityKeyStore() {
        unmockkObject(AndroidSignalIdentityKeyStore)
    }

    private fun buildFirestore(): FirebaseFirestore {
        val escrowDevices = mockk<CollectionReference> {
            every { document(DEVICE_ID) } returns deviceRef
        }
        val escrowPublicKeys = mockk<CollectionReference> {
            every { document("${DEVICE_ID}_$KEY_VERSION") } returns publicKeyRef
        }
        val userDocument = mockk<DocumentReference> {
            every { collection("escrow_devices") } returns escrowDevices
            every { collection("escrow_public_keys") } returns escrowPublicKeys
        }
        val usersCollection = mockk<CollectionReference> {
            every { document(UID) } returns userDocument
        }
        return mockk {
            every { collection("users") } returns usersCollection
            every { runTransaction(any<Transaction.Function<Unit>>()) } answers {
                Tasks.forResult(firstArg<Transaction.Function<Unit>>().apply(transaction))
            }
        }
    }

    private data class PublicKeyMaterial(
        val dataBase64: String,
        val fingerprint: String,
    )

    private fun publicKeyMaterial(seed: Int): PublicKeyMaterial {
        val bytes = publicKeyBytes(seed)
        return PublicKeyMaterial(
            dataBase64 = CloudVaultCryptoSupport.encodeBase64(bytes),
            fingerprint = CloudVaultCrypto.sha256Base64(bytes),
        )
    }

    private fun publicKeyBytes(seed: Int): ByteArray {
        val bytes = ByteArray(65) { index -> ((seed + index) and 0xFF).toByte() }
        bytes[0] = 0x04
        return bytes
    }

    private fun keypair(seed: Int = 1): AndroidCloudVaultDeviceKeypair {
        val bytes = publicKeyBytes(seed)
        return mockk {
            every { publicKeyData } returns bytes
            every { publicKeyFingerprint } returns CloudVaultCrypto.sha256Base64(bytes)
            every { deviceId } returns DEVICE_ID
            every { keyVersion } returns KEY_VERSION
        }
    }

    private fun publicKeyDocument(material: PublicKeyMaterial): Map<String, Any> = mapOf(
        "deviceId" to DEVICE_ID,
        "publicKeyData" to material.dataBase64,
        "publicKeyFingerprint" to material.fingerprint,
        "keyVersion" to KEY_VERSION.toLong(),
        "algorithm" to AndroidEscrowDeviceRegistry.ESCROW_PUBLIC_KEY_ALGORITHM,
    )

    private fun snapshotWith(documentData: Map<String, Any>?): DocumentSnapshot = mockk {
        every { exists() } returns (documentData != null)
        every { data } returns documentData
    }

    private fun stubExistingDeviceDoc() {
        every { deviceRef.get() } returns Tasks.forResult(
            mockk<DocumentSnapshot> {
                every { getString("trustState") } returns null
            },
        )
    }

    @Test
    fun registerSelfShortCircuitsOnCacheServableMatchingPublicKey() {
        stubExistingDeviceDoc()
        val material = publicKeyMaterial(seed = 1)
        every { publicKeyRef.get() } returns Tasks.forResult(snapshotWith(publicKeyDocument(material)))

        val registration = runBlocking { registry.registerSelf(uid = UID, keypair = keypair(seed = 1)) }

        assertEquals(DEVICE_ID, registration.deviceId)
        assertEquals(AndroidEscrowDeviceRegistry.PENDING, registration.trustState)
        verify(exactly = 0) { firestore.runTransaction(any<Transaction.Function<Unit>>()) }
    }

    @Test
    fun registerSelfRejectsCacheServableConflictingPublicKey() {
        stubExistingDeviceDoc()
        val storedMaterial = publicKeyMaterial(seed = 2)
        every { publicKeyRef.get() } returns Tasks.forResult(snapshotWith(publicKeyDocument(storedMaterial)))

        assertThrows(IllegalArgumentException::class.java) {
            runBlocking { registry.registerSelf(uid = UID, keypair = keypair(seed = 1)) }
        }
    }

    @Test
    fun registerSelfCreatesPublicKeyTransactionallyWhenReadFailsAndDocumentIsMissing() {
        stubExistingDeviceDoc()
        val material = publicKeyMaterial(seed = 1)
        every { publicKeyRef.get() } returns Tasks.forException(RuntimeException("offline cache miss"))
        every { transaction.get(publicKeyRef) } returns snapshotWith(null)
        val payload = slot<Any>()
        every { transaction.set(publicKeyRef, capture(payload), any<SetOptions>()) } returns transaction

        runBlocking { registry.registerSelf(uid = UID, keypair = keypair(seed = 1)) }

        verify(exactly = 1) { transaction.set(publicKeyRef, any(), any<SetOptions>()) }
        val written = payload.captured as Map<*, *>
        assertEquals(DEVICE_ID, written["deviceId"])
        assertEquals(material.dataBase64, written["publicKeyData"])
        assertEquals(material.fingerprint, written["publicKeyFingerprint"])
        assertEquals(KEY_VERSION, written["keyVersion"])
        assertEquals(AndroidEscrowDeviceRegistry.ESCROW_PUBLIC_KEY_ALGORITHM, written["algorithm"])
        assertNotNull(written["createdAt"])
    }

    @Test
    fun registerSelfValidatesConcurrentIdenticalCreateInsideTransaction() {
        stubExistingDeviceDoc()
        val material = publicKeyMaterial(seed = 1)
        every { publicKeyRef.get() } returns Tasks.forResult(snapshotWith(null))
        every { transaction.get(publicKeyRef) } returns snapshotWith(publicKeyDocument(material))

        runBlocking { registry.registerSelf(uid = UID, keypair = keypair(seed = 1)) }

        verify(exactly = 0) { transaction.set(publicKeyRef, any(), any<SetOptions>()) }
    }

    @Test
    fun registerSelfRejectsConcurrentConflictingCreateInsideTransaction() {
        stubExistingDeviceDoc()
        val storedMaterial = publicKeyMaterial(seed = 2)
        every { publicKeyRef.get() } returns Tasks.forResult(snapshotWith(null))
        every { transaction.get(publicKeyRef) } returns snapshotWith(publicKeyDocument(storedMaterial))

        assertThrows(IllegalArgumentException::class.java) {
            runBlocking { registry.registerSelf(uid = UID, keypair = keypair(seed = 1)) }
        }
    }
}
