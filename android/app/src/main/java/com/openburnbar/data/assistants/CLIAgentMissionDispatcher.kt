package com.openburnbar.data.assistants

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import com.openburnbar.data.cloud.AndroidCloudVaultResolvedKey
import com.openburnbar.data.cloud.CloudVaultCrypto
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private const val VAL_3 = 3

private val missionCloudJson =
    Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
    }

@Serializable
private data class AndroidMissionPrivatePayload(
    val title: String? = null,
    val prompt: String? = null,
    val targetProject: String? = null,
    val liveSummary: String? = null,
    val resultPreview: String? = null,
    val errorMessage: String? = null,
    val approvalTitle: String? = null,
    val approvalMessage: String? = null,
    val personaScopeJSON: String? = null,
    val synthesisSummary: String? = null,
)

@Serializable
private data class AndroidMissionEventPrivatePayload(
    val title: String? = null,
    val message: String,
    val fullMessage: String? = null,
    val toolName: String? = null,
    val artifactPath: String? = null,
    val changedFilePath: String? = null,
)

private fun sealedMissionPayloadMap(payload: AndroidMissionPrivatePayload, key: AndroidCloudVaultResolvedKey): Map<String, Any> =
    CloudVaultCrypto.sealedPayloadMap(
        CloudVaultCrypto.sealPayload(
            missionCloudJson.encodeToString(payload).toByteArray(Charsets.UTF_8),
            key.keyData,
            key.vaultKeyID,
        ),
    )

private fun sealedMissionEventPayloadMap(payload: AndroidMissionEventPrivatePayload, key: AndroidCloudVaultResolvedKey): Map<String, Any> =
    CloudVaultCrypto.sealedPayloadMap(
        CloudVaultCrypto.sealPayload(
            missionCloudJson.encodeToString(payload).toByteArray(Charsets.UTF_8),
            key.keyData,
            key.vaultKeyID,
        ),
    )

private fun openMissionPayload(raw: Any?, vaultKey: ByteArray?): AndroidMissionPrivatePayload? {
    val key = vaultKey ?: return null
    val envelope = CloudVaultCrypto.sealedPayloadFromMap(raw as? Map<*, *>) ?: return null
    return runCatching {
        missionCloudJson.decodeFromString<AndroidMissionPrivatePayload>(
            CloudVaultCrypto.openPayload(envelope, key).toString(Charsets.UTF_8),
        )
    }.getOrNull()
}

private fun openMissionEventPayload(raw: Any?, vaultKey: ByteArray?): AndroidMissionEventPrivatePayload? {
    val key = vaultKey ?: return null
    val envelope = CloudVaultCrypto.sealedPayloadFromMap(raw as? Map<*, *>) ?: return null
    return runCatching {
        missionCloudJson.decodeFromString<AndroidMissionEventPrivatePayload>(
            CloudVaultCrypto.openPayload(envelope, key).toString(Charsets.UTF_8),
        )
    }.getOrNull()
}

private suspend fun sealedMissionStateUpdate(
    uid: String,
    firestore: FirebaseFirestore,
    payload: Map<String, Any>,
    liveSummary: String? = null,
    resultPreview: String? = null,
    errorMessage: String? = null,
    approvalTitle: String? = null,
    approvalMessage: String? = null,
): Map<String, Any> {
    val key = AndroidCloudVaultKeyAccess.keyForWriting(uid = uid, firestore = firestore)
    val sanitized = payload.toMutableMap()
    listOf("liveSummary", "resultPreview", "errorMessage", "approvalTitle", "approvalMessage").forEach { sanitized.remove(it) }
    val privatePayload =
        AndroidMissionPrivatePayload(
            liveSummary = liveSummary,
            resultPreview = resultPreview,
            errorMessage = errorMessage,
            approvalTitle = approvalTitle,
            approvalMessage = approvalMessage,
        )
    sanitized["contentSealed"] = true
    sanitized["sealedStateSchemaVersion"] = 1
    sanitized["sealedStateVaultKeyID"] = key.vaultKeyID
    sanitized["sealedStatePayload"] = sealedMissionPayloadMap(privatePayload, key)
    return sanitized
}

