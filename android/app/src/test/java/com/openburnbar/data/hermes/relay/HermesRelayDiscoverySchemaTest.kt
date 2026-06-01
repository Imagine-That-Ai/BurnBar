package com.openburnbar.data.hermes.relay

import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.time.Instant
import java.util.Base64 as JavaBase64
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private const val VAL_16 = 16
private const val VAL_1778983899164_L = 1778983899164L
private const val VAL_32 = 32

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
        val descriptor =
            decodeHermesRelayConnectionDescriptor(
                documentId = "doc-id",
                data =
                mapOf(
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

        val resolved = requireNotNull(descriptor)
        assertEquals("relay-123", resolved.id)
        assertEquals("Alberto's MacBook Pro Hermes Relay", resolved.displayName)
        assertEquals("relay-public-key", resolved.relayPublicKey)
        assertEquals(1, resolved.relayKeyVersion)
        assertEquals("minimax-m2.7-highspeed", resolved.advertisedModel)
        assertEquals(listOf("chat_completions", "remote_relay", "realtime_relay"), resolved.capabilities)
        assertEquals(Instant.parse("2026-05-17T02:11:39.164Z").toEpochMilli(), resolved.updatedAt)
    }

    @Test
    fun keepsLegacyRelayConnectionDocumentFallbacks() {
        val descriptor =
            decodeHermesRelayConnectionDescriptor(
                documentId = "legacy-relay",
                data =
                mapOf(
                    "display_name" to "Legacy relay",
                    "relay_public_key" to "legacy-public-key",
                    "relay_key_version" to 1,
                    "relay_encryption" to HermesRelayCrypto.ALGORITHM,
                    "advertised_model" to "deepseek-v4-flash",
                    "updated_at" to VAL_1778983899164_L,
                ),
            )

        val resolved = requireNotNull(descriptor)
        assertEquals("legacy-relay", resolved.id)
        assertEquals("Legacy relay", resolved.displayName)
        assertEquals("legacy-public-key", resolved.relayPublicKey)
        assertEquals("deepseek-v4-flash", resolved.advertisedModel)
        assertEquals(VAL_1778983899164_L, resolved.updatedAt)
    }

    @Test
    fun skipsNonRelayHermesConnectionWithoutRelayPublicKey() {
        val descriptor =
            decodeHermesRelayConnectionDescriptor(
                documentId = "direct",
                data =
                mapOf(
                    "displayName" to "Direct Hermes",
                    "mode" to "directURL",
                    "endpointURL" to "http://127.0.0.1:11434",
                ),
            )

        assertEquals(null, descriptor)
    }

    @Test
    fun decodesCanonicalIrohPairingPublicKey() {
        val raw = ByteArray(VAL_32) { it.toByte() }
        val decoded =
            decodeIrohPairingPublicKey(
                mapOf("publicKeyBase64" to JavaBase64.getEncoder().encodeToString(raw)),
            )

        assertTrue(raw.contentEquals(decoded))
    }

    @Test
    fun mapsCanonicalIrohPairingRecordFromMacSchema() {
        val record =
            decodeIrohPairingRecord(
                documentId = "relay-123",
                uid = "firebase-uid",
                data =
                mapOf(
                    "id" to "relay-123",
                    "uid" to "stale-legacy-field",
                    "nodeId" to "host-node",
                    "relayURL" to "https://relay.example.test/",
                    "directAddresses" to listOf("addr-b", "addr-a"),
                    "publishedAtMillis" to VAL_1778983899164_L,
                    "protocolVersion" to 1L,
                    "signature" to "signature-base64",
                ),
            )

        val resolved = requireNotNull(record)
        assertEquals("firebase-uid", resolved.uid)
        assertEquals("relay-123", resolved.connectionId)
        assertEquals("host-node", resolved.nodeId)
        assertEquals("https://relay.example.test/", resolved.relayURL)
        assertEquals(listOf("addr-b", "addr-a"), resolved.directAddresses)
        assertEquals(VAL_1778983899164_L, resolved.publishedAtMillis)
        assertEquals(1, resolved.protocolVersion)
        assertEquals("signature-base64", resolved.signature)
    }

    @Test
    fun rejectsWrongSizedIrohPairingPublicKey() {
        val thrown =
            runCatching {
                decodeIrohPairingPublicKey(
                    mapOf("publicKeyBase64" to JavaBase64.getEncoder().encodeToString(ByteArray(VAL_16))),
                )
            }.exceptionOrNull()

        assertTrue(thrown is HermesRelayException)
        assertEquals("Pairing public key is not a valid Ed25519 public key.", thrown?.message)
    }
}
