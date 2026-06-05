package com.openburnbar.data.cloud

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SignedPreKeyRecord

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

    @Test
    fun signalIdentityDocumentMatcherAcceptsOnlyExactPublicIdentity() {
        val keyPair = org.signal.libsignal.protocol.ecc.ECKeyPair.generate()
        val identity =
            AndroidSignalIdentityKeypair(
                identityKeyId = "android-device_1",
                publicKeyData = keyPair.publicKey.serialize(),
                privateKeyData = keyPair.privateKey.serialize(),
                keyVersion = 1,
            )
        val data =
            mapOf(
                "deviceId" to "android-device",
                "platform" to "Android",
                "identityKeyId" to identity.identityKeyId,
                "publicKeyData" to identity.publicKeyBase64,
                "publicKeyFingerprint" to identity.publicKeyFingerprint,
                "keyVersion" to 1L,
                "algorithm" to CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION,
            )

        assertTrue(
            AndroidEscrowDeviceRegistry.signalIdentityDocumentMatches(
                data = data,
                deviceId = "android-device",
                platform = "Android",
                identity = identity,
            ),
        )
        assertFalse(
            AndroidEscrowDeviceRegistry.signalIdentityDocumentMatches(
                data = data + ("publicKeyData" to "wrong"),
                deviceId = "android-device",
                platform = "Android",
                identity = identity,
            ),
        )
    }

    @Test
    fun signalPrekeyPublicationUsesRealLibsignalMaterialAndPublishesPublicOnlyDocs() {
        val keyPair = org.signal.libsignal.protocol.ecc.ECKeyPair.generate()
        val identity =
            AndroidSignalIdentityKeypair(
                identityKeyId = "android-device_1",
                publicKeyData = keyPair.publicKey.serialize(),
                privateKeyData = keyPair.privateKey.serialize(),
                keyVersion = 1,
            )
        val publication =
            AndroidSignalPrekeyDirectory.generatePublication(
                identity = identity,
                deviceId = "android-device",
                nowMillis = 1_777_777_000_000L,
                ids =
                    AndroidSignalPrekeyDirectory.AndroidSignalPrekeyIds(
                        signedPreKeyId = 11,
                        oneTimePreKeyIds = listOf(101, 102),
                        kyberPreKeyIds = listOf(201, 202),
                    ),
                recordEncoder = CloudVaultCryptoSupport::encodeBase64,
            )

        assertEquals("spk-11", publication.signedPreKey.signedPreKeyId)
        assertEquals(listOf("opk-101", "opk-102"), publication.oneTimePreKeys.map { it.oneTimePreKeyId })
        assertEquals(listOf("kpk-201", "kpk-202"), publication.kyberPreKeys.map { it.kyberPreKeyId })

        val signedRecord =
            SignedPreKeyRecord(CloudVaultCryptoSupport.decodeBase64(publication.localRecords.signedPreKeyRecordB64))
        val signedPublic = signedRecord.getKeyPair().publicKey.serialize()
        assertEquals(11, signedRecord.id)
        assertEquals(CloudVaultCryptoSupport.encodeBase64(signedPublic), publication.signedPreKey.publicKeyB64)
        assertTrue(keyPair.publicKey.verifySignature(signedPublic, signedRecord.signature))

        val oneTimeRecord =
            PreKeyRecord(CloudVaultCryptoSupport.decodeBase64(publication.localRecords.oneTimePreKeyRecordB64.first()))
        assertEquals(101, oneTimeRecord.id)
        assertEquals(
            CloudVaultCryptoSupport.encodeBase64(oneTimeRecord.getKeyPair().publicKey.serialize()),
            publication.oneTimePreKeys.first().publicKeyB64,
        )

        val kyberRecord =
            KyberPreKeyRecord(CloudVaultCryptoSupport.decodeBase64(publication.localRecords.kyberPreKeyRecordB64.first()))
        val kyberPublic = kyberRecord.keyPair.publicKey.serialize()
        assertEquals(201, kyberRecord.id)
        assertEquals(CloudVaultCryptoSupport.encodeBase64(kyberPublic), publication.kyberPreKeys.first().publicKeyB64)
        assertTrue(keyPair.publicKey.verifySignature(kyberPublic, kyberRecord.signature))

        val signedDoc = publication.signedPreKey.firestoreData()
        val oneTimeDoc = publication.oneTimePreKeys.first().firestoreData()
        val kyberDoc = publication.kyberPreKeys.first().firestoreData()
        listOf(signedDoc, oneTimeDoc, kyberDoc).forEach { doc ->
            assertFalse(doc.keys.any { it.contains("private", ignoreCase = true) || it.contains("record", ignoreCase = true) })
        }
        assertTrue(AndroidSignalPrekeyDirectory.signedPreKeyDocumentMatches(signedDoc, signedDoc))
        assertTrue(AndroidSignalPrekeyDirectory.oneTimePreKeyDocumentMatches(oneTimeDoc, oneTimeDoc))
        assertTrue(AndroidSignalPrekeyDirectory.kyberPreKeyDocumentMatches(kyberDoc, kyberDoc))
        assertFalse(AndroidSignalPrekeyDirectory.signedPreKeyDocumentMatches(signedDoc + ("publicKeyB64" to "wrong"), signedDoc))
        assertFalse(AndroidSignalPrekeyDirectory.kyberPreKeyDocumentMatches(kyberDoc + ("signatureB64" to "wrong"), kyberDoc))
    }

    @Test
    fun signalPrekeyLifecycleDocumentsMatchRulesContractAndStayPublicOnly() {
        val claim =
            AndroidSignalClaimedPrekeyUpdate(
                sessionId = "session-1",
                claimedAtMillis = 1_777_777_000_000L,
            ).firestoreUpdate()

        assertEquals("claimed", claim["status"])
        assertEquals("session-1", claim["claimedBySessionId"])
        assertFalse(claim.keys.any { it.contains("private", ignoreCase = true) || it.contains("record", ignoreCase = true) })

        val session =
            AndroidSignalSessionDirectoryDocument(
                sessionId = "session-1",
                identityKeyId = "android-device_1",
                deviceId = "android-device",
                keyVersion = 1,
                peerUid = "uid-1",
                peerDeviceId = "mac-device",
                peerIdentityKeyId = "mac-device_2",
                mode = AndroidSignalPrekeyDirectory.SESSION_MODE_SAME_USER_DEVICE,
                createdAtMillis = 1_777_777_000_000L,
                lastMessageAtMillis = 1_777_777_060_000L,
            ).firestoreData()

        assertEquals("session-1", session["sessionId"])
        assertEquals("android-device_1", session["identityKeyId"])
        assertEquals("mac-device_2", session["peerIdentityKeyId"])
        assertEquals("same-user-device", session["mode"])
        assertEquals("device-local-only", session["stateStorage"])
        assertEquals("active", session["status"])
        assertFalse(session.keys.any { it.contains("sessionState", ignoreCase = true) || it.contains("ratchet", ignoreCase = true) })

        val rotation =
            AndroidSignalRotationEventDocument(
                rotationId = "rotation-1",
                identityKeyId = "android-device_1",
                deviceId = "android-device",
                keyVersion = 1,
                fromKeyVersion = 1,
                toKeyVersion = 2,
                reason = "revocation_rewrap",
                rewrapRequired = true,
                rewrapJobId = "rewrap-1",
                revokedIdentityKeyId = "mac-device_1",
                createdAtMillis = 1_777_777_000_000L,
            ).firestoreData()

        assertEquals("rotation-1", rotation["rotationId"])
        assertEquals(1, rotation["fromKeyVersion"])
        assertEquals(2, rotation["toKeyVersion"])
        assertEquals("revocation_rewrap", rotation["reason"])
        assertEquals("planned", rotation["status"])
        assertEquals(true, rotation["rewrapRequired"])
        assertEquals("mac-device_1", rotation["revokedIdentityKeyId"])
    }

    @Test
    fun signalRewrapPlanExcludesRevokedIdentitiesFromFutureWraps() {
        val plan =
            AndroidSignalRewrapPlan(
                rewrapJobId = "rewrap-1",
                candidateRecipientIdentityKeyIds = listOf("device-c_1", "device-a_1", "device-b_1"),
                revokedIdentityKeyIds = listOf("device-b_1"),
            )

        assertEquals(listOf("device-a_1", "device-c_1"), plan.activeRecipientIdentityKeyIds)
        assertEquals(listOf("device-b_1"), plan.revokedIdentityKeyIds)
    }
}
