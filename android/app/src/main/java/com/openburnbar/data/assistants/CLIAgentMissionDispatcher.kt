package com.openburnbar.data.assistants

import android.util.Log
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import com.openburnbar.data.cloud.AndroidCloudVaultResolvedKey
import com.openburnbar.data.cloud.AndroidCloudVaultSignalPayloads
import com.openburnbar.data.cloud.AndroidSignalIdentityKeyStore
import com.openburnbar.data.cloud.AndroidSignalIdentityKeypair
import com.openburnbar.data.cloud.CloudVaultAADContext
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.cloud.CloudVaultSignalRecipient
import com.openburnbar.data.cloud.SignalAtRestFallbackPolicy
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
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

private const val MISSION_REQUEST_SCHEMA_VERSION = 3

/** Data-domain id whose sealingScheme gates at-rest Signal sealing for CLI missions. */
private const val SIGNAL_CLI_DOMAIN = "conversations_chat"

/**
 * Carries the at-rest Signal sealing context into the (non-suspend) mission payload
 * factories. Resolved in the suspend dispatch path ONLY when the domain gate is on, so
 * a null context (the default everywhere) means production stays fully inert. Matches the
 * iOS-wired surfaces: the single mission request doc + fan-out child request docs (NOT the
 * group doc or event sub-docs, which iOS leaves legacy — wiring them would create envelopes
 * iOS/Mac cannot yet read).
 */
data class CLISignalSealContext(
    val uid: String,
    val collection: String,
    val docId: String,
    val localIdentity: AndroidSignalIdentityKeypair,
    val otherRecipients: List<CloudVaultSignalRecipient>,
)

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

// RR-8 path-bound AAD contexts. These MUST match the Swift writers/readers in
// AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift +
// OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift byte-for-byte (see the
// cross-language KAT CloudVaultAadParityTest). They are nil-safe: when the ids are
// unavailable the readers fall back to legacy global-AAD docs (openPayload branches on
// envelope.aad, so a path context is ignored for a global-AAD document).
private fun missionRequestAadContext(uid: String?, requestID: String): CloudVaultAADContext? = uid?.let {
    runCatching {
        CloudVaultAADContext(uid = it, collection = "cli_agent_mission_requests", docID = requestID, field = "sealedPayload")
    }.getOrNull()
}

private fun missionStateAadContext(uid: String?, requestID: String): CloudVaultAADContext? = uid?.let {
    runCatching {
        CloudVaultAADContext(uid = it, collection = "cli_agent_mission_requests", docID = requestID, field = "sealedStatePayload")
    }.getOrNull()
}

private fun missionEventAadContext(uid: String?, requestID: String?, eventID: String?): CloudVaultAADContext? =
    if (uid != null && requestID != null && eventID != null) {
        runCatching {
            CloudVaultAADContext(
                uid = uid,
                collection = "cli_agent_mission_requests/events",
                docID = "$requestID/$eventID",
                field = "sealedPayload",
            )
        }.getOrNull()
    } else {
        null
    }

private fun openMissionPayload(raw: Any?, vaultKey: ByteArray?, aadContext: CloudVaultAADContext? = null): AndroidMissionPrivatePayload? {
    val key = vaultKey ?: return null
    val envelope = CloudVaultCrypto.sealedPayloadFromMap(raw as? Map<*, *>) ?: return null
    return runCatching {
        missionCloudJson.decodeFromString<AndroidMissionPrivatePayload>(
            CloudVaultCrypto.openPayload(envelope, key, aadContext = aadContext).toString(Charsets.UTF_8),
        )
    }.getOrNull()
}

