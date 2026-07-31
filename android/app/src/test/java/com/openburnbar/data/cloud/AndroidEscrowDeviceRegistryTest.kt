package com.openburnbar.data.cloud

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidEscrowDeviceRegistryTest {
    @Test
    fun trustedDeviceMatcherAcceptsSameAndroidKey() {
        assertTrue(
            AndroidEscrowDeviceRegistry.trustedDeviceDocumentMatches(
                data = mapOf(
                    "trustState" to AndroidEscrowDeviceRegistry.TRUSTED,
                    "platform" to "Android",
                    "publicKeyFingerprint" to "fingerprint",
                    "keyVersion" to 1L,
                ),
                publicKeyFingerprint = "fingerprint",
                keyVersion = 1,
            ),
        )
    }

    @Test
    fun trustedDeviceMatcherRejectsKeyOrTrustDrift() {
        val baseline =
            mapOf(
                "trustState" to AndroidEscrowDeviceRegistry.TRUSTED,
                "platform" to "Android",
                "publicKeyFingerprint" to "fingerprint",
                "keyVersion" to 1,
            )

        assertFalse(
            AndroidEscrowDeviceRegistry.trustedDeviceDocumentMatches(
                data = baseline + ("publicKeyFingerprint" to "different"),
                publicKeyFingerprint = "fingerprint",
                keyVersion = 1,
            ),
        )
        assertFalse(
            AndroidEscrowDeviceRegistry.trustedDeviceDocumentMatches(
                data = baseline + ("keyVersion" to 2),
                publicKeyFingerprint = "fingerprint",
                keyVersion = 1,
            ),
        )
        assertFalse(
            AndroidEscrowDeviceRegistry.trustedDeviceDocumentMatches(
                data = baseline + ("platform" to "iOS"),
                publicKeyFingerprint = "fingerprint",
                keyVersion = 1,
            ),
        )
        assertFalse(
            AndroidEscrowDeviceRegistry.trustedDeviceDocumentMatches(
                data = baseline + ("trustState" to AndroidEscrowDeviceRegistry.PENDING),
                publicKeyFingerprint = "fingerprint",
                keyVersion = 1,
            ),
        )
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
        val bytes = ByteArray(65) { index -> ((seed + index) and 0xFF).toByte() }
        bytes[0] = 0x04
        return PublicKeyMaterial(
            dataBase64 = CloudVaultCryptoSupport.encodeBase64(bytes),
            fingerprint = CloudVaultCrypto.sha256Base64(bytes),
        )
    }
}
