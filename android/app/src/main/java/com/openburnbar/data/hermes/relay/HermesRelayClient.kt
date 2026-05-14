package com.openburnbar.data.hermes.relay

import android.util.Base64
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import kotlinx.coroutines.tasks.await
import org.json.JSONObject
import java.util.UUID

class HermesRelayException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)

object HermesRelayOperationName {
    const val CHAT_COMPLETIONS = "chatCompletions"
    const val MODELS = "models"
    const val SESSIONS = "sessions"
    const val SESSION_DETAIL = "sessionDetail"
    const val PROFILES = "profiles"
    const val JOBS = "jobs"
}

object HermesRelayChunkKind {
    const val STREAM = "stream"
    const val FINAL = "final"
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
    val updatedAt: Long? = null
)

/**
 * Firestore-backed transport. Wire-format identical to the iOS
 * `HermesRelayClient.swift` so a Mac host can decrypt
 * Android-originated requests and vice-versa.
 */
class HermesRelayClient(
    private val keyStore: HermesRelayKeyStore,
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance()
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
                updatedAt = doc.getTimestamp("updated_at")?.toDate()?.time
            )
        }
    }

    suspend fun sendUnary(
        connection: HermesRelayConnectionDescriptor,
        operation: String,
        method: String,
        path: String,
        body: ByteArray = ByteArray(0),
        sessionId: String? = null
    ): String {
        val (envelope, sharedKey, requestId) = buildEnvelope(connection, operation, method, path, body, sessionId)
        val docRef = firestore.collection("users")
            .document(auth.currentUser?.uid ?: throw HermesRelayException("Not signed in."))
            .collection("hermes_relay_requests")
            .document(requestId)
        docRef.set(envelope).await()

        val deadline = System.currentTimeMillis() + DEFAULT_TIMEOUT_MILLIS
        while (System.currentTimeMillis() < deadline) {
            val snap = docRef.get().await()
            val status = snap.getString("status")
            if (status == "error") {
                throw HermesRelayException(snap.getString("error_message") ?: "Hermes relay failed.")
            }
            val nonce = snap.getString("response_nonce")
            val ct = snap.getString("response_ciphertext")
            if (nonce != null && ct != null) {
                val aad = HermesRelayCrypto.aad(operation, requestId, "response")
                val plain = HermesRelayCrypto.open(
                    nonce = Base64.decode(nonce, Base64.NO_WRAP),
                    ciphertext = Base64.decode(ct, Base64.NO_WRAP),
                    key = HermesRelayCrypto.deriveKey(sharedKey, aad),
                    aad = aad
                )
                return String(plain, Charsets.UTF_8)
            }
            kotlinx.coroutines.delay(POLL_INTERVAL_MILLIS)
        }
        throw HermesRelayException("Hermes relay timed out waiting for a response.")
    }

    suspend fun sendStreaming(
        connection: HermesRelayConnectionDescriptor,
        operation: String,
        method: String,
        path: String,
        body: ByteArray,
        sessionId: String? = null,
        onChunk: suspend (kind: String, text: String) -> Unit
    ) {
        val (envelope, sharedKey, requestId) = buildEnvelope(connection, operation, method, path, body, sessionId)
        val streamingEnvelope = envelope.toMutableMap().apply { put("streaming", true) }
        val docRef = firestore.collection("users")
            .document(auth.currentUser?.uid ?: throw HermesRelayException("Not signed in."))
            .collection("hermes_relay_requests")
            .document(requestId)
        docRef.set(streamingEnvelope).await()

        val deadline = System.currentTimeMillis() + DEFAULT_TIMEOUT_MILLIS
        var seen = 0
        while (System.currentTimeMillis() < deadline) {
            val chunks = docRef.collection("chunks")
                .orderBy("seq", Query.Direction.ASCENDING)
                .get()
                .await()
                .documents
            for (chunk in chunks.drop(seen)) {
                val kind = chunk.getString("kind") ?: continue
                val nonce = chunk.getString("nonce") ?: continue
                val ct = chunk.getString("ciphertext") ?: continue
                val seq = chunk.getLong("seq")?.toInt() ?: seen
                val aad = HermesRelayCrypto.aad(operation, requestId, "chunk:$seq")
                val plain = HermesRelayCrypto.open(
                    nonce = Base64.decode(nonce, Base64.NO_WRAP),
                    ciphertext = Base64.decode(ct, Base64.NO_WRAP),
                    key = HermesRelayCrypto.deriveKey(sharedKey, aad),
                    aad = aad
                )
                val text = String(plain, Charsets.UTF_8)
                onChunk(kind, text)
                seen += 1
                if (kind == HermesRelayChunkKind.FINAL || kind == HermesRelayChunkKind.ERROR) {
                    if (kind == HermesRelayChunkKind.ERROR) {
                        throw HermesRelayException(text)
                    }
                    return
                }
            }
            kotlinx.coroutines.delay(POLL_INTERVAL_MILLIS)
        }
        throw HermesRelayException("Hermes relay timed out mid-stream.")
    }

    private fun buildEnvelope(
        connection: HermesRelayConnectionDescriptor,
        operation: String,
        method: String,
        path: String,
        body: ByteArray,
        sessionId: String?
    ): Triple<Map<String, Any?>, ByteArray, String> {
        val requestId = UUID.randomUUID().toString()
        val keyPair = keyStore.loadOrCreateClientKeyPair()
        val relayPublic = HermesRelayCrypto.decodeUncompressedPublicKey(
            Base64.decode(connection.relayPublicKey, Base64.NO_WRAP)
        )
        val shared = HermesRelayCrypto.ecdh(keyPair.private, relayPublic)
        val aad = HermesRelayCrypto.aad(operation, requestId, "request")
        val key = HermesRelayCrypto.deriveKey(shared, aad)

        val plaintext = JSONObject().apply {
            put("method", method)
            put("path", path)
            if (body.isNotEmpty()) {
                put("body", Base64.encodeToString(body, Base64.NO_WRAP))
            }
            sessionId?.let { put("session_id", it) }
        }.toString().toByteArray(Charsets.UTF_8)

        val sealed = HermesRelayCrypto.seal(plaintext, key, aad)
        val clientPub = HermesRelayCrypto.encodeUncompressedPublicKey(
            keyPair.public as java.security.interfaces.ECPublicKey
        )

        val envelope = mapOf(
            "operation" to operation,
            "connection_id" to connection.id,
            "method" to method,
            "path" to path,
            "algorithm" to (connection.relayEncryption.ifBlank { HermesRelayCrypto.ALGORITHM }),
            "client_pub" to Base64.encodeToString(clientPub, Base64.NO_WRAP),
            "key_version" to (connection.relayKeyVersion ?: 1),
            "request_nonce" to Base64.encodeToString(sealed.nonce, Base64.NO_WRAP),
            "request_ciphertext" to Base64.encodeToString(sealed.ciphertext, Base64.NO_WRAP),
            "status" to "pending",
            "created_at" to FieldValue.serverTimestamp(),
            "session_id" to (sessionId ?: "")
        )
        return Triple(envelope, shared, requestId)
    }

    companion object {
        private const val DEFAULT_TIMEOUT_MILLIS = 30_000L
        private const val POLL_INTERVAL_MILLIS = 350L
    }
}