private fun openMissionEventPayload(raw: Any?, vaultKey: ByteArray?, aadContext: CloudVaultAADContext? = null): AndroidMissionEventPrivatePayload? {
    val key = vaultKey ?: return null
    val envelope = CloudVaultCrypto.sealedPayloadFromMap(raw as? Map<*, *>) ?: return null
    return runCatching {
        missionCloudJson.decodeFromString<AndroidMissionEventPrivatePayload>(
            CloudVaultCrypto.openPayload(envelope, key, aadContext = aadContext).toString(Charsets.UTF_8),
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
    private val securityClient: ComputerUseSecurityCallableClient = ComputerUseSecurityCallableClient(),
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
        validateFanOutDispatch(runtimeTokens, trimmedPrompt)

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
        val fanOutSignal = resolveSignalContext(uid = uid, docId = plan.groupID)
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
                signalIdentity = fanOutSignal?.localIdentity,
                signalRecipients = fanOutSignal?.otherRecipients ?: emptyList(),
            ),
        )

        batch.commit().await()
        return FanOutDispatchResult(groupID = plan.groupID, childMissionIDs = plan.childMissionIDs)
    }

    private fun validateFanOutDispatch(runtimeTokens: List<String>, trimmedPrompt: String) {
        val validationMessage =
            when {
                runtimeTokens.size < 2 -> "Fan-out dispatch needs at least 2 runtimes."
                trimmedPrompt.isBlank() -> "Mission prompt was empty."
                else -> null
            }
        if (validationMessage != null) throw DispatchException(validationMessage)
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
        val signalContext = resolveSignalContext(uid = uid, docId = id)
        val payloadInput =
            CLIMissionPayloadInput(
                core = CLIMissionPayloadCore(id = id, title = title, prompt = trimmedPrompt, missionKind = missionKind),
                execution = CLIMissionPayloadExecution(requestedRuntime, targetProject, depth, approvalMode, requestedModelID),
                permissions = CLIMissionPayloadPermissions(commandsAllowed, fileEditsAllowed),
                metadata =
                CLIMissionPayloadMetadata(
                    clientThreadID,
                    parentSessionID,
                    resumeAction,
                    sourceSkillID,
                    sourceSurface,
                    parentHermesThreadID,
                ),
                experience = CLIMissionPayloadExperience(deliveryMode, presentationMode),
            )
        val payload =
            CLIAgentMissionRequestPayloadFactory.buildSealed(
                input = payloadInput,
                key = resolvedKey,
                signal = signalContext,
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

    /**
     * Resolve the at-rest Signal sealing context for a mission doc, or null when the domain
     * gate is off (the production default → inert). Loads/publishes the device's Signal
     * identity and fetches the trusted-device recipient set only when the gate is on.
     */
    private suspend fun resolveSignalContext(uid: String, docId: String): CLISignalSealContext? {
        if (!AndroidCloudVaultSignalPayloads.signalSealingIsEnabled(SIGNAL_CLI_DOMAIN)) return null
        // BEST-EFFORT at-rest Signal sealing. The legacy AES-GCM sealedPayload is the FLOOR
        // (buildSealed always writes it); the additive signalEnvelope is added only when this
        // context resolves. On ANY failure (e.g. a trusted device without a published
        // identity) return null so the mission writes legacy-only rather than failing the
        // whole dispatch — legacy is already end-to-end so no confidentiality is lost.
        return runCatching {
            val escrow = AndroidCloudVaultDeviceKeypair.loadOrCreate()
            val identity = AndroidSignalIdentityKeyStore.loadOrCreate(escrow.deviceId, escrow.keyVersion)
            AndroidSignalIdentityKeyStore.publishIfNeeded(
                uid = uid,
                deviceId = escrow.deviceId,
                identity = identity,
                firestore = firestore,
            )
            val recipients =
                AndroidCloudVaultSignalPayloads.atRestRecipients(uid = uid, firestore = firestore, localIdentity = identity)
            CLISignalSealContext(
                uid = uid,
                collection = "cli_agent_mission_requests",
                docId = docId,
                localIdentity = identity,
                otherRecipients = recipients,
            )
        }.onFailure {
            Log.w("CLIAgentMissionDispatcher", "Signal at-rest seal context failed; CLI mission writes legacy-only", it)
        }.getOrNull()
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
        // Local-only (no network): null until the device generates a Signal identity (activation).
        val signalIdentity =
            runCatching {
                val escrow = AndroidCloudVaultDeviceKeypair.loadOrCreate()
                AndroidSignalIdentityKeyStore.load(escrow.deviceId, escrow.keyVersion)
            }.getOrNull()
        var latestSnapshot: DocumentSnapshot? = null
        var latestEvents: List<CLIAgentMissionEvent> = emptyList()

        fun emitLatest() {
            val mission =
                latestSnapshot?.toMissionSnapshot(
                    fallbackID = requestID,
                    eventOverride = latestEvents.takeIf { it.isNotEmpty() },
                    vaultKey = vaultKey,
                    uid = uid,
                    signalIdentity = signalIdentity,
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
                    latestEvents = snapshot?.documents.orEmpty().mapNotNull { it.toMissionEvent(vaultKey, uid, requestID) }
                    emitLatest()
                }
        awaitClose {
            requestRegistration.remove()
            eventsRegistration.remove()
        }
    }

    suspend fun respondToApproval(requestID: String, approve: Boolean) {
        auth.currentUser?.uid ?: throw DispatchException("Sign in before approving Mac agent missions.")
        // Bind the approve/reject to this trusted native escrow device via the
        // App-Check-enforced callable. The bare Firestore status flip is no
        // longer accepted by firestore.rules (it must carry approvedByDeviceId
        // resolving to a trusted escrow device), so a stolen owner token cannot
        // self-approve a high-risk mission. The deviceId here is the same id
        // AndroidEscrowDeviceRegistry registers/trusts.
        val deviceId = AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId
        securityClient.respondMissionApproval(
            requestId = requestID,
            approve = approve,
            deviceId = deviceId,
        )
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

internal typealias CLIMissionPayloadInput = CLIAgentMissionRequestPayloadFactory.PayloadInput
internal typealias CLIMissionPayloadCore = CLIAgentMissionRequestPayloadFactory.Core
internal typealias CLIMissionPayloadExecution = CLIAgentMissionRequestPayloadFactory.Execution
internal typealias CLIMissionPayloadPermissions = CLIAgentMissionRequestPayloadFactory.Permissions
internal typealias CLIMissionPayloadMetadata = CLIAgentMissionRequestPayloadFactory.Metadata
internal typealias CLIMissionPayloadExperience = CLIAgentMissionRequestPayloadFactory.Experience

object CLIAgentMissionRequestPayloadFactory {
    data class Core(
        val id: String,
        val title: String,
        val prompt: String,
        val missionKind: String,
    )

    data class Execution(
        val requestedRuntime: String,
        val targetProject: String?,
        val depth: String,
        val approvalMode: String,
        val requestedModelID: String? = null,
    )

    data class Permissions(
        val commandsAllowed: Boolean,
        val fileEditsAllowed: Boolean,
    )

    data class Metadata(
        val clientThreadID: String? = null,
        val parentSessionID: String? = null,
        val resumeAction: String? = null,
        val sourceSkillID: String? = null,
        val sourceSurface: String? = null,
        val parentHermesThreadID: String? = null,
    )

    data class Experience(
        val deliveryMode: SkillRunDeliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
        val presentationMode: CLIAgentChatPresentationMode = CLIAgentChatPresentationMode.NATIVE_CHAT,
    )

    data class PayloadInput(
        val core: Core,
        val execution: Execution,
        val permissions: Permissions,
        val metadata: Metadata = Metadata(),
        val experience: Experience = Experience(),
        val now: Instant = Instant.now(),
    )

    fun buildSealed(input: PayloadInput, key: AndroidCloudVaultResolvedKey, signal: CLISignalSealContext? = null): Map<String, Any> {
        val legacy = build(input)
        val core = input.core
        val isChat = core.missionKind.trim().equals("chat", ignoreCase = true)
        return applySealedPrivatePayload(
            payload = legacy,
            privatePayload =
            AndroidMissionPrivatePayload(
                title = core.title.trim().ifBlank { if (isChat) "New chat" else "Insights mission" },
                prompt = core.prompt.trim(),
                targetProject = input.execution.targetProject?.trim()?.takeIf { it.isNotEmpty() },
                liveSummary =
                if (isChat) {
                    "Chat queued from this device. Waiting for the signed-in Mac agent listener to claim it."
                } else {
                    "Mission queued from this device. Waiting for the signed-in Mac agent listener to claim it."
                },
            ),
            key = key,
            signal = signal,
        )
    }

    fun sealGroupPayload(
        payload: Map<String, Any>,
        title: String,
        prompt: String,
        targetProject: String?,
        key: AndroidCloudVaultResolvedKey,
    ): Map<String, Any> = applySealedPrivatePayload(
        payload = payload,
        privatePayload =
        AndroidMissionPrivatePayload(
            title = title.trim().ifBlank { "Fan-out mission" },
            prompt = prompt.trim(),
            targetProject = targetProject?.trim()?.takeIf { it.isNotEmpty() },
        ),
        key = key,
    )

    fun build(input: PayloadInput): Map<String, Any> {
        val core = input.core
        val execution = input.execution
        val permissions = input.permissions
        val metadata = input.metadata
        val experience = input.experience
        val isChat = core.missionKind.trim().equals("chat", ignoreCase = true)
        val baseSource = if (isChat) "android-chat" else "android-insights"
        return buildMap {
            put("id", core.id)
            put("title", core.title.trim().ifBlank { if (isChat) "New chat" else "Insights mission" })
            put("prompt", core.prompt.trim())
            put("missionKind", core.missionKind)
            put("requestedRuntime", execution.requestedRuntime)
            execution.requestedModelID?.trim()?.takeIf { it.isNotEmpty() }?.let { put("requestedModelID", it) }
            put("targetProject", execution.targetProject.orEmpty().trim())
            put("depth", execution.depth)
            put("approvalMode", execution.approvalMode)
            put("commandsAllowed", permissions.commandsAllowed)
            put("fileEditsAllowed", permissions.fileEditsAllowed)
            put("source", baseSource)
            put("sourceSurface", metadata.sourceSurface?.trim()?.takeIf { it.isNotEmpty() } ?: baseSource)
            put("deliveryMode", experience.deliveryMode.wire)
            put("presentationMode", experience.presentationMode.wire)
            put("status", "pending")
            put(
                "liveSummary",
                if (isChat) {
                    "Chat queued from this device. Waiting for the signed-in Mac agent listener to claim it."
                } else {
                    "Mission queued from this device. Waiting for the signed-in Mac agent listener to claim it."
                },
            )
            put("createdAt", input.now.toString())
            put("updatedAt", FieldValue.serverTimestamp())
            put("schemaVersion", MISSION_REQUEST_SCHEMA_VERSION)
            metadata.sourceSkillID?.trim()?.takeIf { it.isNotEmpty() }?.let { put("sourceSkillID", it) }
            metadata.clientThreadID?.trim()?.takeIf { it.isNotEmpty() }?.let { put("clientThreadID", it) }
            metadata.parentHermesThreadID?.trim()?.takeIf { it.isNotEmpty() }?.let { put("parentHermesThreadID", it) }
            metadata.parentSessionID?.trim()?.takeIf { it.isNotEmpty() }?.let { put("parentSessionID", it) }
            metadata.resumeAction?.trim()?.takeIf { it.isNotEmpty() }?.let { put("resumeAction", it) }
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
        sealed["sealedSchemaVersion"] = 2
        sealed["vaultKeyID"] = key.vaultKeyID
        sealed["sealedPayload"] = sealedMissionEventPayloadMap(privatePayload, key)
        return sealed
    }

    private fun applySealedPrivatePayload(
        payload: Map<String, Any>,
        privatePayload: AndroidMissionPrivatePayload,
        key: AndroidCloudVaultResolvedKey,
        signal: CLISignalSealContext? = null,
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
        sealed["sealedSchemaVersion"] = 2
        sealed["vaultKeyID"] = key.vaultKeyID
        sealed["sealedPayload"] = sealedMissionPayloadMap(privatePayload, key)
        if (signal != null) {
            // Dual-write the at-rest Signal envelope (same plaintext bytes as the AES-GCM
            // seal above). Gated: signalEnvelopeMapIfEnabled returns null when the domain
            // gate is off, so this is inert in production until the flip.
            AndroidCloudVaultSignalPayloads.signalEnvelopeMapIfEnabled(
                AndroidCloudVaultSignalPayloads.SignalEnvelopeMapRequest(
                    domainID = SIGNAL_CLI_DOMAIN,
                    uid = signal.uid,
                    collection = signal.collection,
                    docId = signal.docId,
                    plaintext = missionCloudJson.encodeToString(privatePayload).toByteArray(Charsets.UTF_8),
                    localIdentity = signal.localIdentity,
                    otherRecipients = signal.otherRecipients,
                ),
            )?.let { sealed["signalEnvelope"] = it }
        }
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
fun DocumentSnapshot.toMissionSnapshotOrNull(
    vaultKey: ByteArray? = null,
    uid: String? = null,
    signalIdentity: AndroidSignalIdentityKeypair? = null,
    trustedSenderPublicKeys: Map<String, ByteArray> = emptyMap(),
): CLIAgentMissionSnapshot? = toMissionSnapshot(
    fallbackID = id,
    vaultKey = vaultKey,
    uid = uid,
    signalIdentity = signalIdentity,
    trustedSenderPublicKeys = trustedSenderPublicKeys,
)

/**
 * Signal-first open of a mission request doc's private payload. Returns null when no envelope is
 * present, uid/identity is missing, or a failure is legacy-fallback-eligible — so the caller falls
 * through to the legacy AES-GCM opener (rollout compatibility, matching iOS). RR-7a sender-auth:
 * a stripped/forged/untrusted sender block or a relocated binding throws here (re-thrown) so the
 * caller fails closed rather than decoding the unauthenticated legacy payload.
 */
private fun DocumentSnapshot.openSignalMissionPayload(
    uid: String?,
    docId: String,
    signalIdentity: AndroidSignalIdentityKeypair?,
    trustedSenderPublicKeys: Map<String, ByteArray>,
): AndroidMissionPrivatePayload? {
    if (get("signalEnvelope") == null || uid == null) return null
    val senderSetComplete = trustedSenderPublicKeys.size > 1
    val result =
        runCatching {
            AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                data = data ?: emptyMap(),
                uid = uid,
                collection = "cli_agent_mission_requests",
                docId = docId,
                localIdentity = signalIdentity,
                trustedSenderPublicKeys = trustedSenderPublicKeys,
            )?.let { missionCloudJson.decodeFromString<AndroidMissionPrivatePayload>(it.toString(Charsets.UTF_8)) }
        }
    result.getOrNull()?.let { return it }
    result.exceptionOrNull()?.let { error ->
        if (!SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback(error, senderSetComplete)) throw error
    }
    return null
}

private fun DocumentSnapshot.toMissionSnapshot(
    fallbackID: String,
    eventOverride: List<CLIAgentMissionEvent>? = null,
    vaultKey: ByteArray? = null,
    uid: String? = null,
    signalIdentity: AndroidSignalIdentityKeypair? = null,
    trustedSenderPublicKeys: Map<String, ByteArray> = emptyMap(),
): CLIAgentMissionSnapshot? {
    val missionDocId = getString("id") ?: fallbackID
    // Signal-first open of the request private payload (item 3). RR-7a sender-auth: a
    // stripped/forged/untrusted sender block or relocated binding fails closed (no legacy decode);
    // a legacy-eligible failure (gate off / identity unavailable / malformed) falls back — matches iOS.
    val requestPrivate = requestPrivatePayload(uid, missionDocId, signalIdentity, vaultKey, trustedSenderPublicKeys)
    val statePrivate = openMissionPayload(get("sealedStatePayload"), vaultKey, missionStateAadContext(uid, missionDocId))
    val title = missionSnapshotTitle(requestPrivate) ?: return null
    val status = getString("status") ?: return null
    val events = eventOverride ?: missionSnapshotEvents(vaultKey)
    return CLIAgentMissionSnapshot(
        id = getString("id") ?: fallbackID,
        title = title,
        status = status,
        requestedRuntime = getString("requestedRuntime") ?: "auto",
        requestedModelID = getString("requestedModelID")?.trim()?.takeIf { it.isNotEmpty() },
        selectedRuntime = getString("selectedRuntime"),
        selectedRuntimeName = getString("selectedRuntimeName"),
        selectedModelID = getString("selectedModelID")?.trim()?.takeIf { it.isNotEmpty() },
        targetProject = missionSnapshotTargetProject(requestPrivate),
        sourceSkillID = getString("sourceSkillID")?.trim()?.takeIf { it.isNotEmpty() },
        sourceSurface = getString("sourceSurface")?.trim()?.takeIf { it.isNotEmpty() },
        deliveryMode = SkillRunDeliveryMode.fromWire(getString("deliveryMode")),
        parentHermesThreadID = getString("parentHermesThreadID")?.trim()?.takeIf { it.isNotEmpty() },
        liveSummary = missionSnapshotText(statePrivate, requestPrivate, "liveSummary"),
        resultPreview = missionSnapshotText(statePrivate, requestPrivate, "resultPreview"),
        errorMessage = missionSnapshotText(statePrivate, requestPrivate, "errorMessage"),
        sessionID = getString("sessionId"),
        approvalRequestId = getString("approvalRequestId"),
        approvalStatus = getString("approvalStatus"),
        approvalTitle = missionSnapshotText(statePrivate, requestPrivate, "approvalTitle"),
        approvalMessage = missionSnapshotText(statePrivate, requestPrivate, "approvalMessage"),
        events = events.sortedWith(compareBy<CLIAgentMissionEvent> { it.sequence }.thenBy { it.timestamp }),
        createdAt = getString("createdAt")?.let { runCatching { Instant.parse(it) }.getOrNull() },
    )
}

private fun DocumentSnapshot.requestPrivatePayload(
    uid: String?,
    missionDocId: String,
    signalIdentity: AndroidSignalIdentityKeypair?,
    vaultKey: ByteArray?,
    trustedSenderPublicKeys: Map<String, ByteArray>,
): AndroidMissionPrivatePayload? = openSignalMissionPayload(uid, missionDocId, signalIdentity, trustedSenderPublicKeys)
    ?: openMissionPayload(get("sealedPayload"), vaultKey, missionRequestAadContext(uid, missionDocId))

private fun DocumentSnapshot.missionSnapshotTitle(requestPrivate: AndroidMissionPrivatePayload?): String? = requestPrivate?.title ?: getString("title")

private fun DocumentSnapshot.missionSnapshotEvents(vaultKey: ByteArray?): List<CLIAgentMissionEvent> {
    val rawEvents = get("events") as? List<*> ?: emptyList<Any>()
    return rawEvents.mapNotNull { raw ->
        val map = raw as? Map<*, *> ?: return@mapNotNull null
        map.toMissionEvent(vaultKey)
    }
}

private fun DocumentSnapshot.missionSnapshotTargetProject(requestPrivate: AndroidMissionPrivatePayload?): String? =
    (requestPrivate?.targetProject ?: getString("targetProject"))?.trim()?.takeIf { it.isNotEmpty() }

private fun DocumentSnapshot.missionSnapshotText(
    statePrivate: AndroidMissionPrivatePayload?,
    requestPrivate: AndroidMissionPrivatePayload?,
    field: String,
): String? = when (field) {
    "liveSummary" -> statePrivate?.liveSummary ?: requestPrivate?.liveSummary ?: getString(field)
    "resultPreview" -> statePrivate?.resultPreview ?: requestPrivate?.resultPreview ?: getString(field)
    "errorMessage" -> statePrivate?.errorMessage ?: requestPrivate?.errorMessage ?: getString(field)
    "approvalTitle" -> statePrivate?.approvalTitle ?: requestPrivate?.approvalTitle ?: getString(field)
    "approvalMessage" -> statePrivate?.approvalMessage ?: requestPrivate?.approvalMessage ?: getString(field)
    else -> getString(field)
}

private fun DocumentSnapshot.toMissionEvent(vaultKey: ByteArray? = null, uid: String? = null, requestID: String? = null): CLIAgentMissionEvent? =
    data?.toMissionEvent(vaultKey, uid, requestID, id)

private fun Map<*, *>.toMissionEvent(
    vaultKey: ByteArray? = null,
    uid: String? = null,
    requestID: String? = null,
    eventID: String? = null,
): CLIAgentMissionEvent? {
    val phase = this["phase"] as? String ?: return null
    val privatePayload = openMissionEventPayload(this["sealedPayload"], vaultKey, missionEventAadContext(uid, requestID, eventID))
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
