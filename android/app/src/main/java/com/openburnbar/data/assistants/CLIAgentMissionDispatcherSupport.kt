package com.openburnbar.data.assistants

import com.google.firebase.firestore.FieldValue
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

internal val MISSION_CREATE_PUBLIC_KEYS = setOf(
    "id",
    "missionKind",
    "requestedRuntime",
    "requestedModelID",
    "depth",
    "approvalMode",
    "commandsAllowed",
    "fileEditsAllowed",
    "source",
    "sourceSkillID",
    "sourceSurface",
    "deliveryMode",
    "presentationMode",
    "parentHermesThreadID",
    "schemaVersion",
    "groupID",
    "siblingIndex",
    "siblingCount",
    "isGroupChild",
    "personaID",
    "clientThreadID",
    "parentSessionID",
    "resumeAction",
    "originatorKind",
    "originatorRef",
    "targetBodyID",
)

internal data class MissionCreateLeaf(
    val requestId: String,
    val remoteCommandID: String,
    val publicFields: Map<String, Any>,
    val sealedPayload: Map<String, Any>,
    val signalEnvelope: Map<String, Any>?,
    val initialEvent: Map<String, Any>,
) {
    fun toCallableMap(deviceId: String): Map<String, Any> {
        val out = linkedMapOf<String, Any>(
            "requestId" to requestId,
            "remoteCommandID" to remoteCommandID,
            "deviceId" to deviceId,
            "publicFields" to publicFields,
            "sealedPayload" to sealedPayload,
            "initialEvent" to initialEvent,
        )
        if (signalEnvelope != null) out["signalEnvelope"] = signalEnvelope
        return out
    }
}

internal fun publicFieldsForCreate(payload: Map<String, Any>, requestId: String): Map<String, Any> {
    val out = linkedMapOf<String, Any>("id" to requestId)
    for (key in MISSION_CREATE_PUBLIC_KEYS) {
        if (key == "id") continue
        val value = payload[key] ?: continue
        if (value is FieldValue) continue
        out[key] = value
    }
    return out
}

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

internal fun buildFanOutChildLeaves(request: FanOutChildWriteRequest): List<MissionCreateLeaf> {
    return request.runtimeTokens.mapIndexed { index, runtimeToken ->
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
                uid = request.uid,
            ).toMutableMap().apply {
                put("groupID", request.plan.groupID)
                put("siblingIndex", index)
                put("siblingCount", request.runtimeTokens.size)
                put("isGroupChild", true)
            }
        val sealed = childPayload["sealedPayload"] as? Map<*, *>
            ?: throw DispatchException("Fan-out child $missionID is missing sealedPayload.")
        val event =
            CLIAgentMissionRequestPayloadFactory.initialQueuedEventSealed(
                sourceSkillID = request.sourceSkillID,
                deliveryMode = request.deliveryMode,
                key = request.key,
                uid = request.uid,
                requestID = missionID,
                eventID = "000001",
            )
        val initialEvent = event["sealedPayload"] as? Map<*, *> ?: event
        MissionCreateLeaf(
            requestId = missionID,
            remoteCommandID = missionID,
            publicFields = publicFieldsForCreate(childPayload, missionID),
            sealedPayload = sealed.entries.associate { it.key.toString() to it.value as Any },
            signalEnvelope = (childPayload["signalEnvelope"] as? Map<*, *>)?.entries?.associate {
                it.key.toString() to it.value as Any
            },
            initialEvent = initialEvent.entries.associate { it.key.toString() to it.value as Any },
        )
    }
}

/** @deprecated Use [buildFanOutChildLeaves]; children persist only through createCliAgentMission. */
internal fun appendFanOutChildMissionWrites(request: FanOutChildWriteRequest): List<SignalMissionWrite> {
    return emptyList()
}
