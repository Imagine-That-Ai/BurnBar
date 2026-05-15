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
    /**
     * Hermes Square §6.4 — fan-out dispatch. Writes one mission group
     * parent + N child cli_agent_mission_requests linked by `groupID`.
     * Mirrors the iOS `dispatchFanOut`. Throws DispatchException on
     * malformed input or auth failure.
     */
    suspend fun dispatchFanOut(
        title: String,
        prompt: String,
        missionKind: String,
        runtimeTokens: List<String>,
        targetProject: String? = null,
        depth: String = "standard",
        approvalMode: String = "existing_policy",
        commandsAllowed: Boolean = false,
        fileEditsAllowed: Boolean = false,
        parallelismLimit: Int? = null,
        mergeStrategy: String = "pick_one",
    ): FanOutDispatchResult {
        val uid = auth.currentUser?.uid
            ?: throw DispatchException("Sign in before dispatching Mac agent missions.")
        if (runtimeTokens.size < 2) throw DispatchException("Fan-out dispatch needs at least 2 runtimes.")
        val trimmedPrompt = prompt.trim()
        if (trimmedPrompt.isBlank()) throw DispatchException("Mission prompt was empty.")

        val groupID = "grp-${UUID.randomUUID()}"
        val trimmedTitle = title.trim().ifBlank { "Fan-out mission" }
        val childMissionIDs = runtimeTokens.map { UUID.randomUUID().toString() }
        val plim = (parallelismLimit ?: runtimeTokens.size).coerceAtLeast(1)
        val now = Instant.now().toString()

        val groupRef = firestore.collection("users").document(uid)
            .collection("mission_groups").document(groupID)
        val batch = firestore.batch()

        val groupPayload: Map<String, Any> = mapOf(
            "id" to groupID,
            "title" to trimmedTitle,
            "prompt" to trimmedPrompt,
            "missionKind" to missionKind,
            "targetProject" to (targetProject ?: ""),
            "childMissionIDs" to childMissionIDs,
            "runtimeTokens" to runtimeTokens,
            "parallelismLimit" to plim,
            "mergeStrategy" to mergeStrategy,
            "phase" to "queued",
            "winnerMissionID" to "",
            "forecast" to mapOf(
                "tokensLow" to 0,
                "tokensHigh" to 0,
                "costLowUSD" to 0.0,
                "costHighUSD" to 0.0,
                "etaLow" to 0.0,
                "etaHigh" to 0.0,
            ),
            "createdAt" to now,
            "updatedAt" to now,
            "schemaVersion" to 1,
            "source" to "android-hermes-square",
        )
        batch.set(groupRef, groupPayload)

        runtimeTokens.forEachIndexed { index, runtimeToken ->
            val missionID = childMissionIDs[index]
            val childPayload = CLIAgentMissionRequestPayloadFactory.build(
                id = missionID,
                title = "$trimmedTitle · $runtimeToken",
                prompt = trimmedPrompt,
                missionKind = missionKind,
                requestedRuntime = runtimeToken,
                targetProject = targetProject,
                depth = depth,
                approvalMode = approvalMode,
                commandsAllowed = commandsAllowed,
                fileEditsAllowed = fileEditsAllowed,
            ).toMutableMap().apply {
                put("groupID", groupID)
                put("siblingIndex", index)
                put("siblingCount", runtimeTokens.size)
                put("isGroupChild", true)
            }
            val requestRef = firestore.collection("users").document(uid)
                .collection("cli_agent_mission_requests").document(missionID)
            batch.set(requestRef, childPayload.toMap())
            batch.set(
                requestRef.collection("events").document("000001"),
                CLIAgentMissionRequestPayloadFactory.initialQueuedEvent(),
            )
        }

        batch.commit().await()
        return FanOutDispatchResult(groupID = groupID, childMissionIDs = childMissionIDs)
    }

    data class FanOutDispatchResult(
        val groupID: String,
        val childMissionIDs: List<String>,
    )

    suspend fun dispatch(
        title: String,
        prompt: String,
        missionKind: String,
        requestedRuntime: String = "auto",
        targetProject: String? = null,
        depth: String = "standard",
        approvalMode: String = "existing_policy",
        commandsAllowed: Boolean = false,
        fileEditsAllowed: Boolean = false,
    ): String {
        val uid = auth.currentUser?.uid ?: throw DispatchException("Sign in before dispatching Mac agent missions.")
        val trimmedPrompt = prompt.trim()
        if (trimmedPrompt.isBlank()) throw DispatchException("Mission prompt was empty.")

        val id = UUID.randomUUID().toString()
        val payload = CLIAgentMissionRequestPayloadFactory.build(
            id = id,
            title = title,
            prompt = trimmedPrompt,
            missionKind = missionKind,
            requestedRuntime = requestedRuntime,
            targetProject = targetProject,
            depth = depth,
            approvalMode = approvalMode,
            commandsAllowed = commandsAllowed,
            fileEditsAllowed = fileEditsAllowed,
        )
        val requestRef = firestore.collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(id)
        firestore.batch()
            .set(requestRef, payload)
            .set(
                requestRef.collection("events").document("000001"),
                CLIAgentMissionRequestPayloadFactory.initialQueuedEvent(),
            )
            .commit()
            .await()
        return id
    }

    fun observe(requestID: String): Flow<CLIAgentMissionSnapshot> = callbackFlow {
        val uid = auth.currentUser?.uid
        if (uid == null) {
            close(DispatchException("Sign in before watching Mac agent missions."))
            return@callbackFlow
        }
        val requestRef = firestore.collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(requestID)
        var latestSnapshot: DocumentSnapshot? = null
        var latestEvents: List<CLIAgentMissionEvent> = emptyList()

        fun emitLatest() {
            val mission = latestSnapshot?.toMissionSnapshot(
                fallbackID = requestID,
                eventOverride = latestEvents.takeIf { it.isNotEmpty() },
            )
            if (mission != null) trySend(mission)
        }

        val requestRegistration = requestRef.addSnapshotListener { snapshot, error ->
            if (error != null) {
                close(error)
                return@addSnapshotListener
            }
            latestSnapshot = snapshot
            emitLatest()
        }
        val eventsRegistration = requestRef.collection("events")
            .orderBy("sequence")
            .limit(1000)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    close(error)
                    return@addSnapshotListener
                }
                latestEvents = snapshot?.documents.orEmpty().mapNotNull { it.toMissionEvent() }
                emitLatest()
            }
        awaitClose {
            requestRegistration.remove()
            eventsRegistration.remove()
        }
    }

    suspend fun respondToApproval(
        requestID: String,
        approve: Boolean,
    ) {
        val uid = auth.currentUser?.uid ?: throw DispatchException("Sign in before approving Mac agent missions.")
        firestore.collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(requestID)
            .set(
                mapOf(
                    "approvalStatus" to if (approve) "approved" else "rejected",
                    "approvalRespondedAt" to Instant.now().toString(),
                    "liveSummary" to if (approve) {
                        "Approval granted from mobile. Waiting for the Mac to resume."
                    } else {
                        "Approval rejected from mobile."
                    },
                    "updatedAt" to FieldValue.serverTimestamp(),
                ),
                com.google.firebase.firestore.SetOptions.merge(),
            )
            .await()
    }
}