enum class HermesSkillRunID(val wire: String, val displayLabel: String) {
    WHAT_HAPPENED("what_happened", "What Happened?"),
    BURN_FORENSICS("burn_forensics", "Burn Forensics"),
    PATTERN_MINER("pattern_miner", "Pattern Miner"),
    COMPARE_AGENTS("compare_agents", "Compare Agents"),
    NEXT_ACTION_COACH("next_action_coach", "Next Action Coach"),
    HANDOFF_BUILDER("handoff_builder", "Handoff Builder"),
    REGRESSION_WATCH("regression_watch", "Regression Watch"),
    RUN_PULSE("run_pulse", "Run Pulse"),
    ;

    companion object {
        fun fromWire(value: String?): HermesSkillRunID? = values().firstOrNull { it.wire == value }
    }
}

enum class SkillRunDeliveryMode(val wire: String, val displayLabel: String) {
    ACTION_ONLY("action_only", "Action alerts"),
    FULL_STREAM("full_stream", "Full stream"),
    MUTED("muted", "Muted"),
    ;

    companion object {
        fun fromWire(value: String?): SkillRunDeliveryMode = values().firstOrNull { it.wire == value } ?: ACTION_ONLY
    }
}

enum class CLIAgentChatPresentationMode(val wire: String, val displayLabel: String) {
    NATIVE_CHAT("native_chat", "Chat"),
    MAC_VISIBLE_CLI("mac_visible_cli", "Mac CLI"),
    MAC_INTERACTIVE_CLI("mac_interactive_cli", "Mac interactive CLI"),
    ;

    companion object {
        fun fromWire(value: String?): CLIAgentChatPresentationMode = values().firstOrNull { it.wire == value } ?: NATIVE_CHAT
    }
}

enum class SkillRunEventImportance(val wire: String) {
    QUIET("quiet"),
    NORMAL("normal"),
    ACTION_REQUIRED("action_required"),
    TERMINAL("terminal"),
    ;

