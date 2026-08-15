package com.openburnbar.data.assistants

import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.WriteBatch
import com.openburnbar.data.cloud.AndroidCloudVaultResolvedKey
import com.openburnbar.data.cloud.AndroidSignalIdentityKeypair
import com.openburnbar.data.cloud.CloudVaultSignalRecipient
import java.time.Instant
import java.util.UUID

internal data class FanOutDispatchPlan(
    val groupID: String,
    val trimmedTitle: String,
    val trimmedPrompt: String,
    val childMissionIDs: List<String>,
    val now: String,
)

internal data class FanOutChildWriteRequest(
    val batch: WriteBatch,
    val firestore: FirebaseFirestore,
    val uid: String,
    val plan: FanOutDispatchPlan,
    val runtimeTokens: List<String>,
    val missionKind: String,
    val targetProject: String?,
    val depth: String,
    val approvalMode: String,
    val commandsAllowed: Boolean,
    val fileEditsAllowed: Boolean,
    val requestedModelIDsByRuntime: Map<String, String>,
    val sourceSkillID: String?,
    val sourceSurface: String?,
    val deliveryMode: SkillRunDeliveryMode,
    val parentHermesThreadID: String?,
    val key: AndroidCloudVaultResolvedKey,
    // At-rest Signal sealing material, resolved once in dispatchFanOut when the gate is on
    // (null/empty in production = inert). Each child builds its own docId-bound context.
    val signalIdentity: AndroidSignalIdentityKeypair? = null,
    val signalRecipients: List<CloudVaultSignalRecipient> = emptyList(),
)

internal data class SignalMissionWrite(
    val missionID: String,
    val payload: Map<String, Any>,
)

/**
 * The Signal callable owns the mission document write when at-rest Signal is
 * active. Removing the legacy AES siblings is deliberate: it keeps required
 * mode valid and prevents a direct Firestore batch from creating an unsealed
 * child before the callable has authenticated and validated the envelope.
 */
internal fun signalCallablePayload(payload: Map<String, Any>): Map<String, Any>? {
    if (payload["signalEnvelope"] == null) return null
    return payload.toMutableMap().apply {
        remove("contentSealed")
        remove("sealedSchemaVersion")
        remove("vaultKeyID")
        remove("sealedPayload")
        // FieldValue.serverTimestamp() cannot cross the callable JSON boundary;
        // the callable stamps updatedAt authoritatively on the server.
        remove("updatedAt")
    }
}

internal fun planFanOutDispatch(title: String, prompt: String, runtimeTokens: List<String>): FanOutDispatchPlan {
    val trimmedPrompt = prompt.trim()
    val trimmedTitle = title.trim().ifBlank { "Fan-out mission" }
    return FanOutDispatchPlan(
        groupID = "grp-${UUID.randomUUID()}",
        trimmedTitle = trimmedTitle,
        trimmedPrompt = trimmedPrompt,
        childMissionIDs = runtimeTokens.map { UUID.randomUUID().toString() },
        now = Instant.now().toString(),
    )
}

internal fun fanOutGroupPayload(
    plan: FanOutDispatchPlan,
    missionKind: String,
    targetProject: String?,
    runtimeTokens: List<String>,
    parallelismLimit: Int?,
    mergeStrategy: String,
): Map<String, Any> {
    val plim = (parallelismLimit ?: runtimeTokens.size).coerceAtLeast(1)
    return mapOf(
        "id" to plan.groupID,
        "title" to plan.trimmedTitle,
        "prompt" to plan.trimmedPrompt,
        "missionKind" to missionKind,
        "targetProject" to (targetProject ?: ""),
        "childMissionIDs" to plan.childMissionIDs,
        "runtimeTokens" to runtimeTokens,
        "parallelismLimit" to plim,
        "mergeStrategy" to mergeStrategy,
        "phase" to "queued",
        "winnerMissionID" to "",
        "forecast" to
            mapOf(
                "tokensLow" to 0,
                "tokensHigh" to 0,
                "costLowUSD" to 0.0,
                "costHighUSD" to 0.0,
                "etaLow" to 0.0,
                "etaHigh" to 0.0,
            ),
        "createdAt" to plan.now,
        "updatedAt" to plan.now,
        "schemaVersion" to 1,
        "source" to "android-hermes-square",
    )
}

private fun fanOutChildPayloadInput(request: FanOutChildWriteRequest, missionID: String, runtimeToken: String): CLIMissionPayloadInput = CLIMissionPayloadInput(
    core = CLIMissionPayloadCore(missionID, "${request.plan.trimmedTitle} · $runtimeToken", request.plan.trimmedPrompt, request.missionKind),
    execution = CLIMissionPayloadExecution(
        requestedRuntime = runtimeToken,
        targetProject = request.targetProject,
        depth = request.depth,
        approvalMode = request.approvalMode,
        requestedModelID = null,
    ),
    permissions = CLIMissionPayloadPermissions(request.commandsAllowed, request.fileEditsAllowed),
    metadata = CLIMissionPayloadMetadata(
        sourceSkillID = request.sourceSkillID,
        sourceSurface = request.sourceSurface,
        parentHermesThreadID = request.parentHermesThreadID,
    ),
    experience = CLIMissionPayloadExperience(deliveryMode = request.deliveryMode),
)

internal fun appendFanOutChildMissionWrites(request: FanOutChildWriteRequest): List<SignalMissionWrite> {
    val signalWrites = mutableListOf<SignalMissionWrite>()
    request.runtimeTokens.forEachIndexed { index, runtimeToken ->
        val missionID = request.plan.childMissionIDs[index]
        val payloadInput = fanOutChildPayloadInput(request = request, missionID = missionID, runtimeToken = runtimeToken)
        val childPayload =
            CLIAgentMissionRequestPayloadFactory.buildSealed(
                input = payloadInput,
                key = request.key,
                signal =
                request.signalIdentity?.let { identity ->
                    CLISignalSealContext(
                        uid = request.uid,
                        collection = "cli_agent_mission_requests",
                        docId = missionID,
                        localIdentity = identity,
                        otherRecipients = request.signalRecipients,
                    )
                },
            ).toMutableMap().apply {
                put("groupID", request.plan.groupID)
                put("siblingIndex", index)
                put("siblingCount", request.runtimeTokens.size)
                put("isGroupChild", true)
            }
        val requestRef =
            request.firestore.collection("users").document(request.uid)
                .collection("cli_agent_mission_requests").document(missionID)
        val signalPayload = signalCallablePayload(childPayload)
        if (request.signalIdentity != null && signalPayload == null) {
            throw DispatchException("Signal at-rest activation produced no mission envelope for $missionID.")
        }
        if (signalPayload != null) {
            signalWrites += SignalMissionWrite(missionID = missionID, payload = signalPayload)
        } else {
            request.batch.set(requestRef, childPayload.toMap())
        }
        request.batch.set(
            requestRef.collection("events").document("000001"),
            CLIAgentMissionRequestPayloadFactory.initialQueuedEventSealed(
                sourceSkillID = request.sourceSkillID,
                deliveryMode = request.deliveryMode,
                key = request.key,
            ),
        )
    }
    return signalWrites
}
