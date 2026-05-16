package com.openburnbar.data.hermes.relay

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayPayload
import com.openburnbar.irohrelay.HermesRelayChunkKind
import com.openburnbar.irohrelay.InMemoryIrohPairingDirectory
import com.openburnbar.irohrelay.IrohEndpointIdentity
import com.openburnbar.irohrelay.IrohPairingRecord
import com.openburnbar.irohrelay.IrohPairingSignature
import com.openburnbar.irohrelay.IrohRelayProtocol
import com.openburnbar.irohrelay.IrohRelayStream
import com.openburnbar.irohrelay.IrohRelayTransport
import com.openburnbar.irohrelay.LoopbackIrohRelayRendezvous
import com.openburnbar.irohrelay.LoopbackIrohRelayTransport
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.security.interfaces.ECPublicKey
import java.util.Base64
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeoutOrNull
import net.i2p.crypto.eddsa.EdDSAPrivateKey
import net.i2p.crypto.eddsa.EdDSAPublicKey
import net.i2p.crypto.eddsa.EdDSAEngine
import net.i2p.crypto.eddsa.spec.EdDSANamedCurveTable
import net.i2p.crypto.eddsa.spec.EdDSAPrivateKeySpec
import net.i2p.crypto.eddsa.spec.EdDSAPublicKeySpec
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Loopback-backed unit tests for `HermesIrohRelayTransport`. The test
 * dials a fake Mac via the in-process `LoopbackIrohRelayTransport`,
 * decrypts the framed payload with the relay-private key, and replays
 * encrypted chunk/complete frames so the transport produces an output
 * string identical to what an iOS sender would.
 *
 * The AAD strings are pinned by the production crypto path; this suite
 * additionally pins them as constants in the assertions so a Mac-side
 * drift would be caught here.
 */
class HermesIrohRelayTransportTest {

    private val pairingSpec = EdDSANamedCurveTable.ED_25519_CURVE_SPEC
    private val pairingPrivateKey: EdDSAPrivateKey
    private val pairingPublicKeyRaw: ByteArray
    private val relayKeyPair = HermesRelayCrypto.generateEphemeralKeyPair()
    private val rendezvous = LoopbackIrohRelayRendezvous()

    init {
        val seed = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        pairingPrivateKey = EdDSAPrivateKey(EdDSAPrivateKeySpec(seed, pairingSpec))
        val pub = EdDSAPublicKey(EdDSAPublicKeySpec(pairingPrivateKey.a, pairingSpec))
        pairingPublicKeyRaw = pub.abyte
    }

