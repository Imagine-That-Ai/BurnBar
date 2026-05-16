package com.openburnbar.data.hermes.relay

import android.util.Base64
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.Date
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.tasks.await
import org.json.JSONObject

class HermesRelayException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)

/**
 * Operation rawValues recognised by the Mac (`HermesRelayOperation` in
 * `OpenBurnBarCore/SharedModels/HermesConnectionTypes.swift`).
 */
object HermesRelayOperationName {
    const val CHAT_COMPLETIONS = "chatCompletions"
    const val MODELS = "models"
    const val SESSIONS = "sessions"
    const val SESSION_DETAIL = "sessionDetail"
    const val PROFILES = "profiles"
    const val JOBS = "jobs"
}

/**
 * Chunk-kind rawValues on Firestore-relay chunk docs. Must match the
 * Swift `HermesRelayChunkKind` enum (`sse`, `data`, `error`).
 */
object HermesRelayChunkKindWire {
    const val SSE = "sse"
    const val DATA = "data"
    const val ERROR = "error"
}

data class HermesRelayConnectionDescriptor(
    val id: String,
    val displayName: String,
    val relayPublicKey: String,
    val relayKeyVersion: Int? = null,
    val relayEncryption: String = HermesRelayCrypto.ALGORITHM,
    val advertisedModel: String? = null,
    val capabilities: List<String> = emptyList(),
    val status: String = "online",
    val updatedAt: Long? = null,
)

/**
 * Firestore-backed Hermes relay client. Wire-shape identical to the iOS
 * `HermesService` Firestore-relay path so a Mac host can decrypt
 * Android-originated requests and vice-versa.
 *
 * Envelope contract (`users/{uid}/hermes_relay_connections/{id}.*`) for
 * connection discovery:
 *   - `relay_public_key`, `relay_encryption`, `relay_key_version`,
 *     `display_name`, `advertised_model`, `capabilities`, `status`.
 *
 * Envelope contract (`users/{uid}/hermes_relay_requests/{id}.*`) for
 * outbound requests:
 *   - `id`, `connectionId`, `operation`, `method`, `status`,
 *     `relayEncryption`, `relayKeyVersion`, `payloadCiphertext`,
 *     `wrappedKey`, `chunkCount`, `createdAt`, `updatedAt`, `expiresAt`,
 *     `expireAt`, `schemaVersion=2`.
 *
 * Response chunks live in `.../{requestId}/chunks/{seq}` with fields
 * `requestId`, `sequence`, `kind` (`sse`|`data`|`error`), `ciphertext`,
 * `schemaVersion`.
 */
