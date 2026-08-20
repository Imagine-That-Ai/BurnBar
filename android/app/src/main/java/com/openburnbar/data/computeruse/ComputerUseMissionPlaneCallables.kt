package com.openburnbar.data.computeruse

/**
 * Mission and BurnBar-attachment plane over the Computer Use security client.
 *
 * Every callable here rides [ComputerUseSecurityCallableClient.callHighRiskOwnerAction]
 * for the App-Check-enforced high-risk owner envelope; the client file itself keeps the
 * attestation, escrow-trust, and controller-route surface.
 */

suspend fun ComputerUseSecurityCallableClient.beginBurnbarAttachment(
    byteCount: Long,
    contentBlake3: String,
    deviceId: String,
    transport: String = "cloud",
): Map<*, *> = callHighRiskOwnerAction(
    callableName = "beginBurnbarAttachment",
    deviceId = deviceId,
    actionKind = "burnbar_attachment_begin",
    subjectId = "begin",
    payload = mapOf(
        "byteCount" to byteCount,
        "contentBlake3" to contentBlake3,
        "transport" to transport,
        "deviceId" to deviceId,
    ),
)

suspend fun ComputerUseSecurityCallableClient.mintBurnbarAttachmentPartURL(id: String, partIndex: Int, contentLength: Long, deviceId: String): String {
    val result =
        callHighRiskOwnerAction(
            callableName = "mintBurnbarAttachmentPartURL",
            deviceId = deviceId,
            actionKind = "burnbar_attachment_part",
            subjectId = id,
            payload = mapOf(
                "id" to id,
                "partIndex" to partIndex,
                "contentLength" to contentLength,
                "deviceId" to deviceId,
            ),
        )
    return result["url"] as? String ?: error("mintBurnbarAttachmentPartURL missing url")
}

suspend fun ComputerUseSecurityCallableClient.composeBurnbarAttachment(id: String, deviceId: String) {
    callHighRiskOwnerAction(
        callableName = "composeBurnbarAttachment",
        deviceId = deviceId,
        actionKind = "burnbar_attachment_compose",
        subjectId = id,
        payload = mapOf("id" to id, "deviceId" to deviceId),
    )
}

suspend fun ComputerUseSecurityCallableClient.finalizeBurnbarAttachment(id: String, deviceId: String) {
    callHighRiskOwnerAction(
        callableName = "finalizeBurnbarAttachment",
        deviceId = deviceId,
        actionKind = "burnbar_attachment_finalize",
        subjectId = id,
        payload = mapOf("id" to id, "deviceId" to deviceId),
    )
}

suspend fun ComputerUseSecurityCallableClient.createCliAgentMission(payload: Map<String, Any>, deviceId: String): String {
    val requestId = payload["requestId"] as? String ?: error("createCliAgentMission requires requestId.")
    val result =
        callHighRiskOwnerAction(
            callableName = "createCliAgentMission",
            deviceId = deviceId,
            actionKind = "cli_agent_mission_create",
            subjectId = requestId,
            payload = payload + ("deviceId" to deviceId),
        )
    return (result["requestId"] as? String)?.takeIf { it.isNotBlank() } ?: requestId
}

suspend fun ComputerUseSecurityCallableClient.cancelCliAgentMission(requestId: String, deviceId: String, sealedStatePayload: Map<String, Any>) {
    callHighRiskOwnerAction(
        callableName = "cancelCliAgentMission",
        deviceId = deviceId,
        actionKind = "cli_agent_mission_cancel",
        subjectId = requestId,
        payload =
        mapOf(
            "requestId" to requestId,
            "deviceId" to deviceId,
            "sealedStatePayload" to sealedStatePayload,
        ),
    )
}

/**
 * Bind a CLI-agent mission approve/reject decision to this trusted native
 * escrow device via the App-Check-enforced `respondMissionApproval` callable.
 */
suspend fun ComputerUseSecurityCallableClient.respondMissionApproval(requestId: String, approve: Boolean, deviceId: String) {
    callHighRiskOwnerAction(
        callableName = "respondMissionApproval",
        deviceId = deviceId,
        actionKind = "computer_use_mission_approval",
        subjectId = requestId,
        payload =
        mapOf(
            "requestId" to requestId,
            "approve" to approve,
            "deviceId" to deviceId,
        ),
        approve = approve,
    )
}

suspend fun ComputerUseSecurityCallableClient.redeemMissionApprovalAnswer(
    requestId: String,
    deviceId: String,
    ceilingDigest: String,
    requestedGrant: Map<String, Any>,
) {
    callHighRiskOwnerAction(
        callableName = "redeemMissionApprovalAnswer",
        deviceId = deviceId,
        actionKind = "mission_approval_answer_redeem",
        subjectId = "$requestId:$ceilingDigest:approve",
        payload =
        mapOf(
            "requestId" to requestId,
            "deviceId" to deviceId,
            "ceilingDigest" to ceilingDigest,
            "requestedGrant" to requestedGrant,
        ),
    )
}

suspend fun ComputerUseSecurityCallableClient.respondHermesGatewayApproval(approvalId: String, approve: Boolean, deviceId: String) {
    callHighRiskOwnerAction(
        callableName = "respondHermesGatewayApproval",
        deviceId = deviceId,
        actionKind = "hermes_gateway_approval",
        subjectId = approvalId,
        payload =
        mapOf(
            "approvalId" to approvalId,
            "approve" to approve,
            "deviceId" to deviceId,
        ),
        approve = approve,
    )
}