    companion object {
        fun fromWire(value: String?): SkillRunEventImportance = values().firstOrNull { it.wire == value } ?: NORMAL
    }
}

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
        requestedModelIDsByRuntime: Map<String, String> = emptyMap(),
        sourceSkillID: String? = null,
        sourceSurface: String? = null,
        deliveryMode: SkillRunDeliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
        parentHermesThreadID: String? = null,
    ): FanOutDispatchResult {
        val uid =
            auth.currentUser?.uid
                ?: throw DispatchException("Sign in before dispatching Mac agent missions.")
        val trimmedPrompt = prompt.trim()
        val validationMessage =
            when {
                runtimeTokens.size < 2 -> "Fan-out dispatch needs at least 2 runtimes."
                trimmedPrompt.isBlank() -> "Mission prompt was empty."
                else -> null
            }
        if (validationMessage != null) throw DispatchException(validationMessage)

        val plan = planFanOutDispatch(title, prompt, runtimeTokens)
        val resolvedKey = AndroidCloudVaultKeyAccess.keyForWriting(uid = uid, firestore = firestore)
        val groupRef =
            firestore.collection("users").document(uid)
                .collection("mission_groups").document(plan.groupID)
        val batch = firestore.batch()
        batch.set(
            groupRef,
            CLIAgentMissionRequestPayloadFactory.sealGroupPayload(
                fanOutGroupPayload(
                    plan = plan,
                    missionKind = missionKind,
                    targetProject = targetProject,
                    runtimeTokens = runtimeTokens,
                    parallelismLimit = parallelismLimit,
                    mergeStrategy = mergeStrategy,
                ),
                title = plan.trimmedTitle,
                prompt = plan.trimmedPrompt,
                targetProject = targetProject,
                key = resolvedKey,
            ),
        )
        appendFanOutChildMissionWrites(
            FanOutChildWriteRequest(
                batch = batch,
                firestore = firestore,
                uid = uid,
                plan = plan,
                runtimeTokens = runtimeTokens,
                missionKind = missionKind,
                targetProject = targetProject,
                depth = depth,
                approvalMode = approvalMode,
                commandsAllowed = commandsAllowed,
                fileEditsAllowed = fileEditsAllowed,
                requestedModelIDsByRuntime = requestedModelIDsByRuntime,
                sourceSkillID = sourceSkillID,
                sourceSurface = sourceSurface,
                deliveryMode = deliveryMode,
                parentHermesThreadID = parentHermesThreadID,
                key = resolvedKey,
            ),
        )

        batch.commit().await()
        return FanOutDispatchResult(groupID = plan.groupID, childMissionIDs = plan.childMissionIDs)
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
        requestedModelID: String? = null,
        clientThreadID: String? = null,
        parentSessionID: String? = null,
        resumeAction: String? = null,
        sourceSkillID: String? = null,
        sourceSurface: String? = null,
        deliveryMode: SkillRunDeliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
        parentHermesThreadID: String? = null,
        presentationMode: CLIAgentChatPresentationMode = CLIAgentChatPresentationMode.NATIVE_CHAT,
    ): String {
        val uid = auth.currentUser?.uid ?: throw DispatchException("Sign in before dispatching Mac agent missions.")
        val trimmedPrompt = prompt.trim()
        if (trimmedPrompt.isBlank()) throw DispatchException("Mission prompt was empty.")

        val id = UUID.randomUUID().toString()
        val resolvedKey = AndroidCloudVaultKeyAccess.keyForWriting(uid = uid, firestore = firestore)
        val payload =
            CLIAgentMissionRequestPayloadFactory.buildSealed(
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
                requestedModelID = requestedModelID,
                clientThreadID = clientThreadID,
                parentSessionID = parentSessionID,
                resumeAction = resumeAction,
                sourceSkillID = sourceSkillID,
                sourceSurface = sourceSurface,
                deliveryMode = deliveryMode,
                parentHermesThreadID = parentHermesThreadID,
                presentationMode = presentationMode,
                key = resolvedKey,
            )
        val requestRef =
            firestore.collection("users").document(uid)
                .collection("cli_agent_mission_requests").document(id)
        firestore.batch()
            .set(requestRef, payload)
            .set(
                requestRef.collection("events").document("000001"),
                CLIAgentMissionRequestPayloadFactory.initialQueuedEventSealed(
                    label = if (missionKind.trim().equals("chat", ignoreCase = true)) "Chat" else "Mission",
                    source =
                    sourceSurface?.trim()?.takeIf { it.isNotEmpty() }
                        ?: if (missionKind.trim().equals("chat", ignoreCase = true)) "android-chat" else "android",
                    sourceSkillID = sourceSkillID,
                    deliveryMode = deliveryMode,
                    key = resolvedKey,
                ),
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
        val requestRef =
            firestore.collection("users").document(uid)
                .collection("cli_agent_mission_requests").document(requestID)
        val vaultKey = runCatching { AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore)?.keyData }.getOrNull()
        var latestSnapshot: DocumentSnapshot? = null
        var latestEvents: List<CLIAgentMissionEvent> = emptyList()

        fun emitLatest() {
            val mission =
                latestSnapshot?.toMissionSnapshot(
                    fallbackID = requestID,
                    eventOverride = latestEvents.takeIf { it.isNotEmpty() },
                    vaultKey = vaultKey,
                )
            if (mission != null) trySend(mission)
        }

        val requestRegistration =
            requestRef.addSnapshotListener { snapshot, error ->
                if (error != null) {
                    close(error)
                    return@addSnapshotListener
                }
                latestSnapshot = snapshot
                emitLatest()
            }
        val eventsRegistration =
            requestRef.collection("events")
                .orderBy("sequence")
                .limit(1000)
                .addSnapshotListener { snapshot, error ->
                    if (error != null) {
                        close(error)
                        return@addSnapshotListener
                    }
                    latestEvents = snapshot?.documents.orEmpty().mapNotNull { it.toMissionEvent(vaultKey) }
                    emitLatest()
                }
        awaitClose {
            requestRegistration.remove()
            eventsRegistration.remove()
        }
    }

    suspend fun respondToApproval(requestID: String, approve: Boolean) {
        val uid = auth.currentUser?.uid ?: throw DispatchException("Sign in before approving Mac agent missions.")
        firestore.collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(requestID)
            .set(
                sealedMissionStateUpdate(
                    uid = uid,
                    firestore = firestore,
                    payload =
                        mapOf(
                            "approvalStatus" to if (approve) "approved" else "rejected",
                            "approvalRespondedAt" to Instant.now().toString(),
                            "updatedAt" to FieldValue.serverTimestamp(),
                        ),
                    liveSummary =
                        if (approve) {
                            "Approval granted from mobile. Waiting for the Mac to resume."
                        } else {
                            "Approval rejected from mobile."
                        },
                ),
                com.google.firebase.firestore.SetOptions.merge(),
            )
            .await()
    }

    suspend fun cancelMission(requestID: String) {
        val uid = auth.currentUser?.uid ?: throw DispatchException("Sign in before cancelling Mac agent missions.")
        firestore.collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(requestID)
            .set(
                sealedMissionStateUpdate(
                    uid = uid,
                    firestore = firestore,
                    payload =
                        mapOf(
                            "status" to "cancelled",
                            "updatedAt" to FieldValue.serverTimestamp(),
                        ),
                    liveSummary = "Mission cancelled by user.",
                ),
                com.google.firebase.firestore.SetOptions.merge(),
            )
            .await()
    }

    suspend fun createImportJob(selectedHarnesses: List<String>, source: String = "android-import"): String {
        val uid = auth.currentUser?.uid ?: throw DispatchException("Sign in before importing Mac agent history.")
        val normalized = selectedHarnesses.map { it.trim().lowercase() }.filter { it.isNotBlank() }.distinct()
        if (normalized.isEmpty()) throw DispatchException("Choose at least one agent history source.")
        val id = "import-${UUID.randomUUID()}"
        firestore.collection("users").document(uid)
            .collection("agent_import_jobs").document(id)
            .set(
                mapOf(
                    "id" to id,
                    "selectedHarnesses" to normalized,
                    "status" to "pending",
                    "source" to source,
                    "progressMessage" to "Waiting for a trusted Mac.",
                    "scannedCount" to 0,
                    "importedCount" to 0,
                    "mirroredSessionCount" to 0,
                    "uploadedSessionLogCount" to 0,
                    "createdAt" to Instant.now().toString(),
                    "updatedAt" to FieldValue.serverTimestamp(),
                    "schemaVersion" to 1,
                ),
            )
            .await()
        return id
    }

    fun observeImportJob(jobID: String): Flow<AgentImportJobSnapshot> = callbackFlow {
        val uid = auth.currentUser?.uid
        if (uid == null) {
            close(DispatchException("Sign in before watching Mac agent imports."))
            return@callbackFlow
        }
        val registration =
            firestore.collection("users").document(uid)
                .collection("agent_import_jobs").document(jobID)
                .addSnapshotListener { snapshot, error ->
                    if (error != null) {
                        close(error)
                        return@addSnapshotListener
                    }
                    val data = snapshot?.data.orEmpty()
                    trySend(
                        AgentImportJobSnapshot(
                            id = snapshot?.id ?: jobID,
                            status = data["status"] as? String ?: "pending",
                            progressMessage = data["progressMessage"] as? String ?: "",
                            scannedCount = (data["scannedCount"] as? Number)?.toInt() ?: 0,
                            importedCount = (data["importedCount"] as? Number)?.toInt() ?: 0,
                            mirroredSessionCount = (data["mirroredSessionCount"] as? Number)?.toInt() ?: 0,
                            uploadedSessionLogCount = (data["uploadedSessionLogCount"] as? Number)?.toInt() ?: 0,
                            errorMessage = data["errorMessage"] as? String,
                        ),
                    )
                }
        awaitClose { registration.remove() }
    }
}

