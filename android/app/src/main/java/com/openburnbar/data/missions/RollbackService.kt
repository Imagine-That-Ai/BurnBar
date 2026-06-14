package com.openburnbar.data.missions

import com.google.firebase.FirebaseException
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.firebase.CloudVaultSealedTextCodec
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

// MARK: - Rollback Service (Android parity, Hermes Square §6.10)
//
// Mirrors the iOS `RollbackService`: listens to
// `users/{uid}/cli_sessions/{sessionID}/snapshots`, exposes a
// `StateFlow<Map<String, List<RollbackSnapshot>>>`, and offers
// `submit(...)` which writes a rollback request to
// `users/{uid}/rollback_requests/{id}` for the Mac to claim.

data class RollbackSnapshot(
    val id: String,
    val sessionID: String,
    val sequence: Int,
    val takenAtEpoch: Long,
    val actionLabel: String,
    val touchedFiles: List<String>,
    val macSnapshotPath: String?,
    val restoredAtEpoch: Long?,
)

sealed class RollbackScope {
    object FullSession : RollbackScope()

    data class LastN(val count: Int) : RollbackScope()

    data class SingleFile(val path: String) : RollbackScope()

    val token: String
        get() =
            when (this) {
                FullSession -> "full_session"
                is LastN -> "last_$count"
                is SingleFile -> "file"
            }

    val asJson: String
        get() =
            when (this) {
                FullSession -> "{\"kind\":\"fullSession\"}"
                is LastN -> "{\"kind\":\"lastN\",\"count\":$count}"
                is SingleFile -> "{\"kind\":\"singleFile\",\"path\":${com.openburnbar.data.missions.jsonString(path)}}"
            }
}

data class RollbackRequest(
    val id: String,
    val sessionID: String,
    val scope: RollbackScope,
    val requestedAtEpoch: Long,
    val requestedBy: String,
    val status: Status,
    val resolvedAtEpoch: Long?,
    val errorMessage: String?,
) {
    enum class Status(val token: String) {
        PENDING("pending"),
        IN_FLIGHT("in_flight"),
        COMPLETED("completed"),
        FAILED("failed"),
        CANCELLED("cancelled"),
        ;

        companion object {
            fun fromToken(token: String?): Status? = when (token) {
                "inFlight" -> IN_FLIGHT
                null -> null
                else -> values().firstOrNull { it.token == token }
            }
        }
    }
}

