package com.openburnbar.data.computeruse

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import kotlinx.coroutines.tasks.await

/**
 * WS4 Android client for App Check attestation binding and escrow device trust callables.
 */
class ComputerUseSecurityCallableClient(
    private val functions: FirebaseFunctions = Firebase.functions("us-central1"),
) {
    suspend fun bindAppCheckAttestation() {
        requireAuthenticatedUser()
        functions.getHttpsCallable("bindAppCheckAttestation").call(emptyMap<String, Any>()).await()
        refreshAuthClaimsAfterBind()
    }

    /**
     * Fetch a single-use, short-lived nonce to attach to a high-risk action,
     * providing replay resistance on top of the 30-day attestation binding.
     */
    suspend fun issueHighRiskActionNonce(): String {
        requireAuthenticatedUser()
        val result =
            functions.getHttpsCallable("issueHighRiskActionNonce")
                .call(emptyMap<String, Any>())
                .await()
        val map = result.getData() as? Map<*, *> ?: error("Could not obtain a high-risk action nonce.")
        val nonce = map["nonce"] as? String
        check(!nonce.isNullOrEmpty()) { "Could not obtain a high-risk action nonce." }
        return nonce
    }

    suspend fun registerEscrowDevice(
        deviceId: String,
        deviceName: String,
        platform: String,
        appVersion: String? = null,
        publicKeyFingerprint: String? = null,
        keyVersion: Int? = null,
    ) {
        requireAuthenticatedUser()
        val nonce = issueHighRiskActionNonce()
        val payload =
            linkedMapOf<String, Any>(
                "deviceId" to deviceId,
                "deviceName" to deviceName,
                "platform" to platform,
                "nonce" to nonce,
            )
        appVersion?.takeIf { it.isNotBlank() }?.let { payload["appVersion"] = it }
        publicKeyFingerprint?.takeIf { it.isNotBlank() }?.let { payload["publicKeyFingerprint"] = it }
        keyVersion?.let { payload["keyVersion"] = it }
        val result = functions.getHttpsCallable("registerEscrowDevice").call(payload).await()
        requireOk(result.getData(), "Escrow device registration failed.")
    }

    suspend fun approveEscrowDeviceTrust(
        deviceId: String,
        approverDeviceId: String? = null,
        trustChain: Map<String, Any>? = null,
    ) {
        requireAuthenticatedUser()
        val nonce = issueHighRiskActionNonce()
        val payload = mutableMapOf<String, Any>("deviceId" to deviceId, "nonce" to nonce)
        approverDeviceId?.takeIf { it.isNotBlank() }?.let { payload["approverDeviceId"] = it }
        trustChain?.let { payload["trustChain"] = it }
        val result =
            functions.getHttpsCallable("approveEscrowDeviceTrust")
                .call(payload)
                .await()
        requireOk(result.getData(), "Escrow device trust approval failed.")
    }

    suspend fun revokeEscrowDeviceTrust(deviceId: String) {
        requireAuthenticatedUser()
        bindAppCheckAttestation()
        val nonce = issueHighRiskActionNonce()
        val result =
            functions.getHttpsCallable("revokeEscrowDeviceTrust")
                .call(mapOf("deviceId" to deviceId, "nonce" to nonce))
                .await()
        requireOk(result.getData(), "Escrow device trust revocation failed.")
    }

    suspend fun publishPhoneControlAuthority(authority: PhoneControlAuthorityDoc) {
        requireAuthenticatedUser()
        bindAppCheckAttestation()
        val nonce = issueHighRiskActionNonce()
        val result =
            functions.getHttpsCallable("publishPhoneControlAuthority")
                .call(
                    mapOf(
                        "deviceId" to authority.deviceId,
                        "connectionId" to authority.connectionId,
                        "peerNodeId" to authority.peerNodeId,
                        "publicKeyBase64" to authority.publicKeyBase64,
                        "publishedAtMillis" to authority.publishedAtMillis,
                        "protocolVersion" to authority.protocolVersion,
                        "nonce" to nonce,
                    ),
                )
                .await()
        requireOk(result.getData(), "Phone-control authority publication failed.")
    }

    suspend fun publishRelaySenderKey(
        deviceId: String,
        peerNodeId: String,
        keyId: String,
        publicKeyBase64: String,
        relayKeyVersion: Int,
        publishedAtMillis: Long,
        signalIdentityKeyId: String,
        signalIdentityKeyVersion: Int,
        signalIdentityPublicKeyFingerprint: String,
    ) {
        requireAuthenticatedUser()
        bindAppCheckAttestation()
        val nonce = issueHighRiskActionNonce()
        val result =
            functions.getHttpsCallable("publishRelaySenderKey")
                .call(
                    mapOf(
                        "deviceId" to deviceId,
                        "peerNodeId" to peerNodeId,
                        "keyId" to keyId,
                        "publicKeyBase64" to publicKeyBase64,
                        "relayKeyVersion" to relayKeyVersion,
                        "publishedAtMillis" to publishedAtMillis,
                        "signalIdentityKeyId" to signalIdentityKeyId,
                        "signalIdentityKeyVersion" to signalIdentityKeyVersion,
                        "signalIdentityPublicKeyFingerprint" to signalIdentityPublicKeyFingerprint,
                        "nonce" to nonce,
                    ),
                )
                .await()
        requireOk(result.getData(), "Relay sender-key publication failed.")
    }

    suspend fun publishAgentGrantAuthority(
        deviceId: String,
        peerNodeId: String,
        publicKeyBase64: String,
    ) {
        requireAuthenticatedUser()
        bindAppCheckAttestation()
        val nonce = issueHighRiskActionNonce()
        val result =
            functions.getHttpsCallable("publishAgentGrantAuthority")
                .call(
                    mapOf(
                        "deviceId" to deviceId,
                        "peerNodeId" to peerNodeId,
                        "publicKeyBase64" to publicKeyBase64,
                        "nonce" to nonce,
                    ),
                )
                .await()
        requireOk(result.getData(), "Agent grant authority publication failed.")
    }

    suspend fun queueAgentCapabilityGrantRequest(payload: Map<String, Any>) {
        requireAuthenticatedUser()
        bindAppCheckAttestation()
        val nonce = issueHighRiskActionNonce()
        val result =
            functions.getHttpsCallable("queueAgentCapabilityGrantRequest")
                .call(payload + mapOf("nonce" to nonce))
                .await()
        requireOk(result.getData(), "Agent grant request queueing failed.")
    }

    /**
     * Bind a CLI-agent mission approve/reject decision to this trusted native
     * escrow device via the App-Check-enforced `respondMissionApproval` callable.
     */
    suspend fun respondMissionApproval(requestId: String, approve: Boolean, deviceId: String) {
        requireAuthenticatedUser()
        val result =
            functions.getHttpsCallable("respondMissionApproval")
                .call(
                    mapOf(
                        "requestId" to requestId,
                        "approve" to approve,
                        "deviceId" to deviceId,
                    ),
                )
                .await()
        requireOk(result.getData(), "Mission approval response failed.")
    }

    private suspend fun refreshAuthClaimsAfterBind() {
        val user =
            FirebaseAuth.getInstance().currentUser
                ?: error("Sign in before performing this Computer Use security action.")
        user.getIdToken(true).await()
    }

    private fun requireAuthenticatedUser() {
        val user = FirebaseAuth.getInstance().currentUser
        check(user != null && !user.isAnonymous) {
            "Sign in before performing this Computer Use security action."
        }
    }

    private fun requireOk(data: Any?, failureMessage: String) {
        val map = data as? Map<*, *> ?: error(failureMessage)
        check(map["ok"] == true) { failureMessage }
    }
}
