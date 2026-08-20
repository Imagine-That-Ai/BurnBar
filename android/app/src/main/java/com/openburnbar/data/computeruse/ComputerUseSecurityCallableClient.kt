package com.openburnbar.data.computeruse

import android.util.Base64
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.FirebaseFunctionsException
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.cloud.AndroidCloudVaultRevocationRotation
import com.openburnbar.data.cloud.AndroidSignalIdentityKeyStore
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.cloud.CloudVaultTrustedDeviceActionProof
import com.openburnbar.data.cloud.CloudVaultTrustedDeviceActionProofPayload
import com.openburnbar.data.cloud.CloudVaultTrustedDeviceActionProofSigner
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

internal suspend fun <T> callBoundToExpectedUid(expectedUid: String, currentUidProvider: () -> String, operation: suspend () -> T): T {
    check(currentUidProvider() == expectedUid) {
        "The signed-in account changed during this Computer Use security action."
    }
    val result = operation()
    check(currentUidProvider() == expectedUid) {
        "The signed-in account changed during this Computer Use security action."
    }
    return result
}

private fun isAppCheckBindingConflict(error: FirebaseFunctionsException): Boolean {
    val bindingGateCode =
        error.code == FirebaseFunctionsException.Code.PERMISSION_DENIED ||
            error.code == FirebaseFunctionsException.Code.FAILED_PRECONDITION
    if (!bindingGateCode) return false
    val message = error.message.orEmpty()
    return message.contains("App Check") || message.contains("bindAppCheckAttestation")
}

/**
 * WS4 Android client for App Check attestation binding and escrow device trust callables.
 */
