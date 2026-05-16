package com.openburnbar.data.hermes.relay

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayPayload
import com.openburnbar.irohrelay.HermesRelayChunkKind
import com.openburnbar.irohrelay.InMemoryIrohPairingDirectory
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
import java.security.KeyPair
import java.security.interfaces.ECPublicKey
import java.util.Base64
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeoutOrNull
import net.i2p.crypto.eddsa.EdDSAEngine
import net.i2p.crypto.eddsa.EdDSAPrivateKey
import net.i2p.crypto.eddsa.EdDSAPublicKey
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
 * dials a fake Mac via `LoopbackIrohRelayTransport`, unwraps the
 * request-side symmetric key using the relay-private key + `keyAAD`,
 * decrypts the request body with `requestAAD`, then re-seals response
 * chunks with `chunkAAD` and `sse`/`data` kind. The Mac's exact contract
 * — pinned in production against
 * `AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift`.
 */
class HermesIrohRelayTransportTest {

    private val pairingSpec = EdDSANamedCurveTable.ED_25519_CURVE_SPEC
    private val pairingPrivateKey: EdDSAPrivateKey
    private val pairingPublicKeyRaw: ByteArray
    private val relayKeyPair: KeyPair = HermesRelayCrypto.generateEphemeralKeyPair()
    private val relayPublicX963: ByteArray =
        HermesRelayCrypto.encodeUncompressedPublicKey(relayKeyPair.public as ECPublicKey)
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

    @Test
    fun aad_strings_match_canonical_prefix() {
        // Pinned by the Mac via OpenBurnBar-HermesRelay-v1|<part>|<uid>|<cid>|<rid>.
        val req = HermesRelayCrypto.requestAAD("u1", "c1", "r1")
        assertEquals("OpenBurnBar-HermesRelay-v1|request|u1|c1|r1", String(req, Charsets.UTF_8))
        val key = HermesRelayCrypto.keyAAD("u1", "c1", "r1")
        assertEquals("OpenBurnBar-HermesRelay-v1|key|u1|c1|r1", String(key, Charsets.UTF_8))
        val chunk = HermesRelayCrypto.chunkAAD("u1", "c1", "r1", sequence = 3, kind = "sse")
        assertEquals("OpenBurnBar-HermesRelay-v1|chunk|u1|c1|r1|3|sse", String(chunk, Charsets.UTF_8))
    }

    @Test
    fun unary_send_returns_concatenated_data_chunks() = runTest {
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
            operation = "models",
            method = "GET",
            path = "/v1/models",
            connectionID = connectionId,
            relayPublicKey = Base64.getEncoder().encodeToString(relayPublicX963),
        )