class RollbackService private constructor(
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
) {
    private val _snapshotsBySession = MutableStateFlow<Map<String, List<RollbackSnapshot>>>(emptyMap())
    val snapshotsBySession: StateFlow<Map<String, List<RollbackSnapshot>>> = _snapshotsBySession.asStateFlow()

    private val _pendingRequests = MutableStateFlow<List<RollbackRequest>>(emptyList())
    val pendingRequests: StateFlow<List<RollbackRequest>> = _pendingRequests.asStateFlow()

    private val _inlineError = MutableStateFlow<String?>(null)
    val inlineError: StateFlow<String?> = _inlineError.asStateFlow()

    private val snapshotRegistrations = ConcurrentHashMap<String, ListenerRegistration>()
    private var requestsRegistration: ListenerRegistration? = null
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun startObservingSession(sessionID: String) {
        if (snapshotRegistrations.containsKey(sessionID)) return
        val uid = auth.currentUser?.uid ?: return
        // Reserve the slot synchronously so concurrent calls don't double-register
        // while the suspend read-key resolves.
        snapshotRegistrations[sessionID] = NoopListenerRegistration
        ioScope.launch {
            // Snapshots seal `sealedActionLabel`/`sealedTouchedFiles`/
            // `sealedMacSnapshotPath` (Mac claimed-device writer). Resolve the read
            // key once so the decoder can open them; legacy plaintext snapshots fall
            // back inside `toRollbackSnapshotOrNull`.
            val vaultKey =
                runCatching {
                    AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore)?.keyData
                }.getOrNull()
            val ref =
                firestore.collection("users").document(uid)
                    .collection("cli_sessions").document(sessionID)
                    .collection("snapshots")
                    .orderBy("sequence")
            val reg =
                ref.addSnapshotListener { snap, error ->
                    if (error != null) {
                        _inlineError.value = error.localizedMessage
                        return@addSnapshotListener
                    }
                    val parsed =
                        snap?.documents.orEmpty().mapNotNull { doc ->
                            doc.data?.toRollbackSnapshotOrNull(documentID = doc.id, sessionID = sessionID, vaultKey = vaultKey)
                        }
                    _snapshotsBySession.value = _snapshotsBySession.value + (sessionID to parsed)
                }
            // Stop-during-resolve removes the placeholder; honor that by dropping
            // the freshly attached listener instead of leaking it.
            if (!snapshotRegistrations.replace(sessionID, NoopListenerRegistration, reg)) {
                reg.remove()
            }
        }
    }

    fun stopObservingSession(sessionID: String) {
        snapshotRegistrations.remove(sessionID)?.remove()
        _snapshotsBySession.value = _snapshotsBySession.value - sessionID
    }

    fun startObservingRequests() {
        if (requestsRegistration != null) return
        val uid = auth.currentUser?.uid ?: return
        // Reserve synchronously to keep the idempotent guard above honest while the
        // suspend read-key resolves.
        requestsRegistration = NoopListenerRegistration
        ioScope.launch {
            // Requests seal `sealedScope` (and, when the Mac claim path lands,
            // `sealedErrorMessage`). Resolve the read key so the decoder can open
            // them; legacy plaintext requests fall back inside
            // `toRollbackRequestOrNull`.
            val vaultKey =
                runCatching {
                    AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore)?.keyData
                }.getOrNull()
            val ref =
                firestore.collection("users").document(uid)
                    .collection("rollback_requests")
                    .whereIn("status", listOf("pending", "in_flight", "inFlight"))
            val reg =
                ref.addSnapshotListener { snap, error ->
                    if (error != null) {
                        _inlineError.value = error.localizedMessage
                        return@addSnapshotListener
                    }
                    val parsed =
                        snap?.documents.orEmpty().mapNotNull { doc ->
                            doc.data?.toRollbackRequestOrNull(documentID = doc.id, vaultKey = vaultKey)
                        }
                    _pendingRequests.value = parsed
                }
            if (requestsRegistration === NoopListenerRegistration) {
                requestsRegistration = reg
            } else {
                // stopAll() ran during resolution — don't leak the listener.
                reg.remove()
            }
        }
    }

    fun stopAll() {
        snapshotRegistrations.values.forEach { it.remove() }
        snapshotRegistrations.clear()
        requestsRegistration?.remove()
        requestsRegistration = null
        _snapshotsBySession.value = emptyMap()
        _pendingRequests.value = emptyList()
    }

    suspend fun submit(sessionID: String, scope: RollbackScope, requestedBy: String): RollbackRequest? {
        val uid =
            auth.currentUser?.uid ?: run {
                _inlineError.value = "Sign in to submit rollback requests."
                return null
            }
        val id = UUID.randomUUID().toString()
        val now = Instant.now()
        val request =
            RollbackRequest(
                id = id,
                sessionID = sessionID,
                scope = scope,
                requestedAtEpoch = now.toEpochMilli(),
                requestedBy = requestedBy,
                status = RollbackRequest.Status.PENDING,
                resolvedAtEpoch = null,
                errorMessage = null,
            )
        // Seal the scope JSON (which embeds an absolute file path for `singleFile`
        // scope) with the Cloud Vault key, mirroring the iOS writer. Do not fall
        // back to plaintext when this device is not approved; keep the request
        // local and make the user approve the device before cloud sync.
        val vaultKey =
            runCatching {
                AndroidCloudVaultKeyAccess.keyForWriting(uid = uid, firestore = firestore).keyData
            }.getOrElse { error ->
                _inlineError.value = error.localizedMessage ?: "Approve this Android device before syncing rollback requests."
                return null
            }
        val payload = sealedRollbackRequestPayload(request, source = "android-hermes-square", vaultKey = vaultKey)
        return try {
            firestore.collection("users").document(uid)
                .collection("rollback_requests").document(id)
                .set(payload)
                .await()
            request
        } catch (e: FirebaseException) {
            _inlineError.value = e.localizedMessage ?: "Rollback request failed."
            null
        }
    }

    companion object {
        @Volatile private var instance: RollbackService? = null

        fun shared(): RollbackService = instance ?: synchronized(this) {
            instance ?: RollbackService().also { instance = it }
        }
    }
}

internal fun sealedRollbackRequestPayload(request: RollbackRequest, source: String, vaultKey: ByteArray): MutableMap<String, Any> = mutableMapOf(
    "id" to request.id,
    "sessionID" to request.sessionID,
    "requestedAt" to Instant.ofEpochMilli(request.requestedAtEpoch).toString(),
    "requestedBy" to request.requestedBy,
    "status" to request.status.token,
    "schemaVersion" to 1,
    "source" to source,
    "sealedScope" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText(request.scope.asJson, vaultKey)),
)

