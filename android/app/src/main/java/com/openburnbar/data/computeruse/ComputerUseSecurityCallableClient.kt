package com.openburnbar.data.computeruse

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import com.openburnbar.data.cloud.AndroidCloudVaultRevocationRotation
import kotlinx.coroutines.tasks.await

data class RelaySenderKeyPublishRequest(
    val deviceId: String,
    val peerNodeId: String,
    val keyId: String,
    val publicKeyBase64: String,
    val relayKeyVersion: Int,
    val publishedAtMillis: Long,
    val signalIdentityKeyId: String,
    val signalIdentityKeyVersion: Int,
    val signalIdentityPublicKeyFingerprint: String,
)

/**
 * RR-5 — the rotation signal surfaced by `revokeEscrowDeviceTrust`, the Android mirror of Swift
 * `ComputerUseSecurityCallableClient.EscrowDeviceTrustRevocationResult`. When
 * [cloudVaultRotationRequired] is true the survivor-side rotation chain (re-key + rewrap) must run;
 * [cloudVaultRotationCompleted] / [cloudVaultRotationFailureMessage] report its outcome.
 */
data class EscrowDeviceTrustRevocationResult(
    val revokedCloudVaultWrappers: Int = 0,
    val cloudVaultRotationRequired: Boolean = false,
    val cloudVaultRotationRequirementId: String? = null,
    val cloudVaultRotationBlockedReason: String? = null,
    val cloudVaultRotationJobId: String? = null,
    val cloudVaultRotationCompleted: Boolean = false,
    val cloudVaultRotationFailureMessage: String? = null,
    val cloudVaultRotationRewrappedDocuments: Int = 0,
    val cloudVaultRotationRewrappedStorageBlobs: Int = 0,
)

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

    /**
     * Revokes escrow device trust and active grants server-side, then — RR-5 — drives the Android
     * Cloud Vault rotation chain when the server's response signals it is required. Mirrors iOS
     * `ComputerUseSecurityCallableClient.revokeEscrowDeviceTrust`: surface the rotation fields instead
     * of discarding them, and when `cloudVaultRotationRequired` is set, generate the next vault key,
     * wrap it to survivors, call `rotateCloudVaultKey`, and run the document/storage rewrap. Pass the
     * rotating (surviving) device id so this device can finish the rotation; absent it the rotation is
     * reported blocked (the revocation itself still succeeded).
     */
    suspend fun revokeEscrowDeviceTrust(
        deviceId: String,
        rotatingDeviceId: String? = null,
        firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    ): EscrowDeviceTrustRevocationResult {
        val uid = requireAuthenticatedUser()
        bindAppCheckAttestation()
        val nonce = issueHighRiskActionNonce()
        val result =
            functions.getHttpsCallable("revokeEscrowDeviceTrust")
                .call(mapOf("deviceId" to deviceId, "nonce" to nonce))
                .await()
        val data = requireOk(result.getData(), "Escrow device trust revocation failed.")
        val revocation =
            EscrowDeviceTrustRevocationResult(
                revokedCloudVaultWrappers = (data["revokedCloudVaultWrappers"] as? Number)?.toInt() ?: 0,
                cloudVaultRotationRequired = data["cloudVaultRotationRequired"] as? Boolean ?: false,
                cloudVaultRotationRequirementId = data["cloudVaultRotationRequirementId"] as? String,
                cloudVaultRotationBlockedReason = data["cloudVaultRotationBlockedReason"] as? String,
            )
        if (!revocation.cloudVaultRotationRequired) return revocation
        val requirementId = revocation.cloudVaultRotationRequirementId
        if (requirementId.isNullOrEmpty() || rotatingDeviceId.isNullOrEmpty()) {
            return revocation.copy(
                cloudVaultRotationFailureMessage =
                    "Cloud Vault rotation is required, but this device's trusted device identity is unavailable.",
            )
        }
        return runCatching {
            val rotation =
                AndroidCloudVaultRevocationRotation.performRevocationCloudVaultRotation(
                    uid = uid,
                    requirementId = requirementId,
                    rotatingDeviceId = rotatingDeviceId,
                    functions = functions,
                    firestore = firestore,
                    issueNonce = { issueHighRiskActionNonce() },
                )
            revocation.copy(
                cloudVaultRotationJobId = rotation.jobId,
                cloudVaultRotationCompleted = true,
                cloudVaultRotationRewrappedDocuments = rotation.rewrappedDocuments,
                cloudVaultRotationRewrappedStorageBlobs = rotation.rewrappedStorageBlobs,
            )
        }.getOrElse { error ->
            revocation.copy(cloudVaultRotationFailureMessage = error.message ?: "Cloud Vault rotation failed.")
        }
    }

    /**
     * RR-5 pickup-on-launch — picks up any pending Cloud Vault rotation requirements this device is a
     * survivor for and runs the rotation chain locally. Mirrors iOS
     * `ComputerUseSecurityCallableClient.pickUpPendingCloudVaultRotations`: revocation normally rotates
     * from the revoking device, but when that device is offline (or runs a platform that cannot
     * rotate) the requirement stays pending; a surviving device finishes it on launch/foreground.
     */
    suspend fun pickUpPendingCloudVaultRotations(
        rotatingDeviceId: String,
        firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    ): AndroidCloudVaultRevocationRotation.PickupResult {
        val uid = requireAuthenticatedUser()
        val trimmed = rotatingDeviceId.trim()
        if (trimmed.isEmpty()) return AndroidCloudVaultRevocationRotation.PickupResult()
        val pending = listPendingCloudVaultRotationRequirements(trimmed)
        return AndroidCloudVaultRevocationRotation.runPickup(
            uid = uid,
            rotatingDeviceId = trimmed,
            pending = pending,
            functions = functions,
            firestore = firestore,
            issueNonce = { issueHighRiskActionNonce() },
        )
    }

    /**
     * Lists the user's pending Cloud Vault rotation requirements via the server-only callable, then
     * decodes them with [AndroidCloudVaultRevocationRotation.parsePendingRequirements].
     */
    suspend fun listPendingCloudVaultRotationRequirements(
        callerDeviceId: String,
    ): List<AndroidCloudVaultRevocationRotation.PendingRequirement> {
        val trimmed = callerDeviceId.trim()
        require(trimmed.isNotEmpty()) { "Could not list pending Cloud Vault rotation requirements." }
        requireAuthenticatedUser()
        val result =
            functions.getHttpsCallable("listPendingCloudVaultRotationRequirements")
                .call(AndroidCloudVaultRevocationRotation.listPendingCallablePayload(trimmed))
                .await()
        val data = result.getData() as? Map<*, *> ?: error("Could not list pending Cloud Vault rotation requirements.")
        val rawRequirements = data["requirements"] as? List<*> ?: error("Could not list pending Cloud Vault rotation requirements.")
        return AndroidCloudVaultRevocationRotation.parsePendingRequirements(rawRequirements)
    }

    suspend fun publishPhoneControlAuthority(authority: PhoneControlAuthorityDoc) {
        requireAuthenticatedUser()
        bindAppCheckAttestation()
        val nonce = issueHighRiskActionNonce()
        // F2: legacy publishes stay byte-identical (no keyKind field); an
        // SE-P256 identity sends the discriminator the server persists as
        // `signingKeyKind` (schemaVersion 3).
        val payload =
            buildMap<String, Any> {
                put("deviceId", authority.deviceId)
                put("connectionId", authority.connectionId)
                put("peerNodeId", authority.peerNodeId)
                put("publicKeyBase64", authority.publicKeyBase64)
                put("publishedAtMillis", authority.publishedAtMillis)
                put("protocolVersion", authority.protocolVersion)
                put("nonce", nonce)
                authority.keyKind?.let { put("keyKind", it) }
            }
        val result =
            functions.getHttpsCallable("publishPhoneControlAuthority")
                .call(payload)
                .await()
        requireOk(result.getData(), "Phone-control authority publication failed.")
    }

    suspend fun publishRelaySenderKey(request: RelaySenderKeyPublishRequest) {
        requireAuthenticatedUser()
        bindAppCheckAttestation()
        val nonce = issueHighRiskActionNonce()
        val result =
            functions.getHttpsCallable("publishRelaySenderKey")
                .call(
                    mapOf(
                        "deviceId" to request.deviceId,
                        "peerNodeId" to request.peerNodeId,
                        "keyId" to request.keyId,
                        "publicKeyBase64" to request.publicKeyBase64,
                        "relayKeyVersion" to request.relayKeyVersion,
                        "publishedAtMillis" to request.publishedAtMillis,
                        "signalIdentityKeyId" to request.signalIdentityKeyId,
                        "signalIdentityKeyVersion" to request.signalIdentityKeyVersion,
                        "signalIdentityPublicKeyFingerprint" to request.signalIdentityPublicKeyFingerprint,
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
        keyKind: String? = null,
    ) {
        requireAuthenticatedUser()
        bindAppCheckAttestation()
        val nonce = issueHighRiskActionNonce()
        // F2: omit keyKind entirely for legacy Ed25519 — the server treats
        // absence as `ed25519`, keeping pre-F2 publishes byte-identical.
        val payload =
            buildMap<String, Any> {
                put("deviceId", deviceId)
                put("peerNodeId", peerNodeId)
                put("publicKeyBase64", publicKeyBase64)
                put("nonce", nonce)
                keyKind?.let { put("keyKind", it) }
            }
        val result =
            functions.getHttpsCallable("publishAgentGrantAuthority")
                .call(payload)
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

    private fun requireAuthenticatedUser(): String {
        val user = FirebaseAuth.getInstance().currentUser
        check(user != null && !user.isAnonymous) {
            "Sign in before performing this Computer Use security action."
        }
        return user.uid
    }

    /**
     * Asserts the callable returned `ok: true` and returns the response map so callers can surface
     * the additional fields (e.g. the RR-5 `cloudVaultRotation*` rotation signal) instead of
     * discarding them — mirrors the Swift clients reading `dict[...]` after the `ok` guard.
     */
    private fun requireOk(data: Any?, failureMessage: String): Map<*, *> {
        val map = data as? Map<*, *> ?: error(failureMessage)
        check(map["ok"] == true) { failureMessage }
        return map
    }
}