        val server = async {
            val stream = hostTransport.accept(timeoutMillis = 5_000)
            handleSingleRequest(
                stream = stream,
                chunks = listOf("Hello " to HermesRelayChunkKind.DATA, "world" to HermesRelayChunkKind.DATA),
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
            relayPublicKey = Base64.getEncoder().encodeToString(relayPublicX963),
        )

        val server = async {
            val stream = hostTransport.accept(timeoutMillis = 5_000)
            handleSingleRequest(
                stream = stream,
                chunks = listOf(
                    "delta-1" to HermesRelayChunkKind.SSE,
                    "delta-2" to HermesRelayChunkKind.SSE,
                ),
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
    fun mac_can_decrypt_request_payload_with_keyAAD_then_requestAAD() = runTest {
        // Equivalent end-to-end: the Mac receiver must (a) unwrap the
        // symmetric key with the keyAAD-derived wrapping key, then (b)
        // open the request body with requestAAD. If either AAD drifts
        // this test fails.
        val uid = "uid-decrypt"
        val connectionId = "conn-decrypt"
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
            body = "{\"messages\":[]}".toByteArray(),
            sessionID = "sess-1",
            connectionID = connectionId,
            relayPublicKey = Base64.getEncoder().encodeToString(relayPublicX963),
        )

        var decodedPath: String? = null
        var decodedBody: String? = null
        var decodedSessionId: String? = null

        val server = async {
            val stream = hostTransport.accept(timeoutMillis = 5_000)
            val incoming = stream.receive() ?: error("no frame")
            val framePayload = incoming.payload ?: error("no payload")
            val keyData = HermesRelayCrypto.unwrapSymmetricKey(
                wrappedKeyBase64 = framePayload.wrappedKey ?: error("missing wrappedKey"),
                privateKey = relayKeyPair.private,
                aad = HermesRelayCrypto.keyAAD(incoming.uid, incoming.connectionId, incoming.requestId.orEmpty()),
            )
            val plaintext = HermesRelayCrypto.openBase64(
                ciphertext = framePayload.payloadCiphertext ?: error("missing payloadCiphertext"),
                keyData = keyData,
                aad = HermesRelayCrypto.requestAAD(incoming.uid, incoming.connectionId, incoming.requestId.orEmpty()),
            )
            val json = org.json.JSONObject(String(plaintext, Charsets.UTF_8))
            decodedPath = json.optString("path")
            decodedBody = json.optString("body")
            decodedSessionId = json.optString("sessionId")
            // Send one terminal chunk so the client returns.
            sendChunk(
                stream = stream,
                frame = incoming,
                keyData = keyData,
                sequence = 0,
                kind = HermesRelayChunkKind.DATA,
                text = "ok",
            )
            sendComplete(stream = stream, frame = incoming, chunkCount = 1)
        }
        transport.sendUnary(payload, timeoutMillis = 5_000)
        server.await()
        assertEquals("/v1/chat/completions", decodedPath)
        assertEquals("{\"messages\":[]}", decodedBody)
        assertEquals("sess-1", decodedSessionId)
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
            relayPublicKey = Base64.getEncoder().encodeToString(relayPublicX963),
        )

        // Server accepts but never replies → unary should surface a
        // HermesRelayException after `timeoutMillis`.
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

    // --- Helpers ------------------------------------------------------

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
        val keyStore = mockk<HermesRelayKeyStore>(relaxed = true)
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

    /**
     * Drive one server-side exchange that matches the Mac iroh handler:
     * read REQUEST_START → unwrap symmetric key (keyAAD) → open body
     * (requestAAD) → emit `chunks` then RESPONSE_COMPLETE.
     */
    private suspend fun handleSingleRequest(
        stream: IrohRelayStream,
        chunks: List<Pair<String, HermesRelayChunkKind>>,
    ) {
        val incoming = stream.receive() ?: return
        val framePayload = incoming.payload ?: return
        val keyData = HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKeyBase64 = framePayload.wrappedKey ?: error("missing wrappedKey"),
            privateKey = relayKeyPair.private,
            aad = HermesRelayCrypto.keyAAD(incoming.uid, incoming.connectionId, incoming.requestId.orEmpty()),
        )
        // Decrypt request body just to assert it parses (catches AAD drift).
        HermesRelayCrypto.openBase64(
            ciphertext = framePayload.payloadCiphertext ?: error("missing payloadCiphertext"),
            keyData = keyData,
            aad = HermesRelayCrypto.requestAAD(incoming.uid, incoming.connectionId, incoming.requestId.orEmpty()),
        )

        chunks.forEachIndexed { index, (text, kind) ->
            sendChunk(stream = stream, frame = incoming, keyData = keyData, sequence = index, kind = kind, text = text)
        }
        sendComplete(stream = stream, frame = incoming, chunkCount = chunks.size)
    }

    private suspend fun sendChunk(
        stream: IrohRelayStream,
        frame: HermesRealtimeRelayFrame,
        keyData: ByteArray,
        sequence: Int,
        kind: HermesRelayChunkKind,
        text: String,
    ) {
        val aad = HermesRelayCrypto.chunkAAD(
            uid = frame.uid,
            connectionId = frame.connectionId,
            requestId = frame.requestId.orEmpty(),
            sequence = sequence,
            kind = kind.wireValue,
        )
        val sealed = HermesRelayCrypto.sealToBase64(text.toByteArray(Charsets.UTF_8), keyData, aad)
        stream.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.RESPONSE_CHUNK,
                uid = frame.uid,
                connectionId = frame.connectionId,
                requestId = frame.requestId,
                payload = HermesRealtimeRelayPayload(
                    sequence = sequence,
                    kind = kind,
                    ciphertext = sealed,
                ),
            ),
        )
    }

    private suspend fun sendComplete(
        stream: IrohRelayStream,
        frame: HermesRealtimeRelayFrame,
        chunkCount: Int,
    ) {
        stream.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.RESPONSE_COMPLETE,
                uid = frame.uid,
                connectionId = frame.connectionId,
                requestId = frame.requestId,
                payload = HermesRealtimeRelayPayload(chunkCount = chunkCount),
            ),
        )
    }
}