data class AgentImportJobSnapshot(
    val id: String,
    val status: String,
    val progressMessage: String,
    val scannedCount: Int,
    val importedCount: Int,
    val mirroredSessionCount: Int,
    val uploadedSessionLogCount: Int,
    val errorMessage: String?,
) {
    val isTerminal: Boolean
        get() = status == "completed" || status == "failed"
}

object CLIAgentMissionRequestPayloadFactory {
    @Suppress("LongParameterList")
    fun buildSealed(
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
        requestedModelID: String? = null,
        clientThreadID: String? = null,
        parentSessionID: String? = null,
        resumeAction: String? = null,
        sourceSkillID: String? = null,
        sourceSurface: String? = null,
        deliveryMode: SkillRunDeliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
        parentHermesThreadID: String? = null,
        presentationMode: CLIAgentChatPresentationMode = CLIAgentChatPresentationMode.NATIVE_CHAT,
        key: AndroidCloudVaultResolvedKey,
        now: Instant = Instant.now(),
    ): Map<String, Any> {
        val legacy =
            build(
                id = id,
                title = title,
                prompt = prompt,
                missionKind = missionKind,
                requestedRuntime = requestedRuntime,
                targetProject = targetProject,
                depth = depth,
                approvalMode = approvalMode,
                commandsAllowed = commandsAllowed,
                fileEditsAllowed = fileEditsAllowed,
                requestedModelID = requestedModelID,
                clientThreadID = clientThreadID,
                parentSessionID = parentSessionID,
                resumeAction = resumeAction,
                sourceSkillID = sourceSkillID,
                sourceSurface = sourceSurface,
                deliveryMode = deliveryMode,
                parentHermesThreadID = parentHermesThreadID,
                presentationMode = presentationMode,
                now = now,
            )
        val isChat = missionKind.trim().equals("chat", ignoreCase = true)
        return applySealedPrivatePayload(
            payload = legacy,
            privatePayload =
                AndroidMissionPrivatePayload(
                    title = title.trim().ifBlank { if (isChat) "New chat" else "Insights mission" },
                    prompt = prompt.trim(),
                    targetProject = targetProject?.trim()?.takeIf { it.isNotEmpty() },
                    liveSummary =
                        if (isChat) {
                            "Chat queued from this device. Waiting for the signed-in Mac agent listener to claim it."
                        } else {
                            "Mission queued from this device. Waiting for the signed-in Mac agent listener to claim it."
                        },
                ),
            key = key,
        )
    }