object CLIAgentMissionRequestPayloadFactory {
    fun build(
        id: String,
        title: String,
        prompt: String,
        missionKind: String,
        requestedRuntime: String,
        targetProject: String?,
        depth: String,
        approvalMode: String,
        commandsAllowed: Boolean,
        fileEditsAllowed: Boolean,
        now: Instant = Instant.now(),
    ): Map<String, Any> = mapOf(
        "id" to id,
        "title" to title.trim().ifBlank { "Insights mission" },
        "prompt" to prompt.trim(),
        "missionKind" to missionKind,
        "requestedRuntime" to requestedRuntime,
        "targetProject" to targetProject.orEmpty().trim(),
        "depth" to depth,
        "approvalMode" to approvalMode,
        "commandsAllowed" to commandsAllowed,
        "fileEditsAllowed" to fileEditsAllowed,
        "source" to "android-insights",
        "status" to "pending",
        "liveSummary" to "Mission queued from this device. Waiting for the signed-in Mac agent listener to claim it.",
        "createdAt" to now.toString(),
        "updatedAt" to FieldValue.serverTimestamp(),
        "schemaVersion" to 2,
    )

    fun initialQueuedEvent(now: Instant = Instant.now()): Map<String, Any> = mapOf(
        "sequence" to 1,
        "timestamp" to now.toString(),
        "kind" to "status",
        "phase" to "queued",
        "title" to "Queued",
        "message" to "Mission queued from this device.",
        "source" to "android",
        "isError" to false,
    )
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
    val approvalRequestId: String?,
    val approvalStatus: String?,
    val approvalTitle: String?,
    val approvalMessage: String?,
    val events: List<CLIAgentMissionEvent>,
    val createdAt: Instant?,
) {
    val runtimeLabel: String
        get() = selectedRuntimeName ?: selectedRuntime ?: if (requestedRuntime == "auto") "Mac agent fleet" else requestedRuntime

    val isTerminal: Boolean
        get() = status in setOf("completed", "failed", "canceled", "cancelled", "unauthorized", "agent_launch_failed")

    val isWaitingForApproval: Boolean
        get() = status == "waiting_for_approval" && (approvalStatus ?: "pending") == "pending"

    val displayStatus: String
        get() {
            val normalized = status.lowercase()
            if (normalized !in setOf("pending", "queued")) return status
            val created = createdAt ?: return status
            return if (Instant.now().epochSecond - created.epochSecond > 120) "mac_offline" else status
        }

    val displayLiveSummary: String?
        get() = if (displayStatus == "mac_offline") {
            "No signed-in Mac has claimed this mission yet. Open BurnBar on the paired Mac to start execution."
        } else {
            liveSummary
        }

    val currentStepLabel: String
        get() = events.lastOrNull()?.let { event ->
            event.title?.takeIf { it.isNotBlank() }
                ?: event.phase.replace("_", " ").replaceFirstChar { it.uppercase() }
        } ?: displayStatus

    val activeToolName: String?
        get() {
            val event = events.asReversed().firstOrNull { event ->
                !event.toolName.isNullOrBlank() ||
                    event.kind == "tool_call" ||
                    event.kind == "tool_result" ||
                    event.phase == "tool_use" ||
                    event.phase == "tool_result"
            } ?: return null
            return event.toolName?.takeIf { it.isNotBlank() }
                ?: event.title?.takeIf { it.isNotBlank() }
        }

    val latestArtifactLabel: String?
        get() = events.asReversed()
            .firstNotNullOfOrNull { event ->
                event.changedFilePath?.takeIf { it.isNotBlank() }
                    ?: event.artifactPath?.takeIf { it.isNotBlank() }
            }
}

