package com.openburnbar.data.cloud

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidEscrowDeviceRegistryTest {
    @Test
    fun publicKeyDocumentMatcherAcceptsExactDocument() {
        val publicKeyData = "A".repeat(88)
        val fingerprint = "F".repeat(44)

        val data =
            mapOf(
                "deviceId" to "android-device",
                "publicKeyData" to publicKeyData,
                "publicKeyFingerprint" to fingerprint,
                "keyVersion" to 1L,
                "algorithm" to AndroidEscrowDeviceRegistry.ESCROW_PUBLIC_KEY_ALGORITHM,
            )

        assertTrue(
            AndroidEscrowDeviceRegistry.publicKeyDocumentMatches(
                data = data,
                deviceId = "android-device",
                publicKeyDataBase64 = publicKeyData,
                publicKeyFingerprint = fingerprint,
                keyVersion = 1,
            ),
        )
    }

    @Test
    fun publicKeyDocumentMatcherAcceptsLegacyDocumentWithoutFingerprint() {
        val publicKeyData = "A".repeat(88)

        val data =
            mapOf(
                "deviceId" to "android-device",
                "publicKeyData" to publicKeyData,
                "keyVersion" to 1,
                "algorithm" to AndroidEscrowDeviceRegistry.ESCROW_PUBLIC_KEY_ALGORITHM,
            )

        assertTrue(
            AndroidEscrowDeviceRegistry.publicKeyDocumentMatches(
                data = data,
                deviceId = "android-device",
                publicKeyDataBase64 = publicKeyData,
                publicKeyFingerprint = "F".repeat(44),
                keyVersion = 1,
            ),
        )
    }

    @Test
    fun publicKeyDocumentMatcherRejectsImmutableKeyDrift() {
        val data =
            mapOf(
                "deviceId" to "android-device",
                "publicKeyData" to "B".repeat(88),
                "publicKeyFingerprint" to "F".repeat(44),
                "keyVersion" to 1,
                "algorithm" to AndroidEscrowDeviceRegistry.ESCROW_PUBLIC_KEY_ALGORITHM,
            )

        assertFalse(
            AndroidEscrowDeviceRegistry.publicKeyDocumentMatches(
                data = data,
                deviceId = "android-device",
                publicKeyDataBase64 = "A".repeat(88),
                publicKeyFingerprint = "F".repeat(44),
                keyVersion = 1,
            ),
        )
    }
}