    fun sealGroupPayload(
        payload: Map<String, Any>,
        title: String,
        prompt: String,
        targetProject: String?,
        key: AndroidCloudVaultResolvedKey,
    ): Map<String, Any> =
        applySealedPrivatePayload(
            payload = payload,
            privatePayload =
                AndroidMissionPrivatePayload(
                    title = title.trim().ifBlank { "Fan-out mission" },
                    prompt = prompt.trim(),
                    targetProject = targetProject?.trim()?.takeIf { it.isNotEmpty() },
                ),
            key = key,
        )

    @Suppress("LongParameterList")
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
        requestedModelID: String? = null,
        clientThreadID: String? = null,
        parentSessionID: String? = null,
        resumeAction: String? = null,
        sourceSkillID: String? = null,
        sourceSurface: String? = null,
        deliveryMode: SkillRunDeliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
        parentHermesThreadID: String? = null,
        presentationMode: CLIAgentChatPresentationMode = CLIAgentChatPresentationMode.NATIVE_CHAT,
        now: Instant = Instant.now(),
    ): Map<String, Any> {
        val isChat = missionKind.trim().equals("chat", ignoreCase = true)
        val baseSource = if (isChat) "android-chat" else "android-insights"
        return buildMap {
            put("id", id)
            put("title", title.trim().ifBlank { if (isChat) "New chat" else "Insights mission" })
            put("prompt", prompt.trim())
            put("missionKind", missionKind)
            put("requestedRuntime", requestedRuntime)
            requestedModelID?.trim()?.takeIf { it.isNotEmpty() }?.let { put("requestedModelID", it) }
            put("targetProject", targetProject.orEmpty().trim())
            put("depth", depth)
            put("approvalMode", approvalMode)
            put("commandsAllowed", commandsAllowed)
            put("fileEditsAllowed", fileEditsAllowed)
            put("source", baseSource)
            put("sourceSurface", sourceSurface?.trim()?.takeIf { it.isNotEmpty() } ?: baseSource)
            put("deliveryMode", deliveryMode.wire)
            put("presentationMode", presentationMode.wire)
            put("status", "pending")
            put(
                "liveSummary",
                if (isChat) {
                    "Chat queued from this device. Waiting for the signed-in Mac agent listener to claim it."
                } else {
                    "Mission queued from this device. Waiting for the signed-in Mac agent listener to claim it."
                },
            )
            put("createdAt", now.toString())
            put("updatedAt", FieldValue.serverTimestamp())
            put("schemaVersion", VAL_3)
            sourceSkillID?.trim()?.takeIf { it.isNotEmpty() }?.let { put("sourceSkillID", it) }
            clientThreadID?.trim()?.takeIf { it.isNotEmpty() }?.let { put("clientThreadID", it) }
            parentHermesThreadID?.trim()?.takeIf { it.isNotEmpty() }?.let { put("parentHermesThreadID", it) }
            parentSessionID?.trim()?.takeIf { it.isNotEmpty() }?.let { put("parentSessionID", it) }
            resumeAction?.trim()?.takeIf { it.isNotEmpty() }?.let { put("resumeAction", it) }
        }
    }

    fun initialQueuedEvent(
        label: String = "Mission",
        source: String = "android",
        sourceSkillID: String? = null,
        deliveryMode: SkillRunDeliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
        eventImportance: SkillRunEventImportance = SkillRunEventImportance.NORMAL,
        skillStepID: String = "queued",
        now: Instant = Instant.now(),
    ): Map<String, Any> = buildMap {
        put("sequence", 1)
        put("timestamp", now.toString())
        put("kind", "status")
        put("phase", "queued")
        put("title", "Queued")
        put("message", "$label queued from this device.")
        put("source", source)
        put("deliveryMode", deliveryMode.wire)
        put("eventImportance", eventImportance.wire)
        put("skillStepID", skillStepID)
        put("isError", false)
        sourceSkillID?.trim()?.takeIf { it.isNotEmpty() }?.let { put("sourceSkillID", it) }
    }

    fun initialQueuedEventSealed(
        label: String = "Mission",
        source: String = "android",
        sourceSkillID: String? = null,
        deliveryMode: SkillRunDeliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
        eventImportance: SkillRunEventImportance = SkillRunEventImportance.NORMAL,
        skillStepID: String = "queued",
        now: Instant = Instant.now(),
        key: AndroidCloudVaultResolvedKey,
    ): Map<String, Any> {
        val legacy =
            initialQueuedEvent(
                label = label,
                source = source,
                sourceSkillID = sourceSkillID,
                deliveryMode = deliveryMode,
                eventImportance = eventImportance,
                skillStepID = skillStepID,
                now = now,
            )
        val sealed = legacy.toMutableMap()
        val privatePayload =
            AndroidMissionEventPrivatePayload(
                title = legacy["title"] as? String,
                message = legacy["message"] as? String ?: "$label queued from this device.",
                fullMessage = legacy["fullMessage"] as? String,
                toolName = legacy["toolName"] as? String,
                artifactPath = legacy["artifactPath"] as? String,
                changedFilePath = legacy["changedFilePath"] as? String,
            )
        listOf("title", "message", "fullMessage", "toolName", "artifactPath", "changedFilePath").forEach { sealed.remove(it) }
        sealed["contentSealed"] = true
        sealed["sealedSchemaVersion"] = 1
        sealed["vaultKeyID"] = key.vaultKeyID
        sealed["sealedPayload"] = sealedMissionEventPayloadMap(privatePayload, key)
        return sealed
    }

    private fun applySealedPrivatePayload(
        payload: Map<String, Any>,
        privatePayload: AndroidMissionPrivatePayload,
        key: AndroidCloudVaultResolvedKey,
    ): Map<String, Any> {
        val sealed = payload.toMutableMap()
        listOf(
            "title",
            "prompt",
            "targetProject",
            "liveSummary",
            "resultPreview",
            "errorMessage",
            "approvalTitle",
            "approvalMessage",
            "personaScopeJSON",
            "synthesisSummary",
        ).forEach { sealed.remove(it) }
        sealed["contentSealed"] = true
        sealed["sealedSchemaVersion"] = 1
        sealed["vaultKeyID"] = key.vaultKeyID
        sealed["sealedPayload"] = sealedMissionPayloadMap(privatePayload, key)
        return sealed
    }
}

