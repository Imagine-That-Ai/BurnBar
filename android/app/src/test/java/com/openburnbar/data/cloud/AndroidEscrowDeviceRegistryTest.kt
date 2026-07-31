package com.openburnbar.data.cloud

import com.google.android.gms.tasks.Tasks
import com.google.firebase.firestore.CollectionReference
import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidEscrowDeviceRegistryTest {
    @Test
    fun registerSelfSkipsRegistrationCallableWhenDeviceAlreadyTrusted() {
        val securityClient = mockk<ComputerUseSecurityCallableClient>()

        val registration = runRegisterSelf(
            existingTrustState = AndroidEscrowDeviceRegistry.TRUSTED,
            securityClient = securityClient,
        )

        assertEquals(AndroidEscrowDeviceRegistry.TRUSTED, registration.trustState)
        coVerify(exactly = 0) {
            securityClient.registerEscrowDevice(any(), any(), any(), any(), any(), any())
        }
    }

    @Test
    fun registerSelfInvokesRegistrationCallableWhenDeviceIsNotTrusted() {
        val securityClient = mockk<ComputerUseSecurityCallableClient>()
        coEvery {
            securityClient.registerEscrowDevice(any(), any(), any(), any(), any(), any())
        } just Runs

        val registration = runRegisterSelf(existingTrustState = null, securityClient = securityClient)

        assertEquals(AndroidEscrowDeviceRegistry.PENDING, registration.trustState)
        coVerify(exactly = 1) {
            securityClient.registerEscrowDevice(
                deviceId = eq(TEST_DEVICE_ID),
                deviceName = any(),
                platform = eq("Android"),
                appVersion = isNull(),
                publicKeyFingerprint = eq(testPublicKey.fingerprint),
                keyVersion = eq(TEST_KEY_VERSION),
            )
        }
    }

    @Test
    fun registerSelfInvokesRegistrationCallableWhenDeviceIsPending() {
        val securityClient = mockk<ComputerUseSecurityCallableClient>()
        coEvery {
            securityClient.registerEscrowDevice(any(), any(), any(), any(), any(), any())
        } just Runs

        val registration = runRegisterSelf(
            existingTrustState = AndroidEscrowDeviceRegistry.PENDING,
            securityClient = securityClient,
        )

        assertEquals(AndroidEscrowDeviceRegistry.PENDING, registration.trustState)
        coVerify(exactly = 1) {
            securityClient.registerEscrowDevice(any(), any(), any(), any(), any(), any())
        }
    }

    private fun runRegisterSelf(existingTrustState: String?, securityClient: ComputerUseSecurityCallableClient): AndroidEscrowDeviceRegistration {
        val keypair = mockk<AndroidCloudVaultDeviceKeypair> {
            every { deviceId } returns TEST_DEVICE_ID
            every { publicKeyFingerprint } returns testPublicKey.fingerprint
            every { keyVersion } returns TEST_KEY_VERSION
            every { publicKeyData } returns testPublicKeyBytes
        }
        val firestore = makeFirestore(existingTrustState = existingTrustState)
        mockkObject(AndroidSignalIdentityKeyStore)
        return try {
            every {
                AndroidSignalIdentityKeyStore.loadOrCreate(any(), any())
            } throws IllegalStateException("Signal identity store is unavailable in JVM tests.")
            runBlocking {
                AndroidEscrowDeviceRegistry(firestore = firestore, securityClient = securityClient)
                    .registerSelf(uid = TEST_UID, keypair = keypair)
            }
        } finally {
            unmockkObject(AndroidSignalIdentityKeyStore)
        }
    }

    private fun makeFirestore(existingTrustState: String?): FirebaseFirestore {
        val deviceSnapshot = mockk<DocumentSnapshot> {
            every { getString("trustState") } returns existingTrustState
        }
        val deviceRef = mockk<DocumentReference> {
            every { get() } returns Tasks.forResult(deviceSnapshot)
        }
        val publicKeySnapshot = mockk<DocumentSnapshot> {
            every { exists() } returns true
            every { data } returns mapOf(
                "deviceId" to TEST_DEVICE_ID,
                "publicKeyData" to testPublicKey.dataBase64,
                "publicKeyFingerprint" to testPublicKey.fingerprint,
                "keyVersion" to TEST_KEY_VERSION.toLong(),
                "algorithm" to AndroidEscrowDeviceRegistry.ESCROW_PUBLIC_KEY_ALGORITHM,
            )
        }
        val publicKeyRef = mockk<DocumentReference> {
            every { get() } returns Tasks.forResult(publicKeySnapshot)
        }
        val escrowDevicesCollection = mockk<CollectionReference> {
            every { document(TEST_DEVICE_ID) } returns deviceRef
        }
        val publicKeysCollection = mockk<CollectionReference> {
            every { document("${TEST_DEVICE_ID}_$TEST_KEY_VERSION") } returns publicKeyRef
        }
        val userRef = mockk<DocumentReference> {
            every { collection("escrow_devices") } returns escrowDevicesCollection
            every { collection("escrow_public_keys") } returns publicKeysCollection
        }
        val usersCollection = mockk<CollectionReference> {
            every { document(TEST_UID) } returns userRef
        }
        return mockk<FirebaseFirestore> {
            every { collection("users") } returns usersCollection
        }
    }

    @Test
    fun publicKeyDocumentMatcherAcceptsExactDocument() {
        val publicKey = publicKeyMaterial(seed = 1)

        val data =
            mapOf(
                "deviceId" to "android-device",
                "publicKeyData" to publicKey.dataBase64,
                "publicKeyFingerprint" to publicKey.fingerprint,
                "keyVersion" to 1L,
                "algorithm" to AndroidEscrowDeviceRegistry.ESCROW_PUBLIC_KEY_ALGORITHM,
            )

        assertTrue(
            AndroidEscrowDeviceRegistry.publicKeyDocumentMatches(
                data = data,
                deviceId = "android-device",
                publicKeyDataBase64 = publicKey.dataBase64,
                publicKeyFingerprint = publicKey.fingerprint,
                keyVersion = 1,
            ),
        )
    }

    @Test
    fun publicKeyDocumentMatcherAcceptsLegacyDocumentWithoutFingerprint() {
        val publicKey = publicKeyMaterial(seed = 1)

        val data =
            mapOf(
                "deviceId" to "android-device",
                "publicKeyData" to publicKey.dataBase64,
                "keyVersion" to 1,
                "algorithm" to AndroidEscrowDeviceRegistry.ESCROW_PUBLIC_KEY_ALGORITHM,
            )

        assertTrue(
            AndroidEscrowDeviceRegistry.publicKeyDocumentMatches(
                data = data,
                deviceId = "android-device",
                publicKeyDataBase64 = publicKey.dataBase64,
                publicKeyFingerprint = publicKey.fingerprint,
                keyVersion = 1,
            ),
        )
    }

    @Test
    fun publicKeyDocumentMatcherRejectsImmutableKeyDrift() {
        val expectedPublicKey = publicKeyMaterial(seed = 1)
        val storedPublicKey = publicKeyMaterial(seed = 2)

        val data =
            mapOf(
                "deviceId" to "android-device",
                "publicKeyData" to storedPublicKey.dataBase64,
                "publicKeyFingerprint" to storedPublicKey.fingerprint,
                "keyVersion" to 1,
                "algorithm" to AndroidEscrowDeviceRegistry.ESCROW_PUBLIC_KEY_ALGORITHM,
            )

        assertFalse(
            AndroidEscrowDeviceRegistry.publicKeyDocumentMatches(
                data = data,
                deviceId = "android-device",
                publicKeyDataBase64 = expectedPublicKey.dataBase64,
                publicKeyFingerprint = expectedPublicKey.fingerprint,
                keyVersion = 1,
            ),
        )
    }

    @Test
    fun publicKeyDocumentMatcherRejectsStoredFingerprintNotDerivedFromPublicKeyData() {
        val publicKey = publicKeyMaterial(seed = 1)
        val otherPublicKey = publicKeyMaterial(seed = 2)

        val data =
            mapOf(
                "deviceId" to "android-device",
                "publicKeyData" to publicKey.dataBase64,
                "publicKeyFingerprint" to otherPublicKey.fingerprint,
                "keyVersion" to 1,
                "algorithm" to AndroidEscrowDeviceRegistry.ESCROW_PUBLIC_KEY_ALGORITHM,
            )

        assertFalse(
            AndroidEscrowDeviceRegistry.publicKeyDocumentMatches(
                data = data,
                deviceId = "android-device",
                publicKeyDataBase64 = publicKey.dataBase64,
                publicKeyFingerprint = publicKey.fingerprint,
                keyVersion = 1,
            ),
        )
    }

    @Test
    fun publicKeyDocumentMatcherRejectsCallerFingerprintNotDerivedFromPublicKeyData() {
        val publicKey = publicKeyMaterial(seed = 1)
        val otherPublicKey = publicKeyMaterial(seed = 2)

        val data =
            mapOf(
                "deviceId" to "android-device",
                "publicKeyData" to publicKey.dataBase64,
                "publicKeyFingerprint" to publicKey.fingerprint,
                "keyVersion" to 1,
                "algorithm" to AndroidEscrowDeviceRegistry.ESCROW_PUBLIC_KEY_ALGORITHM,
            )

        assertFalse(
            AndroidEscrowDeviceRegistry.publicKeyDocumentMatches(
                data = data,
                deviceId = "android-device",
                publicKeyDataBase64 = publicKey.dataBase64,
                publicKeyFingerprint = otherPublicKey.fingerprint,
                keyVersion = 1,
            ),
        )
    }

    @Test
    fun publicKeyDocumentMatcherRejectsMalformedPublicKeyData() {
        val publicKey = publicKeyMaterial(seed = 1)

        val data =
            mapOf(
                "deviceId" to "android-device",
                "publicKeyData" to "not-base64",
                "publicKeyFingerprint" to publicKey.fingerprint,
                "keyVersion" to 1,
                "algorithm" to AndroidEscrowDeviceRegistry.ESCROW_PUBLIC_KEY_ALGORITHM,
            )

        assertFalse(
            AndroidEscrowDeviceRegistry.publicKeyDocumentMatches(
                data = data,
                deviceId = "android-device",
                publicKeyDataBase64 = "not-base64",
                publicKeyFingerprint = publicKey.fingerprint,
                keyVersion = 1,
            ),
        )
    }

    private data class PublicKeyMaterial(
        val dataBase64: String,
        val fingerprint: String,
    )

    private fun publicKeyMaterial(seed: Int): PublicKeyMaterial {
        val bytes = publicKeyBytes(seed = seed)
        return PublicKeyMaterial(
            dataBase64 = CloudVaultCryptoSupport.encodeBase64(bytes),
            fingerprint = CloudVaultCrypto.sha256Base64(bytes),
        )
    }

    private val testPublicKeyBytes = publicKeyBytes(seed = 1)
    private val testPublicKey = publicKeyMaterial(seed = 1)

    private fun publicKeyBytes(seed: Int): ByteArray {
        val bytes = ByteArray(65) { index -> ((seed + index) and 0xFF).toByte() }
        bytes[0] = 0x04
        return bytes
    }

    private companion object {
        const val TEST_UID = "test-uid"
        const val TEST_DEVICE_ID = "android-test-device"
        const val TEST_KEY_VERSION = 1
    }
}
