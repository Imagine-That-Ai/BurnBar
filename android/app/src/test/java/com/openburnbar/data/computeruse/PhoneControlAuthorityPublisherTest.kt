package com.openburnbar.data.computeruse

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class PhoneControlAuthorityPublisherTest {
    private val privateSeed = ByteArray(32) { index -> (index + 1).toByte() }
    private val publicKey = PhoneControlSigner.publicKey(privateSeed)

    @Test
    fun authorityDocumentMatchesFirestoreRulesShape() {
        val doc =
            PhoneControlAuthorityDocumentFactory.document(
                connectionId = "conn-1",
                deviceId = "android-device-1",
                publicKey = publicKey,
                publishedAtMillis = 1_700_000_000_123L,
            )

        assertEquals(doc.peerNodeId, doc.id)
        assertEquals("conn-1", doc.connectionId)
        assertEquals("android-device-1", doc.deviceId)
        assertEquals(1, doc.protocolVersion)
        assertEquals(1, doc.schemaVersion)
        assertEquals(32, Base64.getDecoder().decode(doc.publicKeyBase64).size)

        val map = doc.asMap()
        assertEquals(
            setOf(
                "id",
                "connectionId",
                "peerNodeId",
                "deviceId",
                "publicKeyBase64",
                "publishedAtMillis",
                "protocolVersion",
                "schemaVersion",
            ),
            map.keys,
        )
        assertEquals(doc.peerNodeId, map["id"])
        assertEquals(doc.peerNodeId, map["peerNodeId"])
        assertEquals(doc.connectionId, map["connectionId"])
        assertEquals(doc.deviceId, map["deviceId"])
    }

    @Test
    fun peerNodeIdIsStableAndAndroidScoped() {
        val first = PhoneControlAuthorityDocumentFactory.peerNodeId(publicKey)
        val second = PhoneControlAuthorityDocumentFactory.peerNodeId(publicKey)

        assertEquals(first, second)
        assertEquals("android-phone-", first.take("android-phone-".length))
        assertEquals("android-phone-65b60673d6ed884bf01c2c22", first)
    }

    @Test
    fun peerNodeIdRejectsWrongSizedKeys() {
        assertThrows(IllegalArgumentException::class.java) {
            PhoneControlAuthorityDocumentFactory.peerNodeId(ByteArray(31))
        }
    }

    @Test
    fun legacyIdentityDocumentIsByteIdenticalToPublicKeyDocument() {
        // F2 backward compatibility: with the gate off the identity-based
        // factory must produce the exact pre-F2 document — same map keys, no
        // keyKind — so the publish callable payload stays byte-identical.
        val identity = PhoneControlSigningIdentity.Ed25519(privateSeed)
        val viaPublicKey =
            PhoneControlAuthorityDocumentFactory.document(
                connectionId = "conn-1",
                deviceId = "android-device-1",
                publicKey = publicKey,
                publishedAtMillis = 1_700_000_000_123L,
            )
        val viaIdentity =
            PhoneControlAuthorityDocumentFactory.document(
                connectionId = "conn-1",
                deviceId = "android-device-1",
                identity = identity,
                publishedAtMillis = 1_700_000_000_123L,
            )

        assertEquals(viaPublicKey, viaIdentity)
        assertNull(viaIdentity.keyKind)
        assertEquals(viaPublicKey.asMap(), viaIdentity.asMap())
        assertFalse(viaIdentity.asMap().containsKey("keyKind"))
    }

    @Test
    fun secureEnclaveDocumentPublishesX963KeyAndSePeerNodeId() {
        val identity = softwareP256Identity()
        val doc =
            PhoneControlAuthorityDocumentFactory.document(
                connectionId = "conn-1",
                deviceId = "android-device-1",
                identity = identity,
                publishedAtMillis = 1_700_000_000_123L,
            )

        assertEquals(doc.peerNodeId, doc.id)
        assertEquals("android-se-", doc.peerNodeId.take("android-se-".length))
        assertEquals("android-se-".length + 24, doc.peerNodeId.length)
        assertEquals("se-p256", doc.keyKind)
        val published = Base64.getDecoder().decode(doc.publicKeyBase64)
        assertEquals(65, published.size)
        assertEquals(0x04.toByte(), published.first())
        assertEquals("se-p256", doc.asMap()["keyKind"])
    }

    private fun softwareP256Identity(): PhoneControlSigningIdentity.SecureEnclaveP256 {
        val generator = java.security.KeyPairGenerator.getInstance("EC")
        generator.initialize(java.security.spec.ECGenParameterSpec("secp256r1"))
        val pair = generator.generateKeyPair()
        return PhoneControlSigningIdentity.SecureEnclaveP256(
            pair.private,
            pair.public as? java.security.interfaces.ECPublicKey ?: error("expected EC public key"),
        )
    }
}
