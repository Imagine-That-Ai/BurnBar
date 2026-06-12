package com.openburnbar.data.cloud

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

/**
 * ON-DEVICE proof (item 3) for the Android Signal producer + persistent identity store:
 * exercises real libsignal (Curve25519/HPKE) on ARM and the real Android Keystore +
 * SharedPreferences, complementing the JVM unit tests. Forces the domain gate ON via the
 * test-only override so production stays fail-closed/inert.
 */
@RunWith(AndroidJUnit4::class)
class AndroidSignalProducerInstrumentedTest {
    @Test
    fun signalEnvelopeRoundTripsForLocalAndPeerOnDevice() {
        AndroidCloudVaultSignalPayloads.signalSealingOverrideProvider = { true }
        try {
            val local = AndroidSignalIdentityKeypair.generate("android-on-device-a", 1)
            val peer = AndroidSignalIdentityKeypair.generate("android-on-device-b", 1)
            val plaintext = "on-device signal at-rest payload".toByteArray()

            val map = AndroidCloudVaultSignalPayloads.signalEnvelopeMapIfEnabled(
                AndroidCloudVaultSignalPayloads.SignalEnvelopeMapRequest(
                    domainID = "conversations_chat",
                    uid = "user-on-device",
                    collection = "mobile_assistant_chats",
                    docId = "thread-on-device",
                    plaintext = plaintext,
                    localIdentity = local,
                    otherRecipients = listOf(peer.asRecipient()),
                ),
            )
            assertNotNull(map)
            val data = mapOf<String, Any?>("signalEnvelope" to map!!)

            assertArrayEquals(
                plaintext,
                AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data,
                    uid = "user-on-device",
                    collection = "mobile_assistant_chats",
                    docId = "thread-on-device",
                    localIdentity = local,
                ),
            )
            assertArrayEquals(
                plaintext,
                AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data,
                    uid = "user-on-device",
                    collection = "mobile_assistant_chats",
                    docId = "thread-on-device",
                    localIdentity = peer,
                ),
            )
            // Relocation guard holds on device too.
            assertThrows(IllegalArgumentException::class.java) {
                AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data,
                    uid = "user-on-device",
                    collection = "mobile_assistant_chats",
                    docId = "thread-relocated",
                    localIdentity = local,
                )
            }
        } finally {
            AndroidCloudVaultSignalPayloads.signalSealingOverrideProvider = null
        }
    }

    @Test
    fun identityKeyStorePersistsViaAndroidKeystore() {
        // Unique deviceId per run avoids cross-run contamination of the on-device Keychain/prefs.
        val deviceId = "android-keystore-${UUID.randomUUID()}"
        val created = AndroidSignalIdentityKeyStore.loadOrCreate(deviceId, 1)
        val reloaded = AndroidSignalIdentityKeyStore.load(deviceId, 1)
        assertNotNull(reloaded)
        assertEquals(created.identityKeyId, reloaded!!.identityKeyId)
        assertArrayEquals(created.publicKeyData, reloaded.publicKeyData)
        assertArrayEquals(created.privateKeyData, reloaded.privateKeyData)
        // loadOrCreate is stable (returns the same persisted key, does not regenerate).
        val again = AndroidSignalIdentityKeyStore.loadOrCreate(deviceId, 1)
        assertArrayEquals(created.publicKeyData, again.publicKeyData)
    }
}
