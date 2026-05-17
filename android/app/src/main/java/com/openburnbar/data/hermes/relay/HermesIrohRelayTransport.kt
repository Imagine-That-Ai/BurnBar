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
    private val transportFactory: (String?) -> IrohRelayTransport = { relayURL ->
        defaultTransport(keyStore = HermesRelayKeyStore(context), relayURL = relayURL)
    },
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val connectTimeoutMillis: Long = DEFAULT_CONNECT_TIMEOUT_MILLIS,
    private val nowMillis: () -> Long = { System.currentTimeMillis() },
) : HermesRelayTransporting {

    private val stateLock = Mutex()
    private var endpoint: IrohRelayTransport? = null
    private var startedOnce: Boolean = false
    private var endpointRelayURL: String? = null

    override suspend fun sendUnary(payload: HermesRelayPayload, timeoutMillis: Long): String {
        // Unary forwards arrive as `.data` chunks. The Mac splits the
        // body into ~16 KiB fragments emitted in `sequence` order; we
        // sort defensively and concatenate them into one string.
        val fragments = sortedMapOf<Int, String>()
        send(payload, timeoutMillis) { chunk ->
            when (chunk.kind) {
                RelayChunkKind.DATA -> fragments[chunk.sequence] = chunk.text.orEmpty()
                RelayChunkKind.SSE -> fragments[chunk.sequence] = chunk.text.orEmpty()
                RelayChunkKind.ERROR -> throw HermesRelayException(chunk.text.orEmpty().ifBlank { "Hermes iroh relay returned an error chunk." })
            }
        }
        return fragments.values.joinToString("")
    }

    override suspend fun sendStreaming(
        payload: HermesRelayPayload,
        timeoutMillis: Long,
        onSseEvent: suspend (String) -> Unit,
    ) {
        // Streaming chat (`POST /v1/chat/completions`) arrives as
        // `.sse` chunks, each carrying one SSE event payload. `.error`
        // is terminal.
        send(payload, timeoutMillis) { chunk ->
            when (chunk.kind) {
                RelayChunkKind.SSE, RelayChunkKind.DATA -> {
                    val text = chunk.text.orEmpty()
                    if (text.isNotEmpty()) onSseEvent(text)
                }
                RelayChunkKind.ERROR ->
                    throw HermesRelayException(chunk.text.orEmpty().ifBlank { "Hermes iroh relay returned an error chunk." })
            }
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

        val transport = transport(verifiedTarget.relayURL)
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
            val relayPubBytes = Base64.decode(payload.relayPublicKey, Base64.NO_WRAP)

            // Fresh AES-256 symmetric key per request. The Mac unwraps it
            // with its static P-256 private key and uses it for both the
            // request body (with requestAAD) and every response chunk
            // (with chunkAAD). Wire shape is identical to iOS' Hermes
            // relay (`OpenBurnBarMobile/Services/IrohRelay/`).
            val symmetricKey = HermesRelayCrypto.generateSymmetricKey()

            val bodyString = payload.body?.let { String(it, Charsets.UTF_8) }
            val plaintext = JSONObject().apply {
                put("path", payload.path)
                payload.sessionID?.let { put("sessionId", it) }
                bodyString?.let { put("body", it) }
            }.toString().toByteArray(Charsets.UTF_8)

            val requestAad = HermesRelayCrypto.requestAAD(uid, payload.connectionID, requestId)
            val keyAad = HermesRelayCrypto.keyAAD(uid, payload.connectionID, requestId)
            val payloadCiphertextB64 = HermesRelayCrypto.sealToBase64(plaintext, symmetricKey, requestAad)
            val wrappedKeyB64 = HermesRelayCrypto.wrapSymmetricKey(symmetricKey, relayPubBytes, keyAad)

            val startFrame = HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.REQUEST_START,
                uid = uid,
                connectionId = payload.connectionID,
                requestId = requestId,
                payload = HermesRealtimeRelayPayload(
                    operation = payload.operation,
                    method = payload.method,
                    payloadCiphertext = payloadCiphertextB64,
                    wrappedKey = wrappedKeyB64,
                    relayEncryption = payload.relayEncryption,
                    relayKeyVersion = payload.relayKeyVersion ?: HermesRelayCrypto.KEY_VERSION,
                ),
            )
            stream.send(startFrame)

            val deadline = nowMillis() + timeoutMillis
            while (nowMillis() < deadline) {
                val remaining = deadline - nowMillis()
                val frame = withTimeoutOrNull(remaining) { stream.receive() }
                    ?: throw HermesRelayException("Iroh relay timed out before response.complete.")
                if (frame.uid != uid || frame.connectionId != payload.connectionID || frame.requestId != requestId) continue
                when (frame.type) {
                    HermesRealtimeRelayFrameType.RESPONSE_CHUNK -> {
                        val chunk = chunkRecord(
                            frame = frame,
                            keyData = symmetricKey,
                            requestId = requestId,
                            uid = uid,
                            connectionId = payload.connectionID,
                        ) ?: continue
                        auditLogger.record(
                            event = IrohTransportAuditEvent.STREAM_OPENED,
                            uid = uid,
                            connectionId = payload.connectionID,
                            transport = IrohTransportSelection.IROH_DIRECT,
                            rttMillis = null,
                            detail = mapOf(
                                "side" to "android",
                                "stage" to "android_response_chunk_received",
                                "requestId" to requestId,
                                "sequence" to chunk.sequence.toString(),
                                "kind" to chunk.kind.wireValue,
                                "textBytes" to (chunk.text?.toByteArray(Charsets.UTF_8)?.size ?: 0).toString(),
                            ),
                        )
                        onChunk(chunk)
                        auditLogger.record(
                            event = IrohTransportAuditEvent.STREAM_OPENED,
                            uid = uid,
                            connectionId = payload.connectionID,
                            transport = IrohTransportSelection.IROH_DIRECT,
                            rttMillis = null,
                            detail = mapOf(
                                "side" to "android",
                                "stage" to "android_response_chunk_processed",
                                "requestId" to requestId,
                                "sequence" to chunk.sequence.toString(),
                            ),
                        )
                    }
                    HermesRealtimeRelayFrameType.RESPONSE_COMPLETE -> {
                        auditLogger.record(
                            event = IrohTransportAuditEvent.STREAM_CLOSED,
                            uid = uid,
                            connectionId = payload.connectionID,
                            transport = IrohTransportSelection.IROH_DIRECT,
                            rttMillis = ((nowMillis() - (deadline - timeoutMillis)).toInt()),
                            detail = mapOf(
                                "side" to "android",
                                "stage" to "android_response_complete",
                                "requestId" to requestId,
                            ),
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

    private suspend fun transport(relayURL: String?): IrohRelayTransport = stateLock.withLock {
        val existing = endpoint
        val normalizedRelayURL = relayURL?.trim()?.takeIf { it.isNotEmpty() }
        if (existing != null && startedOnce && endpointRelayURL == normalizedRelayURL) return@withLock existing
        if (existing != null && startedOnce) {
            runCatching { existing.shutdown() }
        }
        val fresh = transportFactory(normalizedRelayURL)
        endpoint = fresh
        fresh.start()
        startedOnce = true
        endpointRelayURL = normalizedRelayURL
        fresh
    }

    private fun chunkRecord(
        frame: HermesRealtimeRelayFrame,
        keyData: ByteArray,
        requestId: String,
        uid: String,
        connectionId: String,
    ): StreamingChunk? {
        val payload = frame.payload ?: return null
        val kind = payload.kind ?: return null
        val sequence = payload.sequence ?: return null
        val ciphertext = payload.ciphertext ?: return null
        val aad = HermesRelayCrypto.chunkAAD(
            uid = uid,
            connectionId = connectionId,
            requestId = requestId,
            sequence = sequence,
            kind = kind.wireValue,
        )
        val plaintext = try {
            HermesRelayCrypto.openBase64(ciphertext, keyData, aad)
        } catch (_: Throwable) {
            return null
        }
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
        fun defaultTransport(keyStore: HermesRelayKeyStore, relayURL: String? = null): IrohRelayTransport {
            val secretProvider: () -> IrohSecretKeyMaterial = { keyStore.irohSecretKeyMaterial() }
            return if (OpenBurnBarIrohFfiBackend.isAvailable()) {
                IrohJniTransport(
                    backend = OpenBurnBarIrohFfiBackend(),
                    secretProvider = secretProvider,
                    relayURLProvider = { relayURL },
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
        return decodeIrohPairingRecord(
            documentId = snap.id,
            uid = uid,
            data = snap.data.orEmpty(),
        )
    }

    override suspend fun revoke(uid: String, connectionId: String) {
        firestore.collection("users").document(uid)
            .collection("iroh_pairing").document(connectionId)
            .delete().await()
    }
}

private fun IrohPairingRecord.asMap(): Map<String, Any?> = mapOf(
    "id" to connectionId,
    "nodeId" to nodeId,
    "relayURL" to relayURL,
    "directAddresses" to directAddresses,
    "publishedAtMillis" to publishedAtMillis,
    "protocolVersion" to protocolVersion,
    "signature" to signature,
)

internal fun decodeIrohPairingRecord(
    documentId: String,
    uid: String,
    data: Map<String, Any?>,
): IrohPairingRecord? {
    val connectionId = (data["id"] as? String)
        ?.takeIf { it.isNotBlank() }
        ?: (data["connectionId"] as? String)?.takeIf { it.isNotBlank() }
        ?: documentId.takeIf { it.isNotBlank() }
        ?: return null
    val nodeId = (data["nodeId"] as? String)?.takeIf { it.isNotBlank() } ?: return null
    val publishedAtMillis = data.longValue("publishedAtMillis") ?: return null
    val signature = (data["signature"] as? String)?.takeIf { it.isNotBlank() } ?: return null
    val protocolVersion = (data.longValue("protocolVersion") ?: IrohRelayProtocol.FRAME_PROTOCOL_VERSION.toLong()).toInt()
    val directAddresses = (data["directAddresses"] as? List<*>)
        ?.mapNotNull { it as? String }
        ?: emptyList()
    return IrohPairingRecord(
        uid = uid,
        connectionId = connectionId,
        nodeId = nodeId,
        relayURL = data["relayURL"] as? String,
        directAddresses = directAddresses,
        publishedAtMillis = publishedAtMillis,
        protocolVersion = protocolVersion,
        signature = signature,
    )
}

internal fun decodeIrohPairingPublicKey(data: Map<String, Any?>): ByteArray {
    val raw = (data["publicKeyBase64"] as? String)
        ?.takeIf { it.isNotBlank() }
        ?: throw HermesRelayException("No paired Mac has published an iroh pairing public key yet.")
    val decoded = try {
        Base64.decode(raw, Base64.NO_WRAP)
    } catch (_: IllegalArgumentException) {
        throw HermesRelayException("Pairing public key is not valid base64.")
    }
    if (decoded.size != 32) {
        throw HermesRelayException("Pairing public key is not a valid Ed25519 public key.")
    }
    return decoded
}

private fun Map<String, Any?>.longValue(key: String): Long? =
    when (val value = this[key]) {
        is Long -> value
        is Int -> value.toLong()
        is Number -> value.toLong()
        else -> null
    }

/** Firestore-backed pairing public-key provider — reads from `iroh_pairing_keys/host.publicKeyBase64`. */
class FirestoreIrohPairingPublicKeyProvider(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
) : IrohPairingPublicKeyProviding {
    override suspend fun fetchPublicKey(uid: String): ByteArray {
        val snap = firestore.collection("users").document(uid)
            .collection("iroh_pairing_keys")
            .document("host")
            .get()
            .await()
        return decodeIrohPairingPublicKey(snap.data.orEmpty())
    }
}
