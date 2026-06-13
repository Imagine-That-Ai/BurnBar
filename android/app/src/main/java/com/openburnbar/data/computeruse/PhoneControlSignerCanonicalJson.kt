package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalResponse
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockCredentialEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockSession

object PhoneControlSignerCanonicalJson {
    fun canonicalIntentJson(intent: PhoneControlIntent): String {
        val fields = linkedMapOf<String, String>()
        intent.clientIntentId?.let { fields["clientIntentId"] = PhoneControlSignerJsonEncoding.quote(it) }
        intent.displayId?.let { fields["displayId"] = PhoneControlSignerJsonEncoding.quote(it) }
        fields["kind"] = PhoneControlSignerJsonEncoding.quote(intent.kind.wireValue)
        intent.key?.let { fields["key"] = PhoneControlSignerJsonEncoding.quote(it) }
        intent.modifiers?.let {
            fields["modifiers"] =
                it.joinToString(prefix = "[", postfix = "]") { item -> PhoneControlSignerJsonEncoding.quote(item) }
        }
        intent.mouseButton?.let { fields["mouseButton"] = it.toString() }
        intent.normalizedX?.let { fields["normalizedX"] = PhoneControlSignerJsonEncoding.number(it) }
        intent.normalizedX2?.let { fields["normalizedX2"] = PhoneControlSignerJsonEncoding.number(it) }
        intent.normalizedY?.let { fields["normalizedY"] = PhoneControlSignerJsonEncoding.number(it) }
        intent.normalizedY2?.let { fields["normalizedY2"] = PhoneControlSignerJsonEncoding.number(it) }
        intent.text?.let { fields["text"] = PhoneControlSignerJsonEncoding.quote(it) }
        return PhoneControlSignerJsonEncoding.sortedJson(fields)
    }

    fun canonicalAgentGrantRequestJson(request: HermesRealtimeRelayAgentGrantRequest): String {
        val fields = linkedMapOf<String, String>()
        fields["capabilities"] =
            request.capabilities.sorted()
                .joinToString(separator = ",", prefix = "[", postfix = "]") { PhoneControlSignerJsonEncoding.quote(it) }
        fields["clientIntentId"] = PhoneControlSignerJsonEncoding.quote(request.clientIntentId)
        fields["deliveryMode"] = PhoneControlSignerJsonEncoding.quote(request.deliveryMode)
        fields["expiresAt"] = PhoneControlSignerJsonEncoding.number(request.expiresAt)
        fields["grantDurationSeconds"] = PhoneControlSignerJsonEncoding.number(request.grantDurationSeconds)
        fields["localAuthenticationSatisfied"] = request.localAuthenticationSatisfied.toString()
        fields["preset"] = PhoneControlSignerJsonEncoding.quote(request.preset)
        fields["requestedAt"] = PhoneControlSignerJsonEncoding.number(request.requestedAt)
        fields["requestId"] = PhoneControlSignerJsonEncoding.quote(request.requestId)
        fields["runtime"] = PhoneControlSignerJsonEncoding.quote(request.runtime)
        fields["sourceDeviceId"] = PhoneControlSignerJsonEncoding.quote(request.sourceDeviceId)
        fields["threadId"] = PhoneControlSignerJsonEncoding.quote(request.threadId)
        fields["trustMode"] = PhoneControlSignerJsonEncoding.quote(request.trustMode)
        return PhoneControlSignerJsonEncoding.sortedJson(fields)
    }

