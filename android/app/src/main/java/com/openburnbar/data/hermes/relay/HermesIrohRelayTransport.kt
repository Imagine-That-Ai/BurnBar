package com.openburnbar.data.hermes.relay

import android.content.Context
import android.util.Base64
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayPayload
import com.openburnbar.irohrelay.HermesRelayChunkKind as RelayChunkKind
import com.openburnbar.irohrelay.IrohDialTarget
import com.openburnbar.irohrelay.IrohPairingDirectory
import com.openburnbar.irohrelay.IrohPairingDirectoryException
import com.openburnbar.irohrelay.IrohPairingError
import com.openburnbar.irohrelay.IrohPairingPublisher
import com.openburnbar.irohrelay.IrohPairingRecord
import com.openburnbar.irohrelay.IrohRelayProtocol
import com.openburnbar.irohrelay.IrohRelayTransport
import com.openburnbar.irohrelay.IrohRelayTransportError
import com.openburnbar.irohrelay.IrohSecretKeyMaterial
import com.openburnbar.irohrelay.IrohTransportAuditLogging
import com.openburnbar.irohrelay.IrohTransportAuditEvent
import com.openburnbar.irohrelay.IrohTransportSelection
import com.openburnbar.irohrelay.IrohJniTransport
import com.openburnbar.irohrelay.LoopbackIrohRelayRendezvous
import com.openburnbar.irohrelay.LoopbackIrohRelayTransport
import com.openburnbar.irohrelay.NoopIrohTransportAuditLogging
import com.openburnbar.irohrelay.OpenBurnBarIrohFfiBackend
import java.util.UUID
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.tasks.await
import org.json.JSONObject

/**
 * Android iroh transport. Conforms to `HermesRelayTransporting` so it
 * slots into `HermesCompositeRelayTransport` next to the existing
 * Firestore-polling `HermesRelayClient` (fallback). Picks up the Mac's
 * NodeAddr material from the signed `iroh_pairing` Firestore record,
 * verifies the Ed25519 signature, then dials the iroh QUIC stream and
 * serves one frame round-trip per request.
 *
 * Mirrors `OpenBurnBarMobile/Services/IrohRelay/HermesIrohRelayTransport.swift`
 * down to the AAD strings and frame-type ordering.
 */
interface HermesRelayTransporting {
    suspend fun sendUnary(payload: HermesRelayPayload, timeoutMillis: Long): String
    suspend fun sendStreaming(
        payload: HermesRelayPayload,
        timeoutMillis: Long,
        onSseEvent: suspend (String) -> Unit,
    )
}

/** Encrypted relay payload — wire shape mirrors iOS `HermesRelayPayload`. */
data class HermesRelayPayload(
    val operation: String,
    val method: String,
    val path: String,
    val body: ByteArray? = null,
    val sessionID: String? = null,
    val connectionID: String,
    val relayPublicKey: String,
    val relayEncryption: String = HermesRelayCrypto.ALGORITHM,
    val relayKeyVersion: Int? = null,
)

