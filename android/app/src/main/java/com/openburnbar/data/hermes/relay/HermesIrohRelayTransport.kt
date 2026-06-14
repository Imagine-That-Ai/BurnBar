package com.openburnbar.data.hermes.relay

import android.content.Context
import android.util.Base64
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRelayChunkKind as RelayChunkKind
import com.openburnbar.irohrelay.IrohDialTarget
import com.openburnbar.irohrelay.IrohJniTransport
import com.openburnbar.irohrelay.IrohPairingDirectory
import com.openburnbar.irohrelay.IrohPairingDirectoryException
import com.openburnbar.irohrelay.IrohPairingError
import com.openburnbar.irohrelay.IrohPairingPublisher
import com.openburnbar.irohrelay.IrohPairingRecord
import com.openburnbar.irohrelay.IrohRelayProtocol
import com.openburnbar.irohrelay.IrohRelayStream
import com.openburnbar.irohrelay.IrohRelayTransport
import com.openburnbar.irohrelay.IrohRelayTransportError
import com.openburnbar.irohrelay.IrohSecretKeyMaterial
import com.openburnbar.irohrelay.IrohTransportAuditEvent
import com.openburnbar.irohrelay.IrohTransportAuditLogging
import com.openburnbar.irohrelay.IrohTransportSelection
import com.openburnbar.irohrelay.LoopbackIrohRelayRendezvous
import com.openburnbar.irohrelay.LoopbackIrohRelayTransport
import com.openburnbar.irohrelay.NoopIrohTransportAuditLogging
import com.openburnbar.irohrelay.OpenBurnBarIrohFfiBackend
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull

/** Cap on the error text recorded in transport audit detail maps. */
private const val AUDIT_ERROR_DETAIL_MAX_CHARS = 256
private const val ED25519_PUBLIC_KEY_BYTES = 32
private const val RELAY_ERROR_REQUEST_FAILED = "request_failed"
private const val RELAY_ERROR_TRANSPORT_FAILED = "transport_failed"

