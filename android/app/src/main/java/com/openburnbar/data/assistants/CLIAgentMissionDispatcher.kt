package com.openburnbar.data.assistants

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await
import java.time.Instant
import java.util.UUID

class CLIAgentMissionDispatcher(
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
) {
    suspend fun dispatch(
        title: String,
        prompt: String,
        missionKind: String,
        requestedRuntime: String = "auto",
    ): String {
        val uid = auth.currentUser?.uid ?: throw DispatchException("Sign in before dispatching Mac agent missions.")
        val trimmedPrompt = prompt.trim()
        if (trimmedPrompt.isBlank()) throw DispatchException("Mission prompt was empty.")

        val id = UUID.randomUUID().toString()
        val payload = mapOf(
            "id" to id,
            "title" to title.trim().ifBlank { "Insights mission" },
            "prompt" to trimmedPrompt,
            "missionKind" to missionKind,
            "requestedRuntime" to requestedRuntime,
            "source" to "android-insights",
            "status" to "pending",
            "liveSummary" to "Mission queued from this device. Waiting for the signed-in Mac agent listener to claim it.",
            "events" to listOf(
                mapOf(
                    "timestamp" to Instant.now().toString(),
                    "phase" to "queued",
                    "message" to "Mission queued from this device.",
                    "source" to "android",
                )
            ),
            "createdAt" to Instant.now().toString(),
            "updatedAt" to FieldValue.serverTimestamp(),
            "schemaVersion" to 2,
        )
        firestore.collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(id)
            .set(payload)
            .await()
        return id
    }

    fun observe(requestID: String): Flow<CLIAgentMissionSnapshot> = callbackFlow {
        val uid = auth.currentUser?.uid
        if (uid == null) {
            close(DispatchException("Sign in before watching Mac agent missions."))
            return@callbackFlow
        }
        val registration = firestore.collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(requestID)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    close(error)
                    return@addSnapshotListener
                }
                val mission = snapshot?.toMissionSnapshot(requestID)
                if (mission != null) trySend(mission)
            }
        awaitClose { registration.remove() }
    }
}

class DispatchException(message: String) : Exception(message)

data class CLIAgentMissionSnapshot(
    val id: String,
    val title: String,
    val status: String,
    val requestedRuntime: String,
    val selectedRuntime: String?,
    val selectedRuntimeName: String?,
    val liveSummary: String?,
    val resultPreview: String?,
    val errorMessage: String?,
    val sessionID: String?,
    val events: List<CLIAgentMissionEvent>,
) {
    val runtimeLabel: String
        get() = selectedRuntimeName ?: selectedRuntime ?: if (requestedRuntime == "auto") "Mac agent fleet" else requestedRuntime

    val isTerminal: Boolean
        get() = status == "completed" || status == "failed"
}

data class CLIAgentMissionEvent(
    val timestamp: String,
    val phase: String,
    val message: String,
    val runtime: String?,
    val source: String?,
)

private fun DocumentSnapshot.toMissionSnapshot(fallbackID: String): CLIAgentMissionSnapshot? {
    val title = getString("title") ?: return null
    val status = getString("status") ?: return null
    val rawEvents = get("events") as? List<*> ?: emptyList<Any>()
    return CLIAgentMissionSnapshot(
        id = getString("id") ?: fallbackID,
        title = title,
        status = status,
        requestedRuntime = getString("requestedRuntime") ?: "auto",
        selectedRuntime = getString("selectedRuntime"),
        selectedRuntimeName = getString("selectedRuntimeName"),
        liveSummary = getString("liveSummary"),
        resultPreview = getString("resultPreview"),
        errorMessage = getString("errorMessage"),
        sessionID = getString("sessionId"),
        events = rawEvents.mapNotNull { raw ->
            val map = raw as? Map<*, *> ?: return@mapNotNull null
            CLIAgentMissionEvent(
                timestamp = map["timestamp"] as? String ?: return@mapNotNull null,
                phase = map["phase"] as? String ?: return@mapNotNull null,
                message = map["message"] as? String ?: return@mapNotNull null,
                runtime = map["runtime"] as? String,
                source = map["source"] as? String,
            )
        },
    )
}