class HermesRelayClient(
    private val keyStore: HermesRelayKeyStore,
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
) {

    fun isUsable(): Boolean {
        val uid = auth.currentUser?.uid ?: return false
        if (uid.isBlank()) return false
        return runCatching { keyStore.clientPublicKeyX963().size == 65 }.getOrDefault(false)
    }

    suspend fun listConnections(): List<HermesRelayConnectionDescriptor> {
        val uid = auth.currentUser?.uid
            ?: throw HermesRelayException("Sign in to Firebase to use Hermes relay.")
        val snapshot = firestore.collection("users").document(uid)
            .collection("hermes_relay_connections")
            .get()
            .await()
        return snapshot.documents.mapNotNull { doc ->
            val publicKey = doc.getString("relay_public_key") ?: return@mapNotNull null
            HermesRelayConnectionDescriptor(
                id = doc.id,
                displayName = doc.getString("display_name") ?: "Hermes relay",
                relayPublicKey = publicKey,
                relayKeyVersion = doc.getLong("relay_key_version")?.toInt(),
                relayEncryption = doc.getString("relay_encryption") ?: HermesRelayCrypto.ALGORITHM,
                advertisedModel = doc.getString("advertised_model"),
                capabilities = (doc.get("capabilities") as? List<*>)?.mapNotNull { it as? String }
                    ?: emptyList(),
                status = doc.getString("status") ?: "online",
                updatedAt = doc.getTimestamp("updated_at")?.toDate()?.time,
            )
        }
    }

    suspend fun sendUnary(
        connection: HermesRelayConnectionDescriptor,
        operation: String,
        method: String,
        path: String,
        body: ByteArray = ByteArray(0),
        sessionId: String? = null,
    ): String {
        val handle = sendEnvelope(connection, operation, method, path, body, sessionId)
        val fragments = sortedMapOf<Int, String>()
        poll(handle = handle) { chunk ->
            when (chunk.kind) {
                HermesRelayChunkKindWire.ERROR -> throw HermesRelayException(chunk.text)
                HermesRelayChunkKindWire.SSE, HermesRelayChunkKindWire.DATA ->
                    fragments[chunk.sequence] = chunk.text
            }
        }
        return fragments.values.joinToString("")
    }

    suspend fun sendStreaming(
        connection: HermesRelayConnectionDescriptor,
        operation: String,
        method: String,
        path: String,
        body: ByteArray,
        sessionId: String? = null,
        onChunk: suspend (kind: String, text: String) -> Unit,
    ) {
        val handle = sendEnvelope(connection, operation, method, path, body, sessionId)
        poll(handle = handle) { chunk ->
            when (chunk.kind) {
                HermesRelayChunkKindWire.ERROR -> throw HermesRelayException(chunk.text)
                else -> onChunk(chunk.kind, chunk.text)
            }
        }
    }

    /** Returns a handle holding the symmetric `keyData` so polling can decrypt chunks. */
    private suspend fun sendEnvelope(
        connection: HermesRelayConnectionDescriptor,
        operation: String,
        method: String,
        path: String,
        body: ByteArray,
        sessionId: String?,
    ): RelayRequestHandle {
        val uid = auth.currentUser?.uid
            ?: throw HermesRelayException("Iroh relay requires a signed-in Firebase user.")
        val requestId = "relay_${UUID.randomUUID().toString().lowercase()}"
        val now = System.currentTimeMillis()
        val expiresAt = now + DEFAULT_TIMEOUT_MILLIS + 30_000L

        val keyData = HermesRelayCrypto.generateSymmetricKey()
        val bodyString = if (body.isNotEmpty()) String(body, Charsets.UTF_8) else null
        val plaintext = JSONObject().apply {
            put("path", path)
            sessionId?.let { put("sessionId", it) }
            bodyString?.let { put("body", it) }
        }.toString().toByteArray(Charsets.UTF_8)

        val requestAad = HermesRelayCrypto.requestAAD(uid, connection.id, requestId)
        val keyAad = HermesRelayCrypto.keyAAD(uid, connection.id, requestId)
        val relayPubBytes = Base64.decode(connection.relayPublicKey, Base64.NO_WRAP)
        val payloadCiphertextB64 = HermesRelayCrypto.sealToBase64(plaintext, keyData, requestAad)
        val wrappedKeyB64 = HermesRelayCrypto.wrapSymmetricKey(keyData, relayPubBytes, keyAad)

        val envelope = mapOf(
            "id" to requestId,
            "connectionId" to connection.id,
            "operation" to operation,
            "method" to method.uppercase(),
            "status" to "pending",
            "payloadCiphertext" to payloadCiphertextB64,
            "wrappedKey" to wrappedKeyB64,
            "relayEncryption" to (connection.relayEncryption.ifBlank { HermesRelayCrypto.ALGORITHM }),
            "relayKeyVersion" to (connection.relayKeyVersion ?: HermesRelayCrypto.KEY_VERSION),
            "chunkCount" to 0,
            "createdAt" to ISO8601.format(Instant.ofEpochMilli(now)),
            "updatedAt" to ISO8601.format(Instant.ofEpochMilli(now)),
            "expiresAt" to ISO8601.format(Instant.ofEpochMilli(expiresAt)),
            "expireAt" to Timestamp(Date(expiresAt)),
            "schemaVersion" to 2,
        )

        firestore.collection("users").document(uid)
            .collection("hermes_relay_requests").document(requestId)
            .set(envelope)
            .await()

        return RelayRequestHandle(uid = uid, requestId = requestId, connectionId = connection.id, keyData = keyData)
    }

    private data class DecryptedChunk(val kind: String, val sequence: Int, val text: String)

    private suspend fun poll(handle: RelayRequestHandle, onChunk: suspend (DecryptedChunk) -> Unit) {
        val requestRef = firestore.collection("users").document(handle.uid)
            .collection("hermes_relay_requests").document(handle.requestId)
        val deadline = System.currentTimeMillis() + DEFAULT_TIMEOUT_MILLIS
        var lastSequence = -1
        while (System.currentTimeMillis() < deadline) {
            val chunks = requestRef.collection("chunks")
                .whereGreaterThan("sequence", lastSequence)
                .orderBy("sequence", Query.Direction.ASCENDING)
                .get()
                .await()
                .documents
            for (doc in chunks) {
                val sequence = doc.getLong("sequence")?.toInt() ?: continue
                val kindText = doc.getString("kind") ?: continue
                val ciphertext = doc.getString("ciphertext") ?: continue
                val aad = HermesRelayCrypto.chunkAAD(
                    uid = handle.uid,
                    connectionId = handle.connectionId,
                    requestId = handle.requestId,
                    sequence = sequence,
                    kind = kindText,
                )
                val plain = HermesRelayCrypto.openBase64(ciphertext, handle.keyData, aad)
                onChunk(DecryptedChunk(kind = kindText, sequence = sequence, text = String(plain, Charsets.UTF_8)))
                lastSequence = maxOf(lastSequence, sequence)
            }

            val request = requestRef.get().await()
            val status = request.getString("status")
            when (status) {
                "completed" -> {
                    val expectedCount = request.getLong("chunkCount")?.toInt() ?: 0
                    if (expectedCount == 0 || lastSequence + 1 >= expectedCount) return
                }
                "failed" -> throw HermesRelayException(request.getString("error") ?: "Remote Hermes relay failed.")
                "cancelled", "expired" -> throw HermesRelayException("Remote Hermes relay request was $status.")
                else -> Unit
            }
            delay(POLL_INTERVAL_MILLIS)
        }
        runCatching {
            requestRef.set(mapOf("status" to "cancelled", "updatedAt" to ISO8601.format(Instant.now())), com.google.firebase.firestore.SetOptions.merge()).await()
        }
        throw HermesRelayException("Hermes relay timed out waiting for a response.")
    }

    private data class RelayRequestHandle(
        val uid: String,
        val requestId: String,
        val connectionId: String,
        val keyData: ByteArray,
    )

    companion object {
        private const val DEFAULT_TIMEOUT_MILLIS = 30_000L
        private const val POLL_INTERVAL_MILLIS = 350L
        private val ISO8601: DateTimeFormatter = DateTimeFormatter.ISO_INSTANT
    }
}
