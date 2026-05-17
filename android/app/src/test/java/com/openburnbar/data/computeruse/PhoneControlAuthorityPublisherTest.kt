package com.openburnbar.data.computeruse

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PhoneControlAuthorityPublisherTest {
    private val privateSeed = ByteArray(32) { index -> (index + 1).toByte() }
    private val publicKey = PhoneControlSigner.publicKey(privateSeed)

    @Test
    fun authorityDocumentMatchesFirestoreRulesShape() {
        val doc = PhoneControlAuthorityDocumentFactory.document(
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
}