internal fun Map<String, Any?>.toRollbackSnapshotOrNull(documentID: String, sessionID: String, vaultKey: ByteArray? = null): RollbackSnapshot? {
    val sequence = (this["sequence"] as? Number)?.toInt()
    val takenAtIso = this["takenAt"] as? String
    val takenAtEpoch = takenAtIso?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }
    val actionLabel =
        CloudVaultSealedTextCodec.openOrLegacy(this["sealedActionLabel"], vaultKey, this["actionLabel"] as? String)
    if (sequence == null || takenAtEpoch == null || actionLabel == null) return null
    // `sealedTouchedFiles` seals the whole `[String]` array as one JSON string.
    // If the sealed field exists, fail closed instead of falling back to a stale
    // plaintext sibling.
    val touched =
        openSealedStringListOrLegacy(this["sealedTouchedFiles"], vaultKey, this["touchedFiles"])
    val macSnapshotPath =
        CloudVaultSealedTextCodec.openOrLegacy(
            this["sealedMacSnapshotPath"],
            vaultKey,
            this["macSnapshotPath"] as? String,
        )
    val restoredAtIso = this["restoredAt"] as? String
    val restoredAtEpoch = restoredAtIso?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }
    return RollbackSnapshot(
        id = this["id"] as? String ?: documentID,
        sessionID = sessionID,
        sequence = sequence,
        takenAtEpoch = takenAtEpoch,
        actionLabel = actionLabel,
        touchedFiles = touched,
        macSnapshotPath = macSnapshotPath,
        restoredAtEpoch = restoredAtEpoch,
    )
}

internal fun Map<String, Any?>.toRollbackRequestOrNull(documentID: String, vaultKey: ByteArray? = null): RollbackRequest? {
    val sessionID = this["sessionID"] as? String ?: return null
    val scopeJSON =
        CloudVaultSealedTextCodec.openOrLegacy(this["sealedScope"], vaultKey, this["scopeJSON"] as? String)
            ?: return null
    val scope = parseScope(scopeJSON)
    val statusRaw = this["status"] as? String
    val status = RollbackRequest.Status.fromToken(statusRaw) ?: return null
    val requestedAt =
        (this["requestedAt"] as? String)?.let {
            runCatching { Instant.parse(it).toEpochMilli() }.getOrNull()
        } ?: System.currentTimeMillis()
    val resolvedAt =
        (this["resolvedAt"] as? String)?.let {
            runCatching { Instant.parse(it).toEpochMilli() }.getOrNull()
        }
    val requestedBy = this["requestedBy"] as? String ?: "unknown"
    val errorMessage =
        CloudVaultSealedTextCodec.openOrLegacy(this["sealedErrorMessage"], vaultKey, this["errorMessage"] as? String)
    return RollbackRequest(
        id = documentID,
        sessionID = sessionID,
        scope = scope,
        requestedAtEpoch = requestedAt,
        requestedBy = requestedBy,
        status = status,
        resolvedAtEpoch = resolvedAt,
        errorMessage = errorMessage,
    )
}

private fun openSealedStringListOrLegacy(rawSealed: Any?, vaultKey: ByteArray?, rawLegacy: Any?): List<String> {
    if (CloudVaultSealedTextCodec.fromMap(rawSealed as? Map<*, *>) != null) {
        val json = CloudVaultSealedTextCodec.open(rawSealed, vaultKey) ?: return emptyList()
        return runCatching {
            val arr = org.json.JSONArray(json)
            (0 until arr.length()).map { arr.getString(it) }
        }.getOrNull() ?: emptyList()
    }
    return (rawLegacy as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
}

private fun parseScope(json: String): RollbackScope {
    return runCatching {
        val obj = org.json.JSONObject(json)
        when (obj.optString("kind")) {
            "fullSession" -> RollbackScope.FullSession
            "lastN" -> RollbackScope.LastN(obj.optInt("count", 1))
            "singleFile" -> RollbackScope.SingleFile(obj.optString("path"))
            else -> RollbackScope.FullSession
        }
    }.getOrDefault(RollbackScope.FullSession)
}

// Placeholder reservation so the synchronous `startObserving*` idempotency guard
// stays honest while the suspend Cloud Vault read key resolves on `ioScope`.
private object NoopListenerRegistration : ListenerRegistration {
    override fun remove() = Unit
}

internal fun jsonString(raw: String): String {
    val out = StringBuilder("\"")
    for (ch in raw) {
        when (ch) {
            '"' -> out.append("\\\"")
            '\\' -> out.append("\\\\")
            '\b' -> out.append("\\b")
            '\n' -> out.append("\\n")
            '\r' -> out.append("\\r")
            '\t' -> out.append("\\t")
            else -> if (ch < ' ') out.append("\\u%04x".format(ch.code)) else out.append(ch)
        }
    }
    out.append('"')
    return out.toString()
}