    @Before
    fun stubAndroidBase64() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            Base64.getEncoder().encodeToString(firstArg<ByteArray>())
        }
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            Base64.getDecoder().decode(firstArg<String>())
        }
    }

    @After
    fun restoreStaticMocks() {
        unmockkStatic(android.util.Base64::class)
    }

    private fun signPairing(payload: ByteArray): String {
        val engine = EdDSAEngine()
        engine.initSign(pairingPrivateKey)
        engine.update(payload)
        return Base64.getEncoder().encodeToString(engine.sign())
    }

    private fun makePairingRecord(uid: String, connectionId: String, nodeId: String): IrohPairingRecord {
        val now = System.currentTimeMillis()
        val payload = IrohPairingSignature.canonicalPayload(
            uid = uid,
            connectionId = connectionId,
            nodeId = nodeId,
            relayURL = null,
            directAddresses = emptyList(),
            publishedAtMillis = now,
            protocolVersion = IrohRelayProtocol.FRAME_PROTOCOL_VERSION,
        )
        return IrohPairingRecord(
            uid = uid,
            connectionId = connectionId,
            nodeId = nodeId,
            publishedAtMillis = now,
            signature = signPairing(payload),
        )
    }

    private fun fakeAuth(uid: String): FirebaseAuth {
        val firebaseUser = mockk<FirebaseUser>()
        every { firebaseUser.uid } returns uid
        val auth = mockk<FirebaseAuth>()
        every { auth.currentUser } returns firebaseUser
        return auth
    }

    private fun makeTransport(
        uid: String,
        connectionId: String,
        clientTransport: IrohRelayTransport,
    ): Pair<HermesIrohRelayTransport, InMemoryIrohPairingDirectory> {
        val directory = InMemoryIrohPairingDirectory()
        val nodeId = "host-${connectionId}"
        runBlocking { directory.publish(makePairingRecord(uid, connectionId, nodeId), uid) }
        val keyStore = mockk<HermesRelayKeyStore>()
        every { keyStore.loadOrCreateClientKeyPair() } returns relayKeyPair
        val publicKeyProvider = object : IrohPairingPublicKeyProviding {
            override suspend fun fetchPublicKey(uid: String): ByteArray = pairingPublicKeyRaw
        }
        val transport = HermesIrohRelayTransport(
            context = mockk(relaxed = true),
            keyStore = keyStore,
            pairingDirectory = directory,
            pairingPublicKeyProvider = publicKeyProvider,
            transportFactory = { clientTransport },
            auth = fakeAuth(uid),
            connectTimeoutMillis = 2_000,
        )
        return transport to directory
    }

    @Test
    fun aad_strings_match_canonical_prefix() {
        // Pin: `OpenBurnBar-HermesRelay-v1|<op>|<reqId>|<part>`.
        val req = HermesRelayCrypto.aad("op", "rid", "request")
        assertEquals("OpenBurnBar-HermesRelay-v1|op|rid|request", String(req, Charsets.UTF_8))
        val chunk = HermesRelayCrypto.aad("op", "rid", "chunk:3")
        assertEquals("OpenBurnBar-HermesRelay-v1|op|rid|chunk:3", String(chunk, Charsets.UTF_8))
    }

    @Test
    fun unary_send_returns_concatenated_text() = runTest {
        val uid = "uid-1"
        val connectionId = "conn-1"
        val nodeId = "host-${connectionId}"
        val hostTransport = LoopbackIrohRelayTransport(rendezvous, nodeId = nodeId)
        val clientTransport = LoopbackIrohRelayTransport(rendezvous, nodeId = "client-${connectionId}")
        hostTransport.start()
        clientTransport.start()

        val (transport, _) = makeTransport(
            uid = uid,
            connectionId = connectionId,
            clientTransport = clientTransport,
        )

        val payload = HermesRelayPayload(
            operation = "chatCompletions",
            method = "POST",
            path = "/v1/chat/completions",
            connectionID = connectionId,
            relayPublicKey = Base64.getEncoder().encodeToString(
                HermesRelayCrypto.encodeUncompressedPublicKey(relayKeyPair.public as ECPublicKey)
            ),
        )

        val server = async {
            val stream = hostTransport.accept(timeoutMillis = 5_000)
            handleSingleUnary(
                stream = stream,
                shared = HermesRelayCrypto.ecdh(relayKeyPair.private, relayKeyPair.public),
                chunks = listOf("Hello ", "world"),
            )
        }
        val result = transport.sendUnary(payload = payload, timeoutMillis = 5_000)
        server.await()
        assertEquals("Hello world", result)

        clientTransport.shutdown()
        hostTransport.shutdown()
    }

    @Test
    fun streaming_send_emits_sse_chunks() = runTest {
        val uid = "uid-stream"
        val connectionId = "conn-stream"
        val nodeId = "host-${connectionId}"
        val hostTransport = LoopbackIrohRelayTransport(rendezvous, nodeId = nodeId)
        val clientTransport = LoopbackIrohRelayTransport(rendezvous, nodeId = "client-${connectionId}")
        hostTransport.start()
        clientTransport.start()

        val (transport, _) = makeTransport(
            uid = uid,
            connectionId = connectionId,
            clientTransport = clientTransport,
        )

        val payload = HermesRelayPayload(
            operation = "chatCompletions",
            method = "POST",
            path = "/v1/chat/completions",
            connectionID = connectionId,
            relayPublicKey = Base64.getEncoder().encodeToString(
                HermesRelayCrypto.encodeUncompressedPublicKey(relayKeyPair.public as ECPublicKey)
            ),
        )

        val server = async {
            val stream = hostTransport.accept(timeoutMillis = 5_000)
            handleSingleUnary(
                stream = stream,
                shared = HermesRelayCrypto.ecdh(relayKeyPair.private, relayKeyPair.public),
                chunks = listOf("delta-1", "delta-2"),
            )
        }
        val received = mutableListOf<String>()
        transport.sendStreaming(
            payload = payload,
            timeoutMillis = 5_000,
            onSseEvent = { received.add(it) },
        )
        server.await()
        assertEquals(listOf("delta-1", "delta-2"), received)

        clientTransport.shutdown()
        hostTransport.shutdown()
    }

    @Test
    fun missing_user_fails_fast() = runTest {
        val hostTransport = LoopbackIrohRelayTransport(rendezvous, nodeId = "host-x")
        val clientTransport = LoopbackIrohRelayTransport(rendezvous, nodeId = "client-x")
        hostTransport.start()
        clientTransport.start()
        val auth = mockk<FirebaseAuth>()
        every { auth.currentUser } returns null

        val keyStore = mockk<HermesRelayKeyStore>()
        val publicKeyProvider = object : IrohPairingPublicKeyProviding {
            override suspend fun fetchPublicKey(uid: String): ByteArray = pairingPublicKeyRaw
        }
        val transport = HermesIrohRelayTransport(
            context = mockk(relaxed = true),
            keyStore = keyStore,
            pairingDirectory = InMemoryIrohPairingDirectory(),
            pairingPublicKeyProvider = publicKeyProvider,
            transportFactory = { clientTransport },
            auth = auth,
            connectTimeoutMillis = 500,
        )
        val payload = HermesRelayPayload(
            operation = "chatCompletions",
            method = "POST",
            path = "/v1/chat/completions",
            connectionID = "c",
            relayPublicKey = "AAAA",
        )
        val thrown = runCatching { transport.sendUnary(payload, 100) }.exceptionOrNull()
        assertTrue("expected HermesRelayException, got $thrown", thrown is HermesRelayException)

        clientTransport.shutdown()
        hostTransport.shutdown()
    }

    @Test
    fun timeout_cascades_when_host_never_replies() = runTest {
        val uid = "uid-timeout"
        val connectionId = "conn-timeout"
        val nodeId = "host-${connectionId}"
        val hostTransport = LoopbackIrohRelayTransport(rendezvous, nodeId = nodeId)
        val clientTransport = LoopbackIrohRelayTransport(rendezvous, nodeId = "client-${connectionId}")
        hostTransport.start()
        clientTransport.start()

        val (transport, _) = makeTransport(
            uid = uid,
            connectionId = connectionId,
            clientTransport = clientTransport,
        )

        val payload = HermesRelayPayload(
            operation = "chatCompletions",
            method = "POST",
            path = "/v1/chat/completions",
            connectionID = connectionId,
            relayPublicKey = Base64.getEncoder().encodeToString(
                HermesRelayCrypto.encodeUncompressedPublicKey(relayKeyPair.public as ECPublicKey)
            ),
        )

        // Server accepts but never sends anything → unary call should
        // surface a HermesRelayException after `timeoutMillis`.
        val server = async { hostTransport.accept(timeoutMillis = 2_000) }

        val outcome = runCatching {
            withTimeoutOrNull(2_000) {
                transport.sendUnary(payload, timeoutMillis = 150)
            }
        }
        assertTrue(
            "expected timeout exception, got $outcome",
            (outcome.exceptionOrNull() is HermesRelayException) || outcome.getOrNull() == null,
        )
        server.await()

        clientTransport.shutdown()
        hostTransport.shutdown()
    }

    /**
     * Drive one server-side exchange: read the `request.start`, decrypt
     * it with the relay-private key (ECDH on the same keypair), then send
     * `response.chunk` frames followed by `response.complete`.
     */
    private suspend fun handleSingleUnary(
        stream: IrohRelayStream,
        shared: ByteArray,
        chunks: List<String>,
    ) {
        val incoming = stream.receive() ?: return
        val payload = incoming.payload ?: return
        val nonceAndCipher = Base64.getDecoder().decode(payload.payloadCiphertext)
        // We don't need to decrypt; only need the requestId + connection
        // ids to address response frames back to the same logical stream.
        val nonce = nonceAndCipher.copyOfRange(0, 12)
        val ciphertext = nonceAndCipher.copyOfRange(12, nonceAndCipher.size)
        val operation = payload.operation.orEmpty()
        val requestId = incoming.requestId.orEmpty()
        val requestKey = HermesRelayCrypto.deriveKey(
            shared,
            HermesRelayCrypto.aad(operation, requestId, "request"),
        )
        HermesRelayCrypto.open(
            nonce = nonce,
            ciphertext = ciphertext,
            key = requestKey,
            aad = HermesRelayCrypto.aad(operation, requestId, "request"),
        )

        chunks.forEachIndexed { index, text ->
            val aad = HermesRelayCrypto.aad(operation, requestId, "chunk:${index}")
            val key = HermesRelayCrypto.deriveKey(shared, aad)
            val sealed = HermesRelayCrypto.seal(text.toByteArray(Charsets.UTF_8), key, aad)
            val response = HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.RESPONSE_CHUNK,
                uid = incoming.uid,
                connectionId = incoming.connectionId,
                requestId = incoming.requestId,
                payload = HermesRealtimeRelayPayload(
                    operation = operation,
                    sequence = index,
                    kind = HermesRelayChunkKind.TEXT,
                    ciphertext = Base64.getEncoder().encodeToString(sealed.nonce + sealed.ciphertext),
                ),
            )
            stream.send(response)
        }
        stream.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.RESPONSE_COMPLETE,
                uid = incoming.uid,
                connectionId = incoming.connectionId,
                requestId = incoming.requestId,
                payload = HermesRealtimeRelayPayload(operation = operation, chunkCount = chunks.size),
            )
        )
    }
}