class DispatchException(message: String) : Exception(message)

data class CLIAgentMissionSnapshot(
    val id: String,
    val title: String,
    val status: String,
    val requestedRuntime: String,
    val requestedModelID: String?,
    val selectedRuntime: String?,
    val selectedRuntimeName: String?,
    val selectedModelID: String?,
    val targetProject: String? = null,
    val sourceSkillID: String? = null,
    val sourceSurface: String? = null,
    val deliveryMode: SkillRunDeliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
    val parentHermesThreadID: String? = null,
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
        get() = status == "waiting_for_approval" && approvalStatus ?: "pending" == "pending"

    val displayStatus: String
        get() {
            val normalized = status.lowercase()
            if (normalized !in setOf("pending", "queued")) return status
            val created = createdAt ?: return status
            return if (Instant.now().epochSecond - created.epochSecond > 120) "mac_offline" else status
        }

    val displayLiveSummary: String?
        get() =
            if (displayStatus == "mac_offline") {
                "No signed-in Mac has claimed this mission yet. Open BurnBar on the paired Mac to start execution."
            } else {
                liveSummary
            }

    val currentStepLabel: String
        get() =
            events.lastOrNull()?.let { event ->
                event.title?.takeIf { it.isNotBlank() }
                    ?: event.phase.replace("_", " ").replaceFirstChar { it.uppercase() }
            } ?: displayStatus

    val activeToolName: String?
        get() {
            val event =
                events.asReversed().firstOrNull { event ->
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
        get() =
            events.asReversed()
                .firstNotNullOfOrNull { event ->
                    event.changedFilePath?.takeIf { it.isNotBlank() }
                        ?: event.artifactPath?.takeIf { it.isNotBlank() }
                }

    val skillRunID: HermesSkillRunID?
        get() = HermesSkillRunID.fromWire(sourceSkillID)
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
    val sourceSkillID: String? = null,
    val deliveryMode: SkillRunDeliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
    val eventImportance: SkillRunEventImportance = SkillRunEventImportance.NORMAL,
    val skillStepID: String? = null,
    val isError: Boolean,
)

/** Public alias used by mission/host code outside this file. Mirrors
 *  the iOS `CLIAgentMissionSnapshot` decoder so the mission console host
 *  can decode list-listener documents without re-implementing the parser. */
fun DocumentSnapshot.toMissionSnapshotOrNull(vaultKey: ByteArray? = null): CLIAgentMissionSnapshot? = toMissionSnapshot(fallbackID = id, vaultKey = vaultKey)

private fun DocumentSnapshot.toMissionSnapshot(
    fallbackID: String,
    eventOverride: List<CLIAgentMissionEvent>? = null,
    vaultKey: ByteArray? = null,
): CLIAgentMissionSnapshot? {
    val requestPrivate = openMissionPayload(get("sealedPayload"), vaultKey)
    val statePrivate = openMissionPayload(get("sealedStatePayload"), vaultKey)
    val title = requestPrivate?.title ?: getString("title") ?: return null
    val status = getString("status") ?: return null
    val rawEvents = get("events") as? List<*> ?: emptyList<Any>()
    val events =
        eventOverride ?: rawEvents.mapNotNull { raw ->
            val map = raw as? Map<*, *> ?: return@mapNotNull null
            map.toMissionEvent(vaultKey)
        }
    return CLIAgentMissionSnapshot(
        id = getString("id") ?: fallbackID,
        title = title,
        status = status,
        requestedRuntime = getString("requestedRuntime") ?: "auto",
        requestedModelID = getString("requestedModelID")?.trim()?.takeIf { it.isNotEmpty() },
        selectedRuntime = getString("selectedRuntime"),
        selectedRuntimeName = getString("selectedRuntimeName"),
        selectedModelID = getString("selectedModelID")?.trim()?.takeIf { it.isNotEmpty() },
        targetProject = (requestPrivate?.targetProject ?: getString("targetProject"))?.trim()?.takeIf { it.isNotEmpty() },
        sourceSkillID = getString("sourceSkillID")?.trim()?.takeIf { it.isNotEmpty() },
        sourceSurface = getString("sourceSurface")?.trim()?.takeIf { it.isNotEmpty() },
        deliveryMode = SkillRunDeliveryMode.fromWire(getString("deliveryMode")),
        parentHermesThreadID = getString("parentHermesThreadID")?.trim()?.takeIf { it.isNotEmpty() },
        liveSummary = statePrivate?.liveSummary ?: requestPrivate?.liveSummary ?: getString("liveSummary"),
        resultPreview = statePrivate?.resultPreview ?: requestPrivate?.resultPreview ?: getString("resultPreview"),
        errorMessage = statePrivate?.errorMessage ?: requestPrivate?.errorMessage ?: getString("errorMessage"),
        sessionID = getString("sessionId"),
        approvalRequestId = getString("approvalRequestId"),
        approvalStatus = getString("approvalStatus"),
        approvalTitle = statePrivate?.approvalTitle ?: requestPrivate?.approvalTitle ?: getString("approvalTitle"),
        approvalMessage = statePrivate?.approvalMessage ?: requestPrivate?.approvalMessage ?: getString("approvalMessage"),
        events = events.sortedWith(compareBy<CLIAgentMissionEvent> { it.sequence }.thenBy { it.timestamp }),
        createdAt = getString("createdAt")?.let { runCatching { Instant.parse(it) }.getOrNull() },
    )
}

private fun DocumentSnapshot.toMissionEvent(vaultKey: ByteArray? = null): CLIAgentMissionEvent? = data?.toMissionEvent(vaultKey)

private fun Map<*, *>.toMissionEvent(vaultKey: ByteArray? = null): CLIAgentMissionEvent? {
    val phase = this["phase"] as? String ?: return null
    val privatePayload = openMissionEventPayload(this["sealedPayload"], vaultKey)
    val message = privatePayload?.message ?: this["message"] as? String ?: return null
    return CLIAgentMissionEvent(
        sequence = (this["sequence"] as? Number)?.toInt() ?: 0,
        timestamp = this["timestamp"] as? String ?: return null,
        kind = this["kind"] as? String ?: phase,
        phase = phase,
        title = privatePayload?.title ?: this["title"] as? String,
        message = message,
        fullMessage = privatePayload?.fullMessage ?: this["fullMessage"] as? String,
        messageLength = (this["messageLength"] as? Number)?.toInt(),
        messageTruncated = this["messageTruncated"] as? Boolean ?: false,
        runtime = this["runtime"] as? String,
        source = this["source"] as? String,
        toolName = privatePayload?.toolName ?: this["toolName"] as? String,
        artifactPath = privatePayload?.artifactPath ?: this["artifactPath"] as? String,
        changedFilePath = privatePayload?.changedFilePath ?: this["changedFilePath"] as? String,
        sourceSkillID = this["sourceSkillID"] as? String,
        deliveryMode = SkillRunDeliveryMode.fromWire(this["deliveryMode"] as? String),
        eventImportance = SkillRunEventImportance.fromWire(this["eventImportance"] as? String),
        skillStepID = this["skillStepID"] as? String,
        isError = this["isError"] as? Boolean ?: (phase == "failed"),
    )
}