class HermesIrohRelayTransport(
    private val context: Context,
    private val keyStore: HermesRelayKeyStore,
    private val pairingDirectory: IrohPairingDirectory,
    private val pairingPublicKeyProvider: IrohPairingPublicKeyProviding,
    private val auditLogger: IrohTransportAuditLogging = NoopIrohTransportAuditLogging,
    private val transportFactory: () -> IrohRelayTransport = { defaultTransport(keyStore = HermesRelayKeyStore(context)) },
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val connectTimeoutMillis: Long = DEFAULT_CONNECT_TIMEOUT_MILLIS,
    private val nowMillis: () -> Long = { System.currentTimeMillis() },
) : HermesRelayTransporting {

    private val stateLock = Mutex()
    private var endpoint: IrohRelayTransport? = null
    private var startedOnce: Boolean = false

    override suspend fun sendUnary(payload: HermesRelayPayload, timeoutMillis: Long): String {
        val fragments = sortedMapOf<Int, String>()
        send(payload, timeoutMillis) { chunk ->
            when (chunk.kind) {
                RelayChunkKind.TEXT -> fragments[chunk.sequence] = chunk.text.orEmpty()
                RelayChunkKind.EVENT -> {} // SSE-style; ignored on unary path
                RelayChunkKind.TOOL_USE, RelayChunkKind.TOOL_RESULT, RelayChunkKind.REASONING ->
                    fragments[chunk.sequence] = chunk.text.orEmpty()
            }
        }
        return fragments.values.joinToString("")
    }

    override suspend fun sendStreaming(
        payload: HermesRelayPayload,
        timeoutMillis: Long,
        onSseEvent: suspend (String) -> Unit,
    ) {
        send(payload, timeoutMillis) { chunk ->
            val text = chunk.text.orEmpty()
            if (text.isNotEmpty()) onSseEvent(text)
        }
    }

    private suspend fun send(
        payload: HermesRelayPayload,
        timeoutMillis: Long,
        onChunk: suspend (StreamingChunk) -> Unit,
    ) {
        val uid = auth.currentUser?.uid
            ?: throw HermesRelayException("Iroh relay requires a signed-in Firebase user.")
        if (payload.relayEncryption != HermesRelayCrypto.ALGORITHM || payload.relayPublicKey.isBlank()) {
            throw HermesRelayException(
                "Update OpenBurnBar on your Mac and re-enable Remote Relay so this Android device can use encrypted relay traffic."
            )
        }

        val publicKey = pairingPublicKeyProvider.fetchPublicKey(uid)

        val publisher = IrohPairingPublisher(pairingDirectory)
        val verifiedTarget: IrohDialTarget = try {
            val target = publisher.fetchAndVerify(
                uid = uid,
                connectionId = payload.connectionID,
                publicKey = publicKey,
                nowMillis = nowMillis(),
            )
            auditLogger.record(
                event = IrohTransportAuditEvent.PAIRING_VERIFIED,
                uid = uid,
                connectionId = payload.connectionID,
                transport = null,
                rttMillis = null,
                detail = emptyMap(),
            )
            target
        } catch (err: IrohPairingDirectoryException) {
            auditLogger.record(
                event = IrohTransportAuditEvent.PAIRING_REJECTED,
                uid = uid,
                connectionId = payload.connectionID,
                transport = null,
                rttMillis = null,
                detail = mapOf("error" to (err.message ?: err.javaClass.simpleName).take(256)),
            )
            throw HermesRelayException("Could not verify iroh pairing record: ${err.message}")
        } catch (err: IrohPairingError) {
            auditLogger.record(
                event = IrohTransportAuditEvent.PAIRING_REJECTED,
                uid = uid,
                connectionId = payload.connectionID,
                transport = null,
                rttMillis = null,
                detail = mapOf("error" to (err.message ?: err.javaClass.simpleName).take(256)),
            )
            throw HermesRelayException("Could not verify iroh pairing record: ${err.message}")
        }

        val transport = transport()
        val dialTimeout = minOf(connectTimeoutMillis, timeoutMillis)
        val stream = try {
            withTimeoutOrNull(dialTimeout) {
                transport.connect(verifiedTarget, timeoutMillis = dialTimeout)
            } ?: throw IrohRelayTransportError.TimedOut
        } catch (err: IrohRelayTransportError) {
            auditLogger.record(
                event = IrohTransportAuditEvent.STREAM_FAILED,
                uid = uid,
                connectionId = payload.connectionID,
                transport = IrohTransportSelection.IROH_DIRECT,
                rttMillis = null,
                detail = mapOf("error" to (err.message ?: err.javaClass.simpleName).take(256)),
            )
            throw err
        }
        auditLogger.record(
            event = IrohTransportAuditEvent.STREAM_OPENED,
            uid = uid,
            connectionId = payload.connectionID,
            transport = IrohTransportSelection.IROH_DIRECT,
            rttMillis = null,
            detail = mapOf("side" to "android"),
        )

        try {
            val requestId = "iroh_${UUID.randomUUID().toString().lowercase()}"
            val keyPair = keyStore.loadOrCreateClientKeyPair()
            val relayPub = HermesRelayCrypto.decodeUncompressedPublicKey(
                Base64.decode(payload.relayPublicKey, Base64.NO_WRAP)
            )
            val shared = HermesRelayCrypto.ecdh(keyPair.private, relayPub)

            val bodyString = payload.body?.let { String(it, Charsets.UTF_8) }
            val plaintext = JSONObject().apply {
                put("path", payload.path)
                payload.sessionID?.let { put("session_id", it) }
                bodyString?.let { put("body", it) }
            }.toString().toByteArray(Charsets.UTF_8)
            val requestAad = HermesRelayCrypto.aad(payload.operation, requestId, "request")
            val key = HermesRelayCrypto.deriveKey(shared, requestAad)
            val sealed = HermesRelayCrypto.seal(plaintext, key, requestAad)

            val startFrame = HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.REQUEST_START,
                uid = uid,
                connectionId = payload.connectionID,
                requestId = requestId,
                payload = HermesRealtimeRelayPayload(
                    operation = payload.operation,
                    method = payload.method,
                    payloadCiphertext = Base64.encodeToString(
                        sealed.nonce + sealed.ciphertext, Base64.NO_WRAP,
                    ),
                    wrappedKey = Base64.encodeToString(shared, Base64.NO_WRAP),
                    relayEncryption = payload.relayEncryption,
                    relayKeyVersion = payload.relayKeyVersion ?: 1,
                ),
            )
            stream.send(startFrame)

            val deadline = nowMillis() + timeoutMillis
            while (nowMillis() < deadline) {
                val frame = stream.receive() ?: throw HermesRelayException("Iroh stream closed before completion.")
                if (frame.uid != uid || frame.connectionId != payload.connectionID || frame.requestId != requestId) continue
                when (frame.type) {
                    HermesRealtimeRelayFrameType.RESPONSE_CHUNK -> {
                        val chunk = chunkRecord(frame, shared = shared, requestId = requestId, uid = uid, connectionId = payload.connectionID) ?: continue
                        onChunk(chunk)
                    }
                    HermesRealtimeRelayFrameType.RESPONSE_COMPLETE -> {
                        auditLogger.record(
                            event = IrohTransportAuditEvent.STREAM_CLOSED,
                            uid = uid,
                            connectionId = payload.connectionID,
                            transport = IrohTransportSelection.IROH_DIRECT,
                            rttMillis = ((nowMillis() - (deadline - timeoutMillis)).toInt()),
                            detail = emptyMap(),
                        )
                        return
                    }
                    HermesRealtimeRelayFrameType.RESPONSE_ERROR -> {
                        throw HermesRelayException(frame.payload?.error ?: "Hermes iroh relay failed.")
                    }
                    else -> continue
                }
            }
            throw HermesRelayException("Iroh relay timed out before response.complete.")
        } finally {
            try { stream.close() } catch (_: Throwable) {}
        }
    }

    private suspend fun transport(): IrohRelayTransport = stateLock.withLock {
        val existing = endpoint
        if (existing != null && startedOnce) return@withLock existing
        val fresh = transportFactory()
        endpoint = fresh
        fresh.start()
        startedOnce = true
        fresh
    }

    private fun chunkRecord(
        frame: HermesRealtimeRelayFrame,
        shared: ByteArray,
        requestId: String,
        uid: String,
        connectionId: String,
    ): StreamingChunk? {
        val payload = frame.payload ?: return null
        val kind = payload.kind ?: return null
        val sequence = payload.sequence ?: return null
        val ciphertext = payload.ciphertext ?: return null
        val cipherBytes = Base64.decode(ciphertext, Base64.NO_WRAP)
        if (cipherBytes.size < 13) return null
        val nonce = cipherBytes.copyOfRange(0, 12)
        val body = cipherBytes.copyOfRange(12, cipherBytes.size)
        val aad = HermesRelayCrypto.aad(payload.operation ?: "", requestId, "chunk:$sequence")
        val key = HermesRelayCrypto.deriveKey(shared, aad)
        val plaintext = try { HermesRelayCrypto.open(nonce, body, key, aad) } catch (_: Throwable) { return null }
        return StreamingChunk(
            kind = kind,
            sequence = sequence,
            text = String(plaintext, Charsets.UTF_8),
        )
    }

    private data class StreamingChunk(
        val kind: RelayChunkKind,
        val sequence: Int,
        val text: String?,
    )

    companion object {
        const val DEFAULT_CONNECT_TIMEOUT_MILLIS: Long = 5_000

        /** Factory used by production wiring — JNI transport if AAR available, loopback otherwise. */
        fun defaultTransport(keyStore: HermesRelayKeyStore): IrohRelayTransport {
            val secretProvider: () -> IrohSecretKeyMaterial = { keyStore.irohSecretKeyMaterial() }
            return if (OpenBurnBarIrohFfiBackend.isAvailable()) {
                IrohJniTransport(
                    backend = OpenBurnBarIrohFfiBackend(),
                    secretProvider = secretProvider,
                    relayURLProvider = { null },
                )
            } else {
                LoopbackIrohRelayTransport(rendezvous = LoopbackIrohRelayRendezvous())
            }
        }
    }
}

