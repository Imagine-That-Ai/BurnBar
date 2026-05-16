package com.openburnbar.irohrelay

import com.google.crypto.tink.signature.SignatureConfig
import java.security.SecureRandom
import java.util.Base64
import net.i2p.crypto.eddsa.EdDSAEngine
import net.i2p.crypto.eddsa.EdDSAPrivateKey
import net.i2p.crypto.eddsa.EdDSAPublicKey
import net.i2p.crypto.eddsa.spec.EdDSANamedCurveTable
import net.i2p.crypto.eddsa.spec.EdDSAPrivateKeySpec
import net.i2p.crypto.eddsa.spec.EdDSAPublicKeySpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test

/**
 * The Mac signs pairing records with iOS CryptoKit Curve25519 (Ed25519).
 * To exercise the Android verifier in a hermetic JVM unit test we use the
 * eddsa library on the test classpath only — production code never
 * exposes a signer.
 */
class IrohRelayPairingTest {
    private lateinit var spec: net.i2p.crypto.eddsa.spec.EdDSAParameterSpec
    private lateinit var privateKey: EdDSAPrivateKey
    private lateinit var publicKey: EdDSAPublicKey
    private lateinit var rawPublicKey: ByteArray

    @Before
    fun setUp() {
        SignatureConfig.register()
        spec = EdDSANamedCurveTable.ED_25519_CURVE_SPEC
        val seed = ByteArray(32).also { SecureRandom().nextBytes(it) }
        privateKey = EdDSAPrivateKey(EdDSAPrivateKeySpec(seed, spec))
        publicKey = EdDSAPublicKey(EdDSAPublicKeySpec(privateKey.a, spec))
        rawPublicKey = publicKey.abyte
    }

    private fun sign(payload: ByteArray): String {
        val engine = EdDSAEngine()
        engine.initSign(privateKey)
        engine.update(payload)
        return Base64.getEncoder().encodeToString(engine.sign())
    }

    @Test
    fun verify_accepts_signed_record() {
        val publishedAt = System.currentTimeMillis()
        val payload = IrohPairingSignature.canonicalPayload(
            uid = "uid-1",
            connectionId = "conn-1",
            nodeId = "node-1",
            relayURL = "https://relay.example.com",
            directAddresses = listOf("10.0.0.5:443", "192.168.1.2:443"),
            publishedAtMillis = publishedAt,
            protocolVersion = IrohRelayProtocol.FRAME_PROTOCOL_VERSION,
        )
        val signature = sign(payload)
        val record = IrohPairingRecord(
            uid = "uid-1",
            connectionId = "conn-1",
            nodeId = "node-1",
            relayURL = "https://relay.example.com",
            directAddresses = listOf("10.0.0.5:443", "192.168.1.2:443"),
            publishedAtMillis = publishedAt,
            signature = signature,
        )
        IrohPairingSignature.verify(record, publicKey = rawPublicKey, nowMillis = publishedAt + 1_000)
    }

    @Test
    fun verify_rejects_record_with_wrong_signature() {
        val publishedAt = System.currentTimeMillis()
        val payload = IrohPairingSignature.canonicalPayload(
            uid = "uid-1",
            connectionId = "conn-1",
            nodeId = "node-1",
            relayURL = null,
            directAddresses = emptyList(),
            publishedAtMillis = publishedAt,
            protocolVersion = IrohRelayProtocol.FRAME_PROTOCOL_VERSION,
        )
        val signature = sign(payload)
        val record = IrohPairingRecord(
            uid = "uid-1",
            connectionId = "conn-1",
            nodeId = "node-1",
            relayURL = null,
            directAddresses = emptyList(),
            publishedAtMillis = publishedAt,
            // Tamper with the nodeId AFTER signing.
            signature = signature,
        ).copy(nodeId = "tampered")
        assertThrows(IrohPairingError.InvalidSignature::class.java) {
            IrohPairingSignature.verify(record, publicKey = rawPublicKey, nowMillis = publishedAt + 1_000)
        }
    }

    @Test
    fun verify_rejects_record_older_than_max_age() {
        val publishedAt = System.currentTimeMillis() - (25 * 60 * 60 * 1000L)
        val payload = IrohPairingSignature.canonicalPayload(
            uid = "uid-1",
            connectionId = "conn-1",
            nodeId = "node-1",
            relayURL = null,
            directAddresses = emptyList(),
            publishedAtMillis = publishedAt,
            protocolVersion = IrohRelayProtocol.FRAME_PROTOCOL_VERSION,
        )
        val record = IrohPairingRecord(
            uid = "uid-1",
            connectionId = "conn-1",
            nodeId = "node-1",
            publishedAtMillis = publishedAt,
            signature = sign(payload),
        )
        assertThrows(IrohPairingError.Expired::class.java) {
            IrohPairingSignature.verify(record, publicKey = rawPublicKey)
        }
    }

    @Test
    fun canonical_payload_round_trips_through_pipe_format() {
        val payload = IrohPairingSignature.canonicalPayload(
            uid = "uid-1",
            connectionId = "conn-1",
            nodeId = "node-xyz",
            relayURL = "  https://relay.example  ",
            directAddresses = listOf("  10.0.0.1:1 ", "10.0.0.1:1", "10.0.0.2:1"),
            publishedAtMillis = 12345L,
            protocolVersion = 1,
        )
        val expected = "openburnbar.iroh.pairing.v1|uid-1|conn-1|node-xyz|https://relay.example|10.0.0.1:1,10.0.0.2:1|12345"
        assertEquals(expected, String(payload, Charsets.UTF_8))
    }

    @Test
    fun verify_rejects_unsupported_protocol_version() {
        val publishedAt = System.currentTimeMillis()
        val record = IrohPairingRecord(
            uid = "uid",
            connectionId = "conn",
            nodeId = "node",
            publishedAtMillis = publishedAt,
            protocolVersion = 99,
            signature = Base64.getEncoder().encodeToString(ByteArray(64)),
        )
        assertThrows(IrohPairingError.UnsupportedProtocolVersion::class.java) {
            IrohPairingSignature.verify(record, publicKey = rawPublicKey)
        }
    }
}