data class CLIAgentMissionEvent(
    val sequence: Int,
    val timestamp: String,
    val kind: String,
    val phase: String,
    val title: String?,
    val message: String,
    val fullMessage: String? = null,
    val messageLength: Int? = null,
    val messageTruncated: Boolean = false,
    val runtime: String?,
    val source: String?,
    val toolName: String?,
    val artifactPath: String?,
    val changedFilePath: String?,
    val isError: Boolean,
)

private fun DocumentSnapshot.toMissionSnapshot(
    fallbackID: String,
    eventOverride: List<CLIAgentMissionEvent>? = null,
): CLIAgentMissionSnapshot? {
    val title = getString("title") ?: return null
    val status = getString("status") ?: return null
    val rawEvents = get("events") as? List<*> ?: emptyList<Any>()
    val events = eventOverride ?: rawEvents.mapNotNull { raw ->
        val map = raw as? Map<*, *> ?: return@mapNotNull null
        map.toMissionEvent()
    }
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
        approvalRequestId = getString("approvalRequestId"),
        approvalStatus = getString("approvalStatus"),
        approvalTitle = getString("approvalTitle"),
        approvalMessage = getString("approvalMessage"),
        events = events.sortedWith(compareBy<CLIAgentMissionEvent> { it.sequence }.thenBy { it.timestamp }),
        createdAt = getString("createdAt")?.let { runCatching { Instant.parse(it) }.getOrNull() },
    )
}

private fun DocumentSnapshot.toMissionEvent(): CLIAgentMissionEvent? = data?.toMissionEvent()

private fun Map<*, *>.toMissionEvent(): CLIAgentMissionEvent? {
    val phase = this["phase"] as? String ?: return null
    return CLIAgentMissionEvent(
        sequence = (this["sequence"] as? Number)?.toInt() ?: 0,
        timestamp = this["timestamp"] as? String ?: return null,
        kind = this["kind"] as? String ?: phase,
        phase = phase,
        title = this["title"] as? String,
        message = this["message"] as? String ?: return null,
        fullMessage = this["fullMessage"] as? String,
        messageLength = (this["messageLength"] as? Number)?.toInt(),
        messageTruncated = this["messageTruncated"] as? Boolean ?: false,
        runtime = this["runtime"] as? String,
        source = this["source"] as? String,
        toolName = this["toolName"] as? String,
        artifactPath = this["artifactPath"] as? String,
        changedFilePath = this["changedFilePath"] as? String,
        isError = this["isError"] as? Boolean ?: (phase == "failed"),
    )
}
