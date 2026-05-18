package com.openburnbar.data.hermes.relay

import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.time.Instant
import java.util.Base64 as JavaBase64
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class HermesRelayDiscoverySchemaTest {

    @Before
    fun stubAndroidBase64() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            JavaBase64.getDecoder().decode(firstArg<String>())
        }
    }

    @After
    fun restoreStaticMocks() {
        unmockkStatic(android.util.Base64::class)
    }

    @Test
    fun mapsCanonicalHermesConnectionDocument() {
        val descriptor = decodeHermesRelayConnectionDescriptor(
            documentId = "doc-id",
            data = mapOf(
                "id" to "relay-123",
                "displayName" to "Alberto's MacBook Pro Hermes Relay",
                "relayPublicKey" to "relay-public-key",
                "relayKeyVersion" to 1L,
                "relayEncryption" to HermesRelayCrypto.ALGORITHM,
                "advertisedModel" to "minimax-m2.7-highspeed",
                "capabilities" to listOf("chat_completions", "remote_relay", "realtime_relay"),
                "status" to "online",
                "updatedAt" to "2026-05-17T02:11:39.164Z",
            ),
        )

        assertNotNull(descriptor)
        descriptor!!
        assertEquals("relay-123", descriptor.id)
        assertEquals("Alberto's MacBook Pro Hermes Relay", descriptor.displayName)
        assertEquals("relay-public-key", descriptor.relayPublicKey)
        assertEquals(1, descriptor.relayKeyVersion)
        assertEquals("minimax-m2.7-highspeed", descriptor.advertisedModel)
        assertEquals(listOf("chat_completions", "remote_relay", "realtime_relay"), descriptor.capabilities)
        assertEquals(Instant.parse("2026-05-17T02:11:39.164Z").toEpochMilli(), descriptor.updatedAt)
    }

    @Test
    fun keepsLegacyRelayConnectionDocumentFallbacks() {
        val descriptor = decodeHermesRelayConnectionDescriptor(
            documentId = "legacy-relay",
            data = mapOf(
                "display_name" to "Legacy relay",
                "relay_public_key" to "legacy-public-key",
                "relay_key_version" to 1,
                "relay_encryption" to HermesRelayCrypto.ALGORITHM,
                "advertised_model" to "deepseek-v4-flash",
                "updated_at" to 1778983899164L,
            ),
        )

        assertNotNull(descriptor)
        descriptor!!
        assertEquals("legacy-relay", descriptor.id)
        assertEquals("Legacy relay", descriptor.displayName)
        assertEquals("legacy-public-key", descriptor.relayPublicKey)
        assertEquals("deepseek-v4-flash", descriptor.advertisedModel)
        assertEquals(1778983899164L, descriptor.updatedAt)
    }

    @Test
    fun skipsNonRelayHermesConnectionWithoutRelayPublicKey() {
        val descriptor = decodeHermesRelayConnectionDescriptor(
            documentId = "direct",
            data = mapOf(
                "displayName" to "Direct Hermes",
                "mode" to "directURL",
                "endpointURL" to "http://127.0.0.1:11434",
            ),
        )

        assertEquals(null, descriptor)
    }

    @Test
    fun decodesCanonicalIrohPairingPublicKey() {
        val raw = ByteArray(32) { it.toByte() }
        val decoded = decodeIrohPairingPublicKey(
            mapOf("publicKeyBase64" to JavaBase64.getEncoder().encodeToString(raw)),
        )

        assertTrue(raw.contentEquals(decoded))
    }

    @Test
    fun mapsCanonicalIrohPairingRecordFromMacSchema() {
        val record = decodeIrohPairingRecord(
            documentId = "relay-123",
            uid = "firebase-uid",
            data = mapOf(
                "id" to "relay-123",
                "uid" to "stale-legacy-field",
                "nodeId" to "host-node",
                "relayURL" to "https://relay.example.test/",
                "directAddresses" to listOf("addr-b", "addr-a"),
                "publishedAtMillis" to 1778983899164L,
                "protocolVersion" to 1L,
                "signature" to "signature-base64",
            ),
        )

        assertNotNull(record)
        record!!
        assertEquals("firebase-uid", record.uid)
        assertEquals("relay-123", record.connectionId)
        assertEquals("host-node", record.nodeId)
        assertEquals("https://relay.example.test/", record.relayURL)
        assertEquals(listOf("addr-b", "addr-a"), record.directAddresses)
        assertEquals(1778983899164L, record.publishedAtMillis)
        assertEquals(1, record.protocolVersion)
        assertEquals("signature-base64", record.signature)
    }

    @Test
    fun rejectsWrongSizedIrohPairingPublicKey() {
        val thrown = runCatching {
            decodeIrohPairingPublicKey(
                mapOf("publicKeyBase64" to JavaBase64.getEncoder().encodeToString(ByteArray(16))),
            )
        }.exceptionOrNull()

        assertTrue(thrown is HermesRelayException)
        assertEquals("Pairing public key is not a valid Ed25519 public key.", thrown?.message)
    }
}
