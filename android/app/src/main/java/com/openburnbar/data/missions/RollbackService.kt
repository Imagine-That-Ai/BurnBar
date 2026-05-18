package com.openburnbar.data.missions

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Query
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.tasks.await
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

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
        get() = when (this) {
            FullSession -> "full_session"
            is LastN -> "last_${count}"
            is SingleFile -> "file"
        }

    val asJson: String
        get() = when (this) {
            FullSession -> "{\"kind\":\"fullSession\"}"
            is LastN -> "{\"kind\":\"lastN\",\"count\":${count}}"
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
        PENDING("pending"), IN_FLIGHT("in_flight"), COMPLETED("completed"), FAILED("failed"), CANCELLED("cancelled");
        companion object {
            fun fromToken(token: String?): Status =
                values().firstOrNull { it.token == token } ?: PENDING
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

    fun startObservingSession(sessionID: String) {
        if (snapshotRegistrations.containsKey(sessionID)) return
        val uid = auth.currentUser?.uid ?: return
        val ref = firestore.collection("users").document(uid)
            .collection("cli_sessions").document(sessionID)
            .collection("snapshots")
            .orderBy("sequence")
        val reg = ref.addSnapshotListener { snap, error ->
            if (error != null) {
                _inlineError.value = error.localizedMessage
                return@addSnapshotListener
            }
            val parsed = snap?.documents.orEmpty().mapNotNull { doc ->
                doc.data?.toRollbackSnapshotOrNull(documentID = doc.id, sessionID = sessionID)
            }
            _snapshotsBySession.value = _snapshotsBySession.value + (sessionID to parsed)
        }
        snapshotRegistrations[sessionID] = reg
    }

    fun stopObservingSession(sessionID: String) {
        snapshotRegistrations.remove(sessionID)?.remove()
        _snapshotsBySession.value = _snapshotsBySession.value - sessionID
    }

    fun startObservingRequests() {
        if (requestsRegistration != null) return
        val uid = auth.currentUser?.uid ?: return
        val ref = firestore.collection("users").document(uid)
            .collection("rollback_requests")
            .whereIn("status", listOf("pending", "in_flight"))
        requestsRegistration = ref.addSnapshotListener { snap, error ->
            if (error != null) {
                _inlineError.value = error.localizedMessage
                return@addSnapshotListener
            }
            val parsed = snap?.documents.orEmpty().mapNotNull { doc ->
                doc.data?.toRollbackRequestOrNull(documentID = doc.id)
            }
            _pendingRequests.value = parsed
        }
    }

    fun stopAll() {
        snapshotRegistrations.values.forEach { it.remove() }
        snapshotRegistrations.clear()
        requestsRegistration?.remove(); requestsRegistration = null
        _snapshotsBySession.value = emptyMap()
        _pendingRequests.value = emptyList()
    }

    suspend fun submit(sessionID: String, scope: RollbackScope, requestedBy: String): RollbackRequest? {
        val uid = auth.currentUser?.uid ?: run {
            _inlineError.value = "Sign in to submit rollback requests."
            return null
        }
        val id = UUID.randomUUID().toString()
        val now = Instant.now()
        val request = RollbackRequest(
            id = id,
            sessionID = sessionID,
            scope = scope,
            requestedAtEpoch = now.toEpochMilli(),
            requestedBy = requestedBy,
            status = RollbackRequest.Status.PENDING,
            resolvedAtEpoch = null,
            errorMessage = null,
        )
        val payload = mapOf<String, Any>(
            "id" to id,
            "sessionID" to sessionID,
            "scopeJSON" to scope.asJson,
            "requestedAt" to now.toString(),
            "requestedBy" to requestedBy,
            "status" to "pending",
            "schemaVersion" to 1,
            "source" to "android-hermes-square",
        )
        return try {
            firestore.collection("users").document(uid)
                .collection("rollback_requests").document(id)
                .set(payload)
                .await()
            request
        } catch (e: Exception) {
            _inlineError.value = e.localizedMessage ?: "Rollback request failed."
            null
        }
    }

    companion object {
        @Volatile private var instance: RollbackService? = null

        fun shared(): RollbackService =
            instance ?: synchronized(this) {
                instance ?: RollbackService().also { instance = it }
            }
    }
}

private fun Map<String, Any?>.toRollbackSnapshotOrNull(documentID: String, sessionID: String): RollbackSnapshot? {
    val sequence = (this["sequence"] as? Number)?.toInt() ?: return null
    val takenAtIso = this["takenAt"] as? String ?: return null
    val takenAtEpoch = runCatching { Instant.parse(takenAtIso).toEpochMilli() }.getOrNull() ?: return null
    val actionLabel = this["actionLabel"] as? String ?: return null
    val touched = (this["touchedFiles"] as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
    val macPath = this["macSnapshotPath"] as? String
    val restoredAtIso = this["restoredAt"] as? String
    val restoredAtEpoch = restoredAtIso?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }
    return RollbackSnapshot(
        id = (this["id"] as? String) ?: documentID,
        sessionID = sessionID,
        sequence = sequence,
        takenAtEpoch = takenAtEpoch,
        actionLabel = actionLabel,
        touchedFiles = touched,
        macSnapshotPath = macPath,
        restoredAtEpoch = restoredAtEpoch,
    )
}

private fun Map<String, Any?>.toRollbackRequestOrNull(documentID: String): RollbackRequest? {
    val sessionID = this["sessionID"] as? String ?: return null
    val scopeJSON = this["scopeJSON"] as? String ?: "{\"kind\":\"fullSession\"}"
    val scope = parseScope(scopeJSON)
    val statusRaw = this["status"] as? String
    val status = RollbackRequest.Status.fromToken(statusRaw)
    val requestedAt = (this["requestedAt"] as? String)?.let {
        runCatching { Instant.parse(it).toEpochMilli() }.getOrNull()
    } ?: System.currentTimeMillis()
    val resolvedAt = (this["resolvedAt"] as? String)?.let {
        runCatching { Instant.parse(it).toEpochMilli() }.getOrNull()
    }
    val requestedBy = (this["requestedBy"] as? String) ?: "unknown"
    val errorMessage = this["errorMessage"] as? String
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