interface IrohPairingPublicKeyProviding {
    suspend fun fetchPublicKey(uid: String): ByteArray
}

/** Firestore-backed `IrohPairingDirectory`, mirrors `FirestoreIrohPairingDirectory`. */
class FirestoreIrohPairingDirectory(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
) : IrohPairingDirectory {
    override suspend fun publish(record: IrohPairingRecord, uid: String) {
        // Android is verify-only — but support manual publish for tests.
        firestore.collection("users").document(uid)
            .collection("iroh_pairing").document(record.connectionId)
            .set(record.asMap())
            .await()
    }

    override suspend fun fetch(uid: String, connectionId: String): IrohPairingRecord? {
        val snap = firestore.collection("users").document(uid)
            .collection("iroh_pairing").document(connectionId)
            .get().await()
        if (!snap.exists()) return null
        @Suppress("UNCHECKED_CAST")
        val directAddresses = (snap.get("directAddresses") as? List<String>) ?: emptyList()
        return IrohPairingRecord(
            uid = snap.getString("uid").orEmpty(),
            connectionId = snap.getString("connectionId").orEmpty(),
            nodeId = snap.getString("nodeId").orEmpty(),
            relayURL = snap.getString("relayURL"),
            directAddresses = directAddresses,
            publishedAtMillis = snap.getLong("publishedAtMillis") ?: 0L,
            protocolVersion = (snap.getLong("protocolVersion") ?: IrohRelayProtocol.FRAME_PROTOCOL_VERSION.toLong()).toInt(),
            signature = snap.getString("signature").orEmpty(),
        )
    }

    override suspend fun revoke(uid: String, connectionId: String) {
        firestore.collection("users").document(uid)
            .collection("iroh_pairing").document(connectionId)
            .delete().await()
    }
}

private fun IrohPairingRecord.asMap(): Map<String, Any?> = mapOf(
    "uid" to uid,
    "connectionId" to connectionId,
    "nodeId" to nodeId,
    "relayURL" to relayURL,
    "directAddresses" to directAddresses,
    "publishedAtMillis" to publishedAtMillis,
    "protocolVersion" to protocolVersion,
    "signature" to signature,
)

/** Firestore-backed pairing public-key provider — reads from `hermes_relay_connections/{id}.pairing_public_key`. */
class FirestoreIrohPairingPublicKeyProvider(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
) : IrohPairingPublicKeyProviding {
    override suspend fun fetchPublicKey(uid: String): ByteArray {
        val snap = firestore.collection("users").document(uid)
            .collection("hermes_relay_connections").get().await()
        val doc = snap.documents.firstOrNull { it.getString("pairing_public_key") != null }
            ?: throw HermesRelayException("No paired Mac has published an iroh pairing public key yet.")
        val raw = doc.getString("pairing_public_key").orEmpty()
        return try { Base64.decode(raw, Base64.NO_WRAP) }
        catch (_: IllegalArgumentException) {
            throw HermesRelayException("Pairing public key is not valid base64.")
        }
    }
}
