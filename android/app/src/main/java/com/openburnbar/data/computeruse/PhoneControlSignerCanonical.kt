package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalResponse
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockCredentialEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockSession

internal object PhoneControlSignerCanonical {
    fun intentHashHex(intent: PhoneControlIntent): String = hashJson(PhoneControlSignerCanonicalJson.canonicalIntentJson(intent))

    fun agentGrantRequestHashHex(request: HermesRealtimeRelayAgentGrantRequest): String =
        hashJson(PhoneControlSignerCanonicalJson.canonicalAgentGrantRequestJson(request))

    fun clipboardRequestHashHex(request: PhoneControlClipboardRequest): String =
        hashJson(PhoneControlSignerCanonicalJson.canonicalClipboardRequestJson(request))

    fun approvalRequestHashHex(request: HermesRealtimeRelayApprovalRequest): String =
        hashJson(PhoneControlSignerCanonicalJson.canonicalApprovalRequestJson(request))

    fun approvalResponseHashHex(response: HermesRealtimeRelayApprovalResponse): String =
        hashJson(PhoneControlSignerCanonicalJson.canonicalApprovalResponseJson(response))

    fun remoteUnlockSessionHashHex(session: HermesRealtimeRelayRemoteUnlockSession): String =
        hashJson(PhoneControlSignerCanonicalJson.canonicalRemoteUnlockSessionJson(session))

    fun remoteUnlockCredentialHashHex(credential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope): String =
        hashJson(PhoneControlSignerCanonicalJson.canonicalRemoteUnlockCredentialJson(credential))

    fun agentContextTargetHashHex(target: PhoneControlAgentContextTarget): String =
        hashJson(PhoneControlSignerCanonicalJson.canonicalAgentContextTargetJson(target))

    fun systemPermissionRequestHashHex(request: PhoneControlSystemPermissionRequest): String =
        hashJson(PhoneControlSignerCanonicalJson.canonicalSystemPermissionRequestJson(request))

    private fun hashJson(json: String): String = PhoneControlSignerJsonEncoding.sha256Hex(json.toByteArray(Charsets.UTF_8))
}