    fun canonicalApprovalRequestJson(request: HermesRealtimeRelayApprovalRequest): String {
        val fields = linkedMapOf<String, String>()
        fields["actionSummary"] = PhoneControlSignerJsonEncoding.quote(request.actionSummary)
        fields["approvalId"] = PhoneControlSignerJsonEncoding.quote(request.approvalId)
        request.beforeScreenshotBlake3?.let { fields["beforeScreenshotBlake3"] = PhoneControlSignerJsonEncoding.quote(it) }
        request.beforeScreenshotMimeType?.let { fields["beforeScreenshotMimeType"] = PhoneControlSignerJsonEncoding.quote(it) }
        request.beforeScreenshotSizeBytes?.let { fields["beforeScreenshotSizeBytes"] = it.toString() }
        fields["message"] = PhoneControlSignerJsonEncoding.quote(request.message)
        fields["requestedAt"] = PhoneControlSignerJsonEncoding.number(request.requestedAt)
        fields["runId"] = PhoneControlSignerJsonEncoding.quote(request.runId)
        fields["sessionId"] = PhoneControlSignerJsonEncoding.quote(request.sessionId)
        fields["title"] = PhoneControlSignerJsonEncoding.quote(request.title)
        fields["toolKind"] = PhoneControlSignerJsonEncoding.quote(request.toolKind)
        request.trustMode?.let { fields["trustMode"] = PhoneControlSignerJsonEncoding.quote(it) }
        return PhoneControlSignerJsonEncoding.sortedJson(fields)
    }

    fun canonicalApprovalResponseJson(response: HermesRealtimeRelayApprovalResponse): String {
        val fields = linkedMapOf<String, String>()
        fields["approvalId"] = PhoneControlSignerJsonEncoding.quote(response.approvalId)
        fields["decision"] = PhoneControlSignerJsonEncoding.quote(response.decision.wireValue())
        response.note?.let { fields["note"] = PhoneControlSignerJsonEncoding.quote(it) }
        response.requestHashBlake3?.let { fields["requestHashBlake3"] = PhoneControlSignerJsonEncoding.quote(it) }
        fields["respondedAt"] = PhoneControlSignerJsonEncoding.number(response.respondedAt)
        fields["respondedBy"] = PhoneControlSignerJsonEncoding.quote(response.respondedBy)
        return PhoneControlSignerJsonEncoding.sortedJson(fields)
    }

    fun canonicalClipboardRequestJson(request: PhoneControlClipboardRequest): String {
        val fields = linkedMapOf<String, String>()
        fields["action"] = PhoneControlSignerJsonEncoding.quote(request.action.wireValue)
        fields["clientIntentId"] = PhoneControlSignerJsonEncoding.quote(request.clientIntentId.orEmpty())
        fields["contentType"] = PhoneControlSignerJsonEncoding.quote(request.contentType)
        fields["maxBytes"] = request.maxBytes.toString()
        fields["requestId"] = PhoneControlSignerJsonEncoding.quote(request.requestId)
        request.text?.let { fields["text"] = PhoneControlSignerJsonEncoding.quote(it) }
        return PhoneControlSignerJsonEncoding.sortedJson(fields)
    }

    fun canonicalRemoteUnlockSessionJson(session: HermesRealtimeRelayRemoteUnlockSession): String {
        val fields = linkedMapOf<String, String>()
        fields["expiresAt"] = PhoneControlSignerJsonEncoding.number(PhoneControlSignerJsonEncoding.swiftReferenceSecondsFromIso8601(session.expiresAt))
        fields["intent"] = PhoneControlSignerJsonEncoding.quote(session.intent.wireValue())
        fields["localAuthenticationSatisfied"] = session.localAuthenticationSatisfied.toString()
        session.requestedBackend?.let { fields["requestedBackend"] = PhoneControlSignerJsonEncoding.quote(it.wireValue()) }
        fields["requestedAt"] = PhoneControlSignerJsonEncoding.number(PhoneControlSignerJsonEncoding.swiftReferenceSecondsFromIso8601(session.requestedAt))
        session.requestedLockState?.let { fields["requestedLockState"] = PhoneControlSignerJsonEncoding.quote(it.wireValue()) }
        fields["requesterDisplayName"] = PhoneControlSignerJsonEncoding.quote(session.requesterDisplayName)
        fields["requestId"] = PhoneControlSignerJsonEncoding.quote(session.requestId)
        session.sessionId?.let { fields["sessionId"] = PhoneControlSignerJsonEncoding.quote(it) }
        session.viewerDeviceId?.let { fields["viewerDeviceId"] = PhoneControlSignerJsonEncoding.quote(it) }
        return PhoneControlSignerJsonEncoding.sortedJson(fields)
    }