class ComputerUseSecurityCallableClient(
    private val functions: FirebaseFunctions = Firebase.functions("us-central1"),
) : IrohControllerRouteCallables, PhoneControlAuthorityPublishingCallables {
    private val relaySenderProofProtocolVersion = "3"

    suspend fun bindAppCheckAttestation(expectedUid: String? = null) {
        val boundUid = requireAuthenticatedUser(expectedUid)
        functions.getHttpsCallable("bindAppCheckAttestation").call(emptyMap<String, Any>()).await()
        requireAuthenticatedUser(boundUid)
        refreshAuthClaimsAfterBind(boundUid)
    }

    /**
     * Fetch a single-use, short-lived nonce to attach to a high-risk action,
     * providing replay resistance on top of the 30-day attestation binding.
     */
    suspend fun issueHighRiskActionNonce(expectedUid: String? = null): String {
        val boundUid = requireAuthenticatedUser(expectedUid)
        val result =
            functions.getHttpsCallable("issueHighRiskActionNonce")
                .call(emptyMap<String, Any>())
                .await()
        val map = result.getData() as? Map<*, *> ?: error("Could not obtain a high-risk action nonce.")
        val nonce = map["nonce"] as? String
        check(!nonce.isNullOrEmpty()) { "Could not obtain a high-risk action nonce." }
        requireAuthenticatedUser(boundUid)
        return nonce
    }

    /**
     * Auth custom claims are account-level, so another signed-in platform can overwrite the
     * `obb_app_check` binding between our bind and the nonce mint. Re-run the full
     * bind -> claims refresh -> nonce sequence once when the mint is rejected at the
     * App Check binding gate; rethrow every other failure unchanged.
     */
    private suspend fun reboundHighRiskActionNonce(bindingConflict: FirebaseFunctionsException): String {
        if (!isAppCheckBindingConflict(bindingConflict)) throw bindingConflict
        bindAppCheckAttestation()
        return issueHighRiskActionNonce()
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
        bindAppCheckAttestation()
        val nonce =
            try {
                issueHighRiskActionNonce()
            } catch (error: FirebaseFunctionsException) {
                reboundHighRiskActionNonce(bindingConflict = error)
            }
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

    suspend fun approveEscrowDeviceTrust(deviceId: String, approverDeviceId: String? = null, trustChain: Map<String, Any>? = null) {
        requireAuthenticatedUser()
        bindAppCheckAttestation()
        val nonce =
            try {
                issueHighRiskActionNonce()
            } catch (error: FirebaseFunctionsException) {
                reboundHighRiskActionNonce(bindingConflict = error)
            }
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
    suspend fun listPendingCloudVaultRotationRequirements(callerDeviceId: String): List<AndroidCloudVaultRevocationRotation.PendingRequirement> {
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
        publishPhoneControlAuthority(expectedUid = requireAuthenticatedUser(), authority = authority)
    }

    override suspend fun publishPhoneControlAuthority(expectedUid: String, authority: PhoneControlAuthorityDoc) {
        requireAuthenticatedUser(expectedUid)
        bindAppCheckAttestation(expectedUid)
        val nonce = issueHighRiskActionNonce(expectedUid)
        // F2: legacy publishes stay byte-identical (no keyKind field); an
        // SE-P256 identity sends the discriminator the server persists as
        // `signingKeyKind` (schemaVersion 3).
        val payload =
            buildMap<String, Any> {
                put("deviceId", authority.deviceId)
                put("expectedUid", expectedUid)
                put("connectionId", authority.connectionId)
                put("peerNodeId", authority.peerNodeId)
                put("publicKeyBase64", authority.publicKeyBase64)
                put("publishedAtMillis", authority.publishedAtMillis)
                put("protocolVersion", authority.protocolVersion)
                put("nonce", nonce)
                authority.keyKind?.let { put("keyKind", it) }
            }
        val result = callBoundToExpectedUid(expectedUid, { requireAuthenticatedUser() }) {
            functions.getHttpsCallable("publishPhoneControlAuthority").call(payload).await()
        }
        requireOk(result.getData(), "Phone-control authority publication failed.")
    }

    override suspend fun issueIrohControllerRouteChallenge(
        expectedUid: String,
        sourceDeviceId: String,
        connectionId: String,
        authorityPeerNodeId: String,
        transportNodeId: String,
    ): IrohControllerRouteChallenge {
        requireAuthenticatedUser(expectedUid)
        bindAppCheckAttestation(expectedUid)
        val nonce = issueHighRiskActionNonce(expectedUid)
        val result = callBoundToExpectedUid(expectedUid, { requireAuthenticatedUser() }) {
            functions.getHttpsCallable("issueIrohControllerRouteChallenge")
                .call(
                    mapOf(
                        "expectedUid" to expectedUid,
                        "sourceDeviceId" to sourceDeviceId,
                        "connectionId" to connectionId,
                        "authorityPeerNodeId" to authorityPeerNodeId,
                        "transportNodeId" to transportNodeId,
                        "nonce" to nonce,
                    ),
                ).await()
        }
        val data = result.getData() as? Map<*, *> ?: error("Controller-route challenge issuance failed.")
        return IrohControllerRouteChallenge(
            challengeId = data.requiredString("challengeId", "Controller-route challenge issuance failed."),
            canonicalPayloadBase64 = data.requiredString("canonicalPayloadBase64", "Controller-route challenge issuance failed."),
            signatureAlgorithm = data.requiredString("signatureAlgorithm", "Controller-route challenge issuance failed."),
            proofKind = IrohControllerRouteProofKind.fromWireValue(
                data.requiredString("proofKind", "Controller-route challenge issuance failed."),
            ),
            requiresAuthorityProof = data.requiredBoolean(
                "requiresAuthorityProof",
                "Controller-route challenge issuance failed.",
            ),
            registrationGeneration = data.requiredLong("registrationGeneration", "Controller-route challenge issuance failed."),
            issuedAtMillis = data.requiredLong("issuedAtMillis", "Controller-route challenge issuance failed."),
            expiresAtMillis = data.requiredLong("expiresAtMillis", "Controller-route challenge issuance failed."),
        )
    }

    override suspend fun registerIrohControllerRoute(
        expectedUid: String,
        challengeId: String,
        transportSignatureBase64: String,
        authoritySignatureBase64: String?,
    ): IrohControllerRouteRegistration {
        requireAuthenticatedUser(expectedUid)
        val result = callBoundToExpectedUid(expectedUid, { requireAuthenticatedUser() }) {
            functions.getHttpsCallable("registerIrohControllerRoute")
                .call(
                    buildMap {
                        put("expectedUid", expectedUid)
                        put("challengeId", challengeId)
                        put("transportSignatureBase64", transportSignatureBase64)
                        authoritySignatureBase64?.let { put("authoritySignatureBase64", it) }
                    },
                )
                .await()
        }
        val data = requireOk(result.getData(), "Controller-route registration failed.")
        return IrohControllerRouteRegistration(
            connectionId = data.requiredString("connectionId", "Controller-route registration failed."),
            sourceDeviceId = data.requiredString("sourceDeviceId", "Controller-route registration failed."),
            transportNodeId = data.requiredString("transportNodeId", "Controller-route registration failed."),
            authorityPeerNodeId = data.requiredString("authorityPeerNodeId", "Controller-route registration failed."),
            generation = data.requiredLong("generation", "Controller-route registration failed."),
            expiresAtMillis = data.requiredLong("expiresAtMillis", "Controller-route registration failed."),
        )
    }

    override suspend fun revokeIrohControllerRoute(expectedUid: String, sourceDeviceId: String, connectionId: String): IrohControllerRouteRevocation {
        requireAuthenticatedUser(expectedUid)
        bindAppCheckAttestation(expectedUid)
        val nonce = issueHighRiskActionNonce(expectedUid)
        val result = callBoundToExpectedUid(expectedUid, { requireAuthenticatedUser() }) {
            functions.getHttpsCallable("revokeIrohControllerRoute")
                .call(
                    mapOf(
                        "expectedUid" to expectedUid,
                        "sourceDeviceId" to sourceDeviceId,
                        "connectionId" to connectionId,
                        "nonce" to nonce,
                    ),
                )
                .await()
        }
        val data = requireOk(result.getData(), "Controller-route revocation failed.")
        val revokedConnectionId = data.requiredString("connectionId", "Controller-route revocation failed.")
        val revokedSourceDeviceId = data.requiredString("sourceDeviceId", "Controller-route revocation failed.")
        val generation = data.requiredLong("generation", "Controller-route revocation failed.")
        check(revokedConnectionId == connectionId && revokedSourceDeviceId == sourceDeviceId && generation > 0L) {
            "Controller-route revocation failed."
        }
        return IrohControllerRouteRevocation(
            connectionId = revokedConnectionId,
            sourceDeviceId = revokedSourceDeviceId,
            generation = generation,
        )
    }

    suspend fun publishRelaySenderKey(request: RelaySenderKeyPublishRequest) {
        val subjectId = relaySenderKeyPublishProofSubjectId(request)
        val payload =
            linkedMapOf<String, Any>(
                "deviceId" to request.deviceId,
                "peerNodeId" to request.peerNodeId,
                "keyId" to request.keyId,
                "publicKeyBase64" to request.publicKeyBase64,
                "relayKeyVersion" to request.relayKeyVersion,
                "publishedAtMillis" to request.publishedAtMillis,
                "signalIdentityKeyId" to request.signalIdentityKeyId,
                "signalIdentityKeyVersion" to request.signalIdentityKeyVersion,
                "signalIdentityPublicKeyFingerprint" to request.signalIdentityPublicKeyFingerprint,
            )
        payload.putAll(
            highRiskOwnerActionEnvelope(
                actionKind = "relay_sender_key_publish",
                subjectId = subjectId,
                deviceId = request.deviceId,
            ),
        )
        val result =
            functions.getHttpsCallable("publishRelaySenderKey")
                .call(payload)
                .await()
        requireOk(result.getData(), "Relay sender-key publication failed.")
    }

    override suspend fun publishAgentGrantAuthority(expectedUid: String, deviceId: String, peerNodeId: String, publicKeyBase64: String, keyKind: String?) {
        requireAuthenticatedUser(expectedUid)
        bindAppCheckAttestation(expectedUid)
        val nonce = issueHighRiskActionNonce(expectedUid)
        // F2: omit keyKind entirely for legacy Ed25519 — the server treats
        // absence as `ed25519`, keeping pre-F2 publishes byte-identical.
        val payload =
            buildMap<String, Any> {
                put("deviceId", deviceId)
                put("expectedUid", expectedUid)
                put("peerNodeId", peerNodeId)
                put("publicKeyBase64", publicKeyBase64)
                put("nonce", nonce)
                keyKind?.let { put("keyKind", it) }
            }
        val result = callBoundToExpectedUid(expectedUid, { requireAuthenticatedUser() }) {
            functions.getHttpsCallable("publishAgentGrantAuthority")
                .call(payload)
                .await()
        }
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

    fun providerAccountSubjectId(provider: String, accountId: String?): String {
        val raw = accountId?.trim()?.takeIf { it.isNotEmpty() } ?: "${provider}_default"
        val lowered = raw.lowercase()
        val sanitized =
            lowered
                .replace(Regex("[^a-z0-9_-]"), "-")
                .replace(Regex("-+"), "-")
                .trim('-')
        return sanitized.ifEmpty { "${provider}_default" }
    }

    suspend fun highRiskOwnerActionEnvelope(
        actionKind: String,
        subjectId: String,
        deviceId: String,
        approve: Boolean = true,
        firestore: com.google.firebase.firestore.FirebaseFirestore = com.google.firebase.firestore.FirebaseFirestore.getInstance(),
    ): Map<String, Any> {
        val uid = requireAuthenticatedUser()
        bindAppCheckAttestation()
        val nonce = issueHighRiskActionNonce()
        val keypair = AndroidCloudVaultDeviceKeypair.loadOrCreate()
        val resolvedDeviceId = deviceId.trim().ifEmpty { keypair.deviceId }
        val identity = AndroidSignalIdentityKeyStore.loadOrCreate(resolvedDeviceId, keypair.keyVersion)
        AndroidSignalIdentityKeyStore.publishIfNeeded(
            uid = uid,
            deviceId = resolvedDeviceId,
            identity = identity,
            firestore = firestore,
        )
        val identityPublicKeyFingerprint = CloudVaultCrypto.sha256Base64(identity.publicKeyData)
        val issuedAtMillis = System.currentTimeMillis()
        val proofPayload =
            CloudVaultTrustedDeviceActionProofPayload(
                uid = uid,
                deviceId = resolvedDeviceId,
                actionKind = actionKind,
                subjectId = subjectId,
                approve = approve,
                nonce = nonce,
                issuedAtMillis = issuedAtMillis,
                deviceSignalIdentityKeyId = identity.identityKeyId,
                deviceSignalIdentityPublicKeyFingerprint = identityPublicKeyFingerprint,
            )
        val signature = CloudVaultTrustedDeviceActionProofSigner.sign(proofPayload, identity)
        val actionProof =
            CloudVaultTrustedDeviceActionProof(
                deviceSignalIdentityKeyId = identity.identityKeyId,
                deviceSignalIdentityPublicKeyFingerprint = identityPublicKeyFingerprint,
                issuedAtMillis = issuedAtMillis,
                signature = signature,
            ).asMap()
        return mapOf(
            "nonce" to nonce,
            "trustedDeviceId" to resolvedDeviceId,
            "actionProof" to actionProof,
        )
    }

    private fun relaySenderKeyPublishProofSubjectId(request: RelaySenderKeyPublishRequest): String {
        val publicKeySHA256Hex = CloudVaultCrypto.sha256Hex(Base64.decode(request.publicKeyBase64, Base64.NO_WRAP))
        val segments =
            listOf(
                "version",
                "1",
                "deviceId",
                request.deviceId,
                "peerNodeId",
                request.peerNodeId,
                "keyId",
                request.keyId,
                "publicKeySHA256Hex",
                publicKeySHA256Hex,
                "relayKeyVersion",
                relaySenderProofProtocolVersion,
                "publishedAtMillis",
                request.publishedAtMillis.toString(),
                "signalIdentityKeyId",
                request.signalIdentityKeyId,
                "signalIdentityKeyVersion",
                request.signalIdentityKeyVersion.toString(),
                "signalIdentityPublicKeyFingerprint",
                request.signalIdentityPublicKeyFingerprint,
            )
        val canonical =
            buildString {
                append("OpenBurnBar-RelaySenderKeyPublish-v1\n")
                for (segment in segments) {
                    append(segment.toByteArray(Charsets.UTF_8).size)
                    append(':')
                    append(segment)
                    append('\n')
                }
            }
        return CloudVaultCrypto.sha256Hex(canonical.toByteArray(Charsets.UTF_8))
    }

    suspend fun callHighRiskOwnerAction(
        callableName: String,
        deviceId: String,
        actionKind: String,
        subjectId: String,
        payload: Map<String, Any> = emptyMap(),
        approve: Boolean = true,
    ): Map<*, *> {
        val envelope = highRiskOwnerActionEnvelope(actionKind, subjectId, deviceId, approve)
        val merged = LinkedHashMap<String, Any>(payload.size + envelope.size)
        merged.putAll(payload)
        merged.putAll(envelope)
        val result = functions.getHttpsCallable(callableName).call(merged).await()
        return requireOk(result.getData(), "$callableName failed.")
    }

    suspend fun createCliAgentMission(payload: Map<String, Any>, deviceId: String): String {
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

    suspend fun cancelCliAgentMission(
        requestId: String,
        deviceId: String,
        sealedStatePayload: Map<String, Any>,
    ) {
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
    suspend fun respondMissionApproval(requestId: String, approve: Boolean, deviceId: String) {
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

    suspend fun respondHermesGatewayApproval(approvalId: String, approve: Boolean, deviceId: String) {
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

    private suspend fun refreshAuthClaimsAfterBind(expectedUid: String) {
        val user =
            FirebaseAuth.getInstance().currentUser
                ?: error("Sign in before performing this Computer Use security action.")
        check(!user.isAnonymous && user.uid == expectedUid) {
            "The signed-in account changed during this Computer Use security action."
        }
        user.getIdToken(true).await()
        requireAuthenticatedUser(expectedUid)
    }

    private fun requireAuthenticatedUser(expectedUid: String? = null): String {
        val user = FirebaseAuth.getInstance().currentUser
        check(user != null && !user.isAnonymous) {
            "Sign in before performing this Computer Use security action."
        }
        check(expectedUid == null || user.uid == expectedUid) {
            "The signed-in account changed during this Computer Use security action."
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

private fun Map<*, *>.requiredString(key: String, failureMessage: String): String = (this[key] as? String)?.takeIf { it.isNotBlank() } ?: error(failureMessage)

private fun Map<*, *>.requiredBoolean(key: String, failureMessage: String): Boolean = this[key] as? Boolean ?: error(failureMessage)

private fun Map<*, *>.requiredLong(key: String, failureMessage: String): Long {
    val value = this[key] as? Number ?: error(failureMessage)
    val asDouble = value.toDouble()
    val asLong = value.toLong()
    check(asDouble.isFinite() && asDouble == asLong.toDouble()) { failureMessage }
    return asLong
}
