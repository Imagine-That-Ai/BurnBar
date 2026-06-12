package com.openburnbar.data.hermes.relay

import android.util.Base64
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.cloud.AndroidSignalIdentityKeyStore
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
import com.openburnbar.data.computeruse.RelaySenderKeyPublishRequest
import java.security.KeyPair
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.Date
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.tasks.await
import org.json.JSONObject

class HermesRelayException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)

private const val X963_PUBLIC_KEY_BYTE_COUNT = 65

/**
 * Operation rawValues recognised by the Mac (`HermesRelayOperation` in
 * `OpenBurnBarCore/SharedModels/HermesConnectionTypes.swift`).
 */
object HermesRelayOperationName {
    const val CHAT_COMPLETIONS = "chatCompletions"
    const val CLI_AGENT_CHAT = "cliAgentChat"
    const val CLI_AGENT_MODEL_CATALOG = "cliAgentModelCatalog"
    const val CLI_AGENT_SESSION_ACTION = "cliAgentSessionAction"
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
    val relayEncryption: String = HermesRelayCrypto.ALGORITHM_V3,
    val advertisedModel: String? = null,
    val capabilities: List<String> = emptyList(),
    val status: String = "online",
    val updatedAt: Long? = null,
)

internal fun decodeHermesRelayConnectionDescriptor(documentId: String, data: Map<String, Any?>): HermesRelayConnectionDescriptor? {
    val publicKey = data.stringField("relayPublicKey", "relay_public_key") ?: return null
    return HermesRelayConnectionDescriptor(
        id = data.stringField("id") ?: documentId,
        displayName = data.stringField("displayName", "display_name") ?: "Hermes relay",
        relayPublicKey = publicKey,
        relayKeyVersion = data.longField("relayKeyVersion", "relay_key_version")?.toInt(),
        relayEncryption = data.stringField("relayEncryption", "relay_encryption") ?: HermesRelayCrypto.ALGORITHM,
        advertisedModel = data.stringField("advertisedModel", "advertised_model"),
        capabilities = data.stringListField("capabilities"),
        status = data.stringField("status") ?: "online",
        updatedAt = data.millisField("updatedAt", "updated_at"),
    )
}

private fun Map<String, Any?>.stringField(vararg names: String): String? = names.firstNotNullOfOrNull { name ->
    (this[name] as? String)?.takeIf { it.isNotBlank() }
}

private fun Map<String, Any?>.longField(vararg names: String): Long? = names.firstNotNullOfOrNull { name ->
    when (val value = this[name]) {
        is Number -> value.toLong()
        is String -> value.toLongOrNull()
        else -> null
    }
}

private fun Map<String, Any?>.stringListField(name: String): List<String> = (this[name] as? List<*>)?.mapNotNull { it as? String } ?: emptyList()

private fun Map<String, Any?>.millisField(vararg names: String): Long? = names.firstNotNullOfOrNull { name ->
    when (val value = this[name]) {
        is Timestamp -> value.toDate().time
        is Date -> value.time
        is Number -> value.toLong()
        is String -> runCatching { Instant.parse(value).toEpochMilli() }.getOrNull()
        else -> null
    }
}

/**
 * Firestore-backed Hermes relay client. Wire-shape identical to the iOS
 * `HermesService` Firestore-relay path so a Mac host can decrypt
 * Android-originated requests and vice-versa.
 *
 * Envelope contract (`users/{uid}/hermes_connections/{id}.*`) for
 * connection discovery:
 *   - `relayPublicKey`, `relayEncryption`, `relayKeyVersion`,
 *     `displayName`, `advertisedModel`, `capabilities`, `status`.
 *
 * Envelope contract (`users/{uid}/hermes_relay_requests/{id}.*`) for
 * outbound requests:
 *   - `id`, `connectionId`, `operation`, `method`, `status`,
     *     `relayEncryption`, `relayKeyVersion=3`, `payloadCiphertext`,
     *     `enc`, `wrappedKey`, sender identity metadata, `chunkCount`,
     *     `createdAt`, `updatedAt`, `expiresAt`, `expireAt`, `schemaVersion=2`.
 *
 * Response chunks live in `.../{requestId}/chunks/{seq}` with fields
 * `requestId`, `sequence`, `kind` (`sse`|`data`|`error`), `ciphertext`,
 * `schemaVersion`.
 */