private fun publicRelayErrorMessage(errorCode: String?): String = when (errorCode) {
    RELAY_ERROR_TRANSPORT_FAILED -> "The remote Hermes relay connection failed."
    RELAY_ERROR_REQUEST_FAILED, null, "" -> "The remote Hermes relay could not complete the request."
    else -> "The remote Hermes relay could not complete the request."
}

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

    suspend fun sendStreaming(payload: HermesRelayPayload, timeoutMillis: Long, onSseEvent: suspend (String) -> Unit)
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

    override suspend fun sendStreaming(payload: HermesRelayPayload, timeoutMillis: Long, onSseEvent: suspend (String) -> Unit) {
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

    private fun relayAuthenticatedUid(payload: HermesRelayPayload): String {
        val uid =
            auth.currentUser?.uid
                ?: throw HermesRelayException("Iroh relay requires a signed-in Firebase user.")
        val relayEncryptionValid =
            payload.relayEncryption == HermesRelayCrypto.ALGORITHM && payload.relayPublicKey.isNotBlank()
        if (!relayEncryptionValid) {
            throw HermesRelayException(
                "Update OpenBurnBar on your Mac and re-enable Remote Relay so this Android device can use encrypted relay traffic.",
            )
        }
        return uid
    }

    private suspend fun verifiedDialTarget(uid: String, payload: HermesRelayPayload, publicKey: ByteArray): IrohDialTarget {
        val publisher = IrohPairingPublisher(pairingDirectory)
        return try {
            val target =
                publisher.fetchAndVerify(
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
            throw pairingVerificationFailure(uid, payload.connectionID, err)
        } catch (err: IrohPairingError) {
            throw pairingVerificationFailure(uid, payload.connectionID, err)
        }
    }

    private suspend fun pairingVerificationFailure(uid: String, connectionId: String, err: Throwable): IrohRelayTransportError {
        val detail = err.message ?: err.javaClass.simpleName
        auditLogger.record(
            event = IrohTransportAuditEvent.PAIRING_REJECTED,
            uid = uid,
            connectionId = connectionId,
            transport = null,
            rttMillis = null,
            detail = mapOf("error" to detail.take(AUDIT_ERROR_DETAIL_MAX_CHARS)),
        )
        return IrohRelayTransportError.PairingRejected(detail = detail, source = err)
    }

    private suspend fun connectVerifiedStream(verifiedTarget: IrohDialTarget, uid: String, connectionId: String, dialTimeout: Long): IrohRelayStream {
        val transport = transport(verifiedTarget.relayURL)
        return try {
            withTimeoutOrNull(dialTimeout) {
                transport.connect(verifiedTarget, timeoutMillis = dialTimeout)
            } ?: throw IrohRelayTransportError.TimedOut
        } catch (err: IrohRelayTransportError) {
            auditLogger.record(
                event = IrohTransportAuditEvent.STREAM_FAILED,
                uid = uid,
                connectionId = connectionId,
                transport = IrohTransportSelection.IROH_DIRECT,
                rttMillis = null,
                detail = mapOf("error" to (err.message ?: err.javaClass.simpleName).take(AUDIT_ERROR_DETAIL_MAX_CHARS)),
            )
            throw err
        }
    }

    private suspend fun send(payload: HermesRelayPayload, timeoutMillis: Long, onChunk: suspend (StreamingChunk) -> Unit) {
        val uid = relayAuthenticatedUid(payload)

        val publicKey = pairingPublicKeyProvider.fetchPublicKey(uid)

        val verifiedTarget = verifiedDialTarget(uid, payload, publicKey)

        val dialTimeout = minOf(connectTimeoutMillis, timeoutMillis)
        val stream = connectVerifiedStream(verifiedTarget, uid, payload.connectionID, dialTimeout)
        auditLogger.record(
            event = IrohTransportAuditEvent.STREAM_OPENED,
            uid = uid,
            connectionId = payload.connectionID,
            transport = IrohTransportSelection.IROH_DIRECT,
            rttMillis = null,
            detail = mapOf("side" to "android"),
        )

        try {
            val relayPubBytes = decodeRelayPublicKeyBytes(payload.relayPublicKey)
            val frames = buildIrohRelaySendFrames(payload, uid, relayPubBytes)
            stream.send(frames.startFrame)

            exchangeRelayRequest(
                RelayExchangeRequest(
                    stream = stream,
                    uid = uid,
                    payload = payload,
                    timeoutMillis = timeoutMillis,
                    symmetricKey = frames.symmetricKey,
                    requestId = frames.requestId,
                    onChunk = onChunk,
                ),
            )
        } finally {
            try {
                stream.close()
            } catch (_: Throwable) {
            }
        }
    }

    private data class RelayExchangeRequest(
        val stream: IrohRelayStream,
        val uid: String,
        val payload: HermesRelayPayload,
        val timeoutMillis: Long,
        val symmetricKey: ByteArray,
        val requestId: String,
        val onChunk: suspend (StreamingChunk) -> Unit,
    )

    private suspend fun exchangeRelayRequest(request: RelayExchangeRequest) {
        val deadline = nowMillis() + request.timeoutMillis
        while (nowMillis() < deadline) {
            val remaining = deadline - nowMillis()
            val frame =
                withTimeoutOrNull(remaining) { request.stream.receive() }
                    ?: relayExchangeTimeout()
            val isMatchingFrame =
                frame.uid == request.uid &&
                    frame.connectionId == request.payload.connectionID &&
                    frame.requestId == request.requestId
            if (isMatchingFrame) {
                when (
                    val action =
                        relayFrameAction(
                            frame,
                            request.symmetricKey,
                            request.requestId,
                            request.uid,
                            request.payload.connectionID,
                        )
                ) {
                    RelayFrameAction.Continue -> Unit
                    RelayFrameAction.Complete -> {
                        auditLogger.record(
                            event = IrohTransportAuditEvent.STREAM_CLOSED,
                            uid = request.uid,
                            connectionId = request.payload.connectionID,
                            transport = IrohTransportSelection.IROH_DIRECT,
                            rttMillis = (nowMillis() - (deadline - request.timeoutMillis)).toInt(),
                            detail =
                            mapOf(
                                "side" to "android",
                                "stage" to "android_response_complete",
                                "requestId" to request.requestId,
                            ),
                        )
                        return
                    }
                    is RelayFrameAction.Emit -> request.onChunk(action.chunk)
                    is RelayFrameAction.Fail -> relayExchangeFail(action.error)
                }
            }
        }
        relayExchangeTimeout()
    }

    private fun relayExchangeTimeout(): Nothing = throw HermesRelayException("Iroh relay timed out before response.complete.")

    private fun relayExchangeFail(error: HermesRelayException): Nothing = throw error

    private sealed class RelayFrameAction {
        data object Continue : RelayFrameAction()

        data object Complete : RelayFrameAction()

        data class Emit(val chunk: StreamingChunk) : RelayFrameAction()

        data class Fail(val error: HermesRelayException) : RelayFrameAction()
    }

    private suspend fun relayFrameAction(
        frame: HermesRealtimeRelayFrame,
        symmetricKey: ByteArray,
        requestId: String,
        uid: String,
        connectionId: String,
    ): RelayFrameAction = when (frame.type) {
        HermesRealtimeRelayFrameType.RESPONSE_CHUNK -> {
            val chunk =
                chunkRecord(
                    frame = frame,
                    keyData = symmetricKey,
                    requestId = requestId,
                    uid = uid,
                    connectionId = connectionId,
                )
            if (chunk == null) {
                RelayFrameAction.Continue
            } else {
                auditLogger.record(
                    event = IrohTransportAuditEvent.STREAM_OPENED,
                    uid = uid,
                    connectionId = connectionId,
                    transport = IrohTransportSelection.IROH_DIRECT,
                    rttMillis = null,
                    detail =
                    mapOf(
                        "side" to "android",
                        "stage" to "android_response_chunk_received",
                        "requestId" to requestId,
                        "sequence" to chunk.sequence.toString(),
                        "kind" to chunk.kind.wireValue,
                        "textBytes" to (chunk.text?.toByteArray(Charsets.UTF_8)?.size ?: 0).toString(),
                    ),
                )
                auditLogger.record(
                    event = IrohTransportAuditEvent.STREAM_OPENED,
                    uid = uid,
                    connectionId = connectionId,
                    transport = IrohTransportSelection.IROH_DIRECT,
                    rttMillis = null,
                    detail =
                    mapOf(
                        "side" to "android",
                        "stage" to "android_response_chunk_processed",
                        "requestId" to requestId,
                        "sequence" to chunk.sequence.toString(),
                    ),
                )
                RelayFrameAction.Emit(chunk)
            }
        }
        HermesRealtimeRelayFrameType.RESPONSE_COMPLETE -> RelayFrameAction.Complete
        HermesRealtimeRelayFrameType.RESPONSE_ERROR ->
            RelayFrameAction.Fail(
                HermesRelayException(publicRelayErrorMessage(frame.payload?.errorCode)),
            )
        else -> RelayFrameAction.Continue
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

    private fun chunkRecord(frame: HermesRealtimeRelayFrame, keyData: ByteArray, requestId: String, uid: String, connectionId: String): StreamingChunk? {
        val payload = frame.payload
        val kind = payload?.kind
        val sequence = payload?.sequence
        val ciphertext = payload?.ciphertext
        val hasChunkFields = payload != null && kind != null && sequence != null && ciphertext != null
        if (!hasChunkFields) return null
        val aad =
            HermesRelayCrypto.chunkAAD(
                uid = uid,
                connectionId = connectionId,
                requestId = requestId,
                sequence = sequence,
                kind = kind.wireValue,
            )
        val plaintext =
            runCatching { HermesRelayCrypto.openBase64(ciphertext, keyData, aad) }.getOrNull()
                ?: return null
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
        throw IrohPairingDirectoryException.unsupportedOnReader()
    }

    override suspend fun fetch(uid: String, connectionId: String): IrohPairingRecord? {
        val snap =
            firestore.collection("users").document(uid)
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
        throw IrohPairingDirectoryException.unsupportedOnReader()
    }
}

internal fun decodeIrohPairingRecord(documentId: String, uid: String, data: Map<String, Any?>): IrohPairingRecord? {
    val connectionId =
        (data["id"] as? String)
            ?.takeIf { it.isNotBlank() }
            ?: (data["connectionId"] as? String)?.takeIf { it.isNotBlank() }
            ?: documentId.takeIf { it.isNotBlank() }
    val nodeId = (data["nodeId"] as? String)?.takeIf { it.isNotBlank() }
    val publishedAtMillis = data.longValue("publishedAtMillis")
    val signature = (data["signature"] as? String)?.takeIf { it.isNotBlank() }
    val hasRequiredPairingFields =
        !connectionId.isNullOrBlank() && nodeId != null && publishedAtMillis != null && signature != null
    if (!hasRequiredPairingFields) {
        return null
    }
    val protocolVersion = (data.longValue("protocolVersion") ?: IrohRelayProtocol.FRAME_PROTOCOL_VERSION.toLong()).toInt()
    val directAddresses =
        (data["directAddresses"] as? List<*>)
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
    val raw = (data["publicKeyBase64"] as? String)?.takeIf { it.isNotBlank() }
    if (raw == null) {
        throw HermesRelayException("No paired Mac has published an iroh pairing public key yet.")
    }
    val decoded = runCatching { Base64.decode(raw, Base64.NO_WRAP) }.getOrNull()
    val validationError =
        when {
            decoded == null -> "Pairing public key is not valid base64."
            decoded.size != ED25519_PUBLIC_KEY_BYTES -> "Pairing public key is not a valid Ed25519 public key."
            else -> null
        }
    if (validationError != null) throw HermesRelayException(validationError)
    return requireNotNull(decoded)
}

private fun Map<String, Any?>.longValue(key: String): Long? = when (val value = this[key]) {
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
        val snap =
            firestore.collection("users").document(uid)
                .collection("iroh_pairing_keys")
                .document("host")
                .get()
                .await()
        return decodeIrohPairingPublicKey(snap.data.orEmpty())
    }
}
