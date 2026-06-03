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

    suspend fun registerEscrowDevice(
        deviceId: String,
        deviceName: String,
        platform: String,
        appVersion: String? = null,
        publicKeyFingerprint: String? = null,
        keyVersion: Int? = null,
    ) {
        requireAuthenticatedUser()
        val payload =
            linkedMapOf<String, Any>(
                "deviceId" to deviceId,
                "deviceName" to deviceName,
                "platform" to platform,
            )
        appVersion?.takeIf { it.isNotBlank() }?.let { payload["appVersion"] = it }
        publicKeyFingerprint?.takeIf { it.isNotBlank() }?.let { payload["publicKeyFingerprint"] = it }
        keyVersion?.let { payload["keyVersion"] = it }
        val result = functions.getHttpsCallable("registerEscrowDevice").call(payload).await()
        requireOk(result.getData(), "Escrow device registration failed.")
    }

    suspend fun approveEscrowDeviceTrust(deviceId: String, approverDeviceId: String? = null) {
        requireAuthenticatedUser()
        val payload = mutableMapOf<String, Any>("deviceId" to deviceId)
        approverDeviceId?.takeIf { it.isNotBlank() }?.let { payload["approverDeviceId"] = it }
        val result =
            functions.getHttpsCallable("approveEscrowDeviceTrust")
                .call(payload)
                .await()
        requireOk(result.getData(), "Escrow device trust approval failed.")
    }

    suspend fun revokeEscrowDeviceTrust(deviceId: String) {
        requireAuthenticatedUser()
        val result =
            functions.getHttpsCallable("revokeEscrowDeviceTrust")
                .call(mapOf("deviceId" to deviceId))
                .await()
        requireOk(result.getData(), "Escrow device trust revocation failed.")
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