class HermesRelayClient(
    private val keyStore: HermesRelayKeyStore,
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    private val securityCallables: ComputerUseSecurityCallableClient = ComputerUseSecurityCallableClient(),
) {
    fun isUsable(): Boolean {
        val uid = auth.currentUser?.uid ?: return false
        if (uid.isBlank()) return false
        return runCatching { keyStore.clientPublicKeyX963().size == X963_PUBLIC_KEY_BYTE_COUNT }.getOrDefault(false)
    }

    suspend fun listConnections(): List<HermesRelayConnectionDescriptor> {
        val uid =
            auth.currentUser?.uid
                ?: throw HermesRelayException("Sign in to Firebase to use Hermes relay.")
        val snapshot =
            firestore.collection("users").document(uid)
                .collection("hermes_connections")
                .get()
                .await()
        val descriptors =
            snapshot.documents.mapNotNull { doc ->
                decodeHermesRelayConnectionDescriptor(doc.id, doc.data.orEmpty())
            }
        if (descriptors.isNotEmpty()) return descriptors

        // Older Android/Mac betas wrote relay-only docs under this legacy
        // collection. Keep it as a fallback so existing users are not stranded
        // while the canonical Hermes connection schema rolls forward.
        val legacySnapshot =
            firestore.collection("users").document(uid)
                .collection("hermes_relay_connections")
                .get()
                .await()
        return legacySnapshot.documents.mapNotNull { doc ->
            decodeHermesRelayConnectionDescriptor(doc.id, doc.data.orEmpty())
        }
    }

    suspend fun sendUnary(
        connection: HermesRelayConnectionDescriptor,
        operation: String,
        method: String,
        path: String,
        body: ByteArray = ByteArray(0),
        sessionId: String? = null,
        timeoutMillis: Long = DEFAULT_TIMEOUT_MILLIS,
    ): String {
        val handle =
            sendEnvelope(
                RelayEnvelopeRequest(
                    connection = connection,
                    operation = operation,
                    method = method,
                    path = path,
                    body = body,
                    sessionId = sessionId,
                    timeoutMillis = timeoutMillis,
                ),
            )
        val fragments = sortedMapOf<Int, String>()
        poll(handle = handle, timeoutMillis = timeoutMillis) { chunk ->
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
        timeoutMillis: Long = DEFAULT_TIMEOUT_MILLIS,
        onChunk: suspend (kind: String, text: String) -> Unit,
    ) {
        val handle =
            sendEnvelope(
                RelayEnvelopeRequest(
                    connection = connection,
                    operation = operation,
                    method = method,
                    path = path,
                    body = body,
                    sessionId = sessionId,
                    timeoutMillis = timeoutMillis,
                ),
            )
        poll(handle = handle, timeoutMillis = timeoutMillis) { chunk ->
            when (chunk.kind) {
                HermesRelayChunkKindWire.ERROR -> throw HermesRelayException(chunk.text)
                else -> onChunk(chunk.kind, chunk.text)
            }
        }
    }

    /** Returns a handle holding the symmetric `keyData` so polling can decrypt chunks. */
    private data class RelayEnvelopeRequest(
        val connection: HermesRelayConnectionDescriptor,
        val operation: String,
        val method: String,
        val path: String,
        val body: ByteArray,
        val sessionId: String?,
        val timeoutMillis: Long,
    )

    private data class RelayEnvelopeContext(val uid: String, val requestId: String, val now: Long, val expiresAt: Long)

    private data class RelaySenderIdentity(
        val keyPair: KeyPair,
        val publicKeyBase64: String,
        val deviceId: String,
        val peerNodeId: String,
        val keyId: String,
    )

    private data class SealedRelayEnvelopePayload(
        val keyData: ByteArray,
        val payloadCiphertextB64: String,
        val wrapped: HermesRelayCrypto.RelayKeyWrapV3Wire,
    )

    private suspend fun sendEnvelope(request: RelayEnvelopeRequest): RelayRequestHandle {
        ensureRelayConnectionCompatible(request.connection)
        val context = relayEnvelopeContext(request.timeoutMillis)
        val plaintext = relayRequestPlaintext(request)
        val sender = publishRelaySenderIdentity(context.uid, context.now)
        val senderCounter = keyStore.nextAuthenticatedSenderCounter(request.connection.id, sender.keyId)
        val sealedPayload = sealRelayPayload(context, request, plaintext, sender, senderCounter)
        writeRelayEnvelope(context, request, sender, senderCounter, sealedPayload)
        return RelayRequestHandle(
            uid = context.uid,
            requestId = context.requestId,
            connectionId = request.connection.id,
            keyData = sealedPayload.keyData,
        )
    }

    private fun relayEnvelopeContext(timeoutMillis: Long): RelayEnvelopeContext {
        val uid =
            auth.currentUser?.uid
                ?: throw HermesRelayException("Iroh relay requires a signed-in Firebase user.")
        val now = System.currentTimeMillis()
        return RelayEnvelopeContext(
            uid = uid,
            requestId = "relay_${UUID.randomUUID().toString().lowercase()}",
            now = now,
            expiresAt = HermesRelayTimeouts.expiresAtMillis(now, timeoutMillis),
        )
    }

    private fun ensureRelayConnectionCompatible(connection: HermesRelayConnectionDescriptor) {
        if (connection.relayEncryption != HermesRelayCrypto.ALGORITHM_V3 ||
            connection.relayKeyVersion != HermesRelayCrypto.KEY_VERSION_V3
        ) {
            throw HermesRelayException("Update OpenBurnBar on your Mac before using authenticated Android relay control.")
        }
    }

    private fun relayRequestPlaintext(request: RelayEnvelopeRequest): ByteArray {
        val bodyString = if (request.body.isNotEmpty()) String(request.body, Charsets.UTF_8) else null
        return JSONObject().apply {
            put("path", request.path)
            request.sessionId?.let { put("sessionId", it) }
            bodyString?.let { put("body", it) }
        }.toString().toByteArray(Charsets.UTF_8)
    }

    private suspend fun publishRelaySenderIdentity(uid: String, now: Long): RelaySenderIdentity {
        val senderKeyPair = keyStore.loadOrCreateClientKeyPair()
        val senderPublicKeyX963 = keyStore.clientPublicKeyX963()
        val senderPublicKeyBase64 = Base64.encodeToString(senderPublicKeyX963, Base64.NO_WRAP)
        val senderDevice = AndroidCloudVaultDeviceKeypair.loadOrCreate()
        val senderDeviceId = senderDevice.deviceId
        val senderPeerNodeId = senderDeviceId
        val keyId = relaySenderKeyId(senderPublicKeyX963)
        val signalIdentity = AndroidSignalIdentityKeyStore.loadOrCreate(senderDeviceId, senderDevice.keyVersion)
        AndroidSignalIdentityKeyStore.publishIfNeeded(
            uid = uid,
            deviceId = senderDeviceId,
            identity = signalIdentity,
            firestore = firestore,
        )
        securityCallables.publishRelaySenderKey(
            RelaySenderKeyPublishRequest(
                deviceId = senderDeviceId,
                peerNodeId = senderPeerNodeId,
                keyId = keyId,
                publicKeyBase64 = senderPublicKeyBase64,
                relayKeyVersion = HermesRelayCrypto.KEY_VERSION_V3,
                publishedAtMillis = now,
                signalIdentityKeyId = signalIdentity.identityKeyId,
                signalIdentityKeyVersion = signalIdentity.keyVersion,
                signalIdentityPublicKeyFingerprint = CloudVaultCrypto.sha256Base64(signalIdentity.publicKeyData),
            ),
        )
        return RelaySenderIdentity(
            keyPair = senderKeyPair,
            publicKeyBase64 = senderPublicKeyBase64,
            deviceId = senderDeviceId,
            peerNodeId = senderPeerNodeId,
            keyId = keyId,
        )
    }

    private fun sealRelayPayload(
        context: RelayEnvelopeContext,
        request: RelayEnvelopeRequest,
        plaintext: ByteArray,
        sender: RelaySenderIdentity,
        senderCounter: Long,
    ): SealedRelayEnvelopePayload {
        val requestAad =
            HermesRelayCrypto.authenticatedRequestAAD(
                uid = context.uid,
                connectionId = request.connection.id,
                requestId = context.requestId,
                operation = request.operation,
                senderDeviceId = sender.deviceId,
                senderPeerNodeId = sender.peerNodeId,
                senderCounter = senderCounter,
                keyId = sender.keyId,
            )
        val keyAad =
            HermesRelayCrypto.authenticatedKeyAAD(
                uid = context.uid,
                connectionId = request.connection.id,
                requestId = context.requestId,
                operation = request.operation,
                senderDeviceId = sender.deviceId,
                senderPeerNodeId = sender.peerNodeId,
                senderCounter = senderCounter,
                keyId = sender.keyId,
            )
        val keyData = HermesRelayCrypto.generateSymmetricKey()
        val relayPubBytes = Base64.decode(request.connection.relayPublicKey, Base64.NO_WRAP)
        val payloadCiphertextB64 = HermesRelayCrypto.sealToBase64(plaintext, keyData, requestAad)
        val wrapped = HermesRelayCrypto.wrapSymmetricKeyV3(keyData, relayPubBytes, sender.keyPair.private, keyAad)
        return SealedRelayEnvelopePayload(
            keyData = keyData,
            payloadCiphertextB64 = payloadCiphertextB64,
            wrapped = wrapped,
        )
    }

    private suspend fun writeRelayEnvelope(
        context: RelayEnvelopeContext,
        request: RelayEnvelopeRequest,
        sender: RelaySenderIdentity,
        senderCounter: Long,
        sealedPayload: SealedRelayEnvelopePayload,
    ) {
        val envelope =
            mapOf(
                "id" to context.requestId,
                "connectionId" to request.connection.id,
                "operation" to request.operation,
                "method" to request.method.uppercase(),
                "status" to "pending",
                "payloadCiphertext" to sealedPayload.payloadCiphertextB64,
                "enc" to sealedPayload.wrapped.enc,
                "wrappedKey" to sealedPayload.wrapped.wrappedKey,
                "relayEncryption" to HermesRelayCrypto.ALGORITHM_V3,
                "relayKeyVersion" to HermesRelayCrypto.KEY_VERSION_V3,
                "senderPublicKey" to sender.publicKeyBase64,
                "senderDeviceId" to sender.deviceId,
                "senderPeerNodeId" to sender.peerNodeId,
                "senderCounter" to senderCounter,
                "keyId" to sender.keyId,
                "chunkCount" to 0,
                "createdAt" to ISO8601.format(Instant.ofEpochMilli(context.now)),
                "updatedAt" to ISO8601.format(Instant.ofEpochMilli(context.now)),
                "expiresAt" to ISO8601.format(Instant.ofEpochMilli(context.expiresAt)),
                "expireAt" to Timestamp(Date(context.expiresAt)),
                "schemaVersion" to 2,
            )

        firestore.collection("users").document(context.uid)
            .collection("hermes_relay_requests").document(context.requestId)
            .set(envelope)
            .await()
    }

    private fun relaySenderKeyId(publicKeyX963: ByteArray): String =
        RelaySealSenderIdentity.relaySenderKeyId(publicKeyX963)

    private data class DecryptedChunk(val kind: String, val sequence: Int, val text: String)

    private fun relayPollTerminalError(status: String?, errorMessage: String?): HermesRelayException? =
        when (status) {
            "failed" -> HermesRelayException(errorMessage ?: "Remote Hermes relay failed.")
            "cancelled", "expired" -> HermesRelayException("Remote Hermes relay request was $status.")
            else -> null
        }

    private suspend fun poll(handle: RelayRequestHandle, timeoutMillis: Long, onChunk: suspend (DecryptedChunk) -> Unit) {
        val requestRef =
            firestore.collection("users").document(handle.uid)
                .collection("hermes_relay_requests").document(handle.requestId)
        val deadline = HermesRelayTimeouts.deadlineMillis(System.currentTimeMillis(), timeoutMillis)
        var lastSequence = -1
        while (System.currentTimeMillis() < deadline) {
            val chunks =
                requestRef.collection("chunks")
                    .whereGreaterThan("sequence", lastSequence)
                    .orderBy("sequence", Query.Direction.ASCENDING)
                    .get()
                    .await()
                    .documents
            for (doc in chunks) {
                val sequence = doc.getLong("sequence")?.toInt()
                val kindText = doc.getString("kind")
                val ciphertext = doc.getString("ciphertext")
                if (sequence != null && kindText != null && ciphertext != null) {
                    val aad =
                        HermesRelayCrypto.chunkAAD(
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
            }

            val request = requestRef.get().await()
            val status = request.getString("status")
            val terminalError = relayPollTerminalError(status, request.getString("error"))
            if (terminalError != null) throw terminalError
            when (status) {
                "completed" -> {
                    val expectedCount = request.getLong("chunkCount")?.toInt() ?: 0
                    if (expectedCount == 0 || lastSequence + 1 >= expectedCount) return
                }
                else -> Unit
            }
            delay(POLL_INTERVAL_MILLIS)
        }
        runCatching {
            requestRef.set(
                mapOf("status" to "cancelled", "updatedAt" to ISO8601.format(Instant.now())),
                com.google.firebase.firestore.SetOptions.merge(),
            ).await()
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
        private const val DEFAULT_TIMEOUT_MILLIS = HermesRelayTimeouts.DEFAULT_TIMEOUT_MILLIS
        private const val POLL_INTERVAL_MILLIS = 350L
        private val ISO8601: DateTimeFormatter = DateTimeFormatter.ISO_INSTANT
    }
}

internal object HermesRelayTimeouts {
    internal const val DEFAULT_TIMEOUT_MILLIS = 30_000L
    private const val EXPIRATION_GRACE_MILLIS = 30_000L

    fun effectiveTimeoutMillis(timeoutMillis: Long): Long = timeoutMillis.takeIf { it > 0 } ?: DEFAULT_TIMEOUT_MILLIS

    fun deadlineMillis(nowMillis: Long, timeoutMillis: Long): Long = nowMillis + effectiveTimeoutMillis(timeoutMillis)

    fun expiresAtMillis(nowMillis: Long, timeoutMillis: Long): Long = deadlineMillis(nowMillis, timeoutMillis) + EXPIRATION_GRACE_MILLIS
}