    fun canonicalRemoteUnlockCredentialJson(credential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope): String {
        val fields = linkedMapOf<String, String>()
        fields["aadBase64"] = PhoneControlSignerJsonEncoding.quote(credential.aadBase64)
        fields["algorithm"] = PhoneControlSignerJsonEncoding.quote(credential.algorithm)
        fields["ciphertextBase64"] = PhoneControlSignerJsonEncoding.quote(credential.ciphertextBase64)
        fields["clientIntentId"] = PhoneControlSignerJsonEncoding.quote(credential.clientIntentId)
        fields["credentialKind"] = PhoneControlSignerJsonEncoding.quote(credential.credentialKind.wireValue())
        fields["expiresAt"] = PhoneControlSignerJsonEncoding.number(PhoneControlSignerJsonEncoding.swiftReferenceSecondsFromIso8601(credential.expiresAt))
        fields["recipientKeyId"] = PhoneControlSignerJsonEncoding.quote(credential.recipientKeyId)
        fields["redactedByteCount"] = credential.redactedByteCount.toString()
        fields["requestedAt"] = PhoneControlSignerJsonEncoding.number(PhoneControlSignerJsonEncoding.swiftReferenceSecondsFromIso8601(credential.requestedAt))
        fields["requestId"] = PhoneControlSignerJsonEncoding.quote(credential.requestId)
        fields["sessionId"] = PhoneControlSignerJsonEncoding.quote(credential.sessionId)
        return PhoneControlSignerJsonEncoding.sortedJson(fields)
    }

    fun canonicalAgentContextTargetJson(target: PhoneControlAgentContextTarget): String {
        val fields = linkedMapOf<String, String>()
        fields["clientIntentId"] = PhoneControlSignerJsonEncoding.quote(target.clientIntentId)
        target.displayId?.let { fields["displayId"] = PhoneControlSignerJsonEncoding.quote(it) }
        fields["instruction"] = PhoneControlSignerJsonEncoding.quote(target.instruction)
        fields["normalizedX"] = PhoneControlSignerJsonEncoding.number(target.normalizedX)
        fields["normalizedY"] = PhoneControlSignerJsonEncoding.number(target.normalizedY)
        fields["requestedAt"] = PhoneControlSignerJsonEncoding.number(target.requestedAt)
        fields["requestId"] = PhoneControlSignerJsonEncoding.quote(target.requestId)
        fields["runtime"] = PhoneControlSignerJsonEncoding.quote(target.runtime)
        target.sessionId?.let { fields["sessionId"] = PhoneControlSignerJsonEncoding.quote(it) }
        target.threadId?.let { fields["threadId"] = PhoneControlSignerJsonEncoding.quote(it) }
        return PhoneControlSignerJsonEncoding.sortedJson(fields)
    }

    fun canonicalSystemPermissionRequestJson(request: PhoneControlSystemPermissionRequest): String {
        val fields = linkedMapOf<String, String>()
        fields["action"] = PhoneControlSignerJsonEncoding.quote(request.action.wireValue)
        request.bundleId?.let { fields["bundleId"] = PhoneControlSignerJsonEncoding.quote(it) }
        fields["clientIntentId"] = PhoneControlSignerJsonEncoding.quote(request.clientIntentId.orEmpty())
        fields["kind"] = PhoneControlSignerJsonEncoding.quote(request.kind.wireValue)
        request.originatingToolCallId?.let { fields["originatingToolCallId"] = PhoneControlSignerJsonEncoding.quote(it) }
        request.originatingToolName?.let { fields["originatingToolName"] = PhoneControlSignerJsonEncoding.quote(it) }
        fields["requestedAt"] = PhoneControlSignerJsonEncoding.number(request.requestedAtSwiftReferenceSeconds)
        fields["requestId"] = PhoneControlSignerJsonEncoding.quote(request.requestId)
        return PhoneControlSignerJsonEncoding.sortedJson(fields)
    }

    private fun HermesRealtimeRelayApprovalResponse.Decision.wireValue(): String = when (this) {
        HermesRealtimeRelayApprovalResponse.Decision.APPROVE -> "approve"
        HermesRealtimeRelayApprovalResponse.Decision.REJECT -> "reject"
        HermesRealtimeRelayApprovalResponse.Decision.REJECT_AND_HALT -> "reject_and_halt"
    }
}
