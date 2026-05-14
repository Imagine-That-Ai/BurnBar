package com.openburnbar.data.assistants

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import kotlinx.coroutines.tasks.await
import java.time.Instant
import java.util.UUID

class CLIAgentMissionDispatcher(
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
) {
    suspend fun dispatch(title: String, prompt: String, missionKind: String): String {
        val uid = auth.currentUser?.uid ?: throw DispatchException("Sign in before dispatching Mac agent missions.")
        val trimmedPrompt = prompt.trim()
        if (trimmedPrompt.isBlank()) throw DispatchException("Mission prompt was empty.")

        val id = UUID.randomUUID().toString()
        val payload = mapOf(
            "id" to id,
            "title" to title.trim().ifBlank { "Insights mission" },
            "prompt" to trimmedPrompt,
            "missionKind" to missionKind,
            "requestedRuntime" to "auto",
            "source" to "android-insights",
            "status" to "pending",
            "createdAt" to Instant.now().toString(),
            "updatedAt" to FieldValue.serverTimestamp(),
            "schemaVersion" to 1,
        )
        firestore.collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(id)
            .set(payload)
            .await()
        return id
    }
}

class DispatchException(message: String) : Exception(message)
