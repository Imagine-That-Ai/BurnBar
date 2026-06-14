// Security-pinned E2EE/trust code under active remediation; behavior is pinned by tests and
// a P0 migration gate.
package com.openburnbar.data.cloud

import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.tasks.await

/**
 * RR-5 — the Android survivor-side Cloud Vault rotation chain, the mirror of Swift
 * `ComputerUseSecurityCallableClient.performRevocationCloudVaultRotation` /
 * `pickUpPendingCloudVaultRotations`.
 *
 * Revocation normally rotates the vault from the revoking device. When that device is offline (or
 * runs a platform that cannot rotate), the `cloud_vault_rotation_requirements/{id}` doc stays
 * `pending` and the revoked device's cached key is not yet retired. A SURVIVING trusted device
 * (this one) finishes the rotation: generate the next vault key, wrap it to every survivor's escrow
 * public key, call `rotateCloudVaultKey` (server validates generation + requirement idempotency),
 * persist the new key, and run [CloudVaultRotationRewrapWorker.runDocumentRewrap].
 *
 * The pure parsing/eligibility helpers ([parsePendingRequirements], [eligibleRequirements]) take no
 * Firebase and are unit-tested directly.
 */
object AndroidCloudVaultRevocationRotation {
    /** Outcome of a completed rotation, surfaced to the revocation result. */
    data class RotationOutcome(
        val jobId: String,
        val rewrappedDocuments: Int,
        val rewrappedStorageBlobs: Int,
    )

    /** A pending Cloud Vault rotation requirement, decoded from the server callable payload. */
    data class PendingRequirement(
        val requirementId: String,
        val survivorDeviceIds: List<String>,
    )

    /** Outcome of one survivor-side rotation pickup pass. */
    data class PickupResult(
        val eligibleRequirementIds: List<String> = emptyList(),
        val completedRequirementIds: List<String> = emptyList(),
        val failedRequirements: Map<String, String> = emptyMap(),
    )

    // Requirement ids this process already took responsibility for, so a second launch/foreground
    // pass does not double-run the rotation chain for the same revocation while the first settles.
    private val inFlightRotationPickups = ConcurrentHashMap.newKeySet<String>()

    /** Callable payload for `listPendingCloudVaultRotationRequirements` (server requires callerDeviceId). */
    fun listPendingCallablePayload(callerDeviceId: String): Map<String, Any> =
        mapOf("callerDeviceId" to callerDeviceId.trim())

    /**
     * Pure decoder for the `listPendingCloudVaultRotationRequirements` payload. Accepts either
     * `requirementId` or `id` for the requirement key and trims/filters survivor ids — byte-for-byte
     * the Swift `parsePendingRequirements`.
     */
    fun parsePendingRequirements(raw: List<*>): List<PendingRequirement> =
        raw.mapNotNull { entry ->
            val map = entry as? Map<*, *> ?: return@mapNotNull null
            val requirementId = (map["requirementId"] as? String ?: map["id"] as? String)?.takeIf { it.isNotEmpty() }
                ?: return@mapNotNull null
            val survivors =
                (map["survivorDeviceIds"] as? List<*>).orEmpty()
                    .mapNotNull { (it as? String)?.trim()?.takeIf { id -> id.isNotEmpty() } }
            PendingRequirement(requirementId = requirementId, survivorDeviceIds = survivors)
        }

    /**
     * Pure survivor filter: keeps requirements where [rotatingDeviceId] is a listed survivor, dropping
     * [alreadyActioned] ids and de-duplicating repeats so a single pass runs each requirement at most
     * once. Mirrors the Swift `eligibleRequirements`.
     */
    fun eligibleRequirements(
        requirements: List<PendingRequirement>,
        rotatingDeviceId: String,
        alreadyActioned: Set<String> = emptySet(),
    ): List<String> {
        val trimmed = rotatingDeviceId.trim()
        if (trimmed.isEmpty()) return emptyList()
        val seen = alreadyActioned.toMutableSet()
        return requirements
            .filter { trimmed in it.survivorDeviceIds }
            .map { it.requirementId }
            .filter { seen.add(it) }
    }

    /**
     * Runs the rotation chain for every requirement this device is an eligible survivor for, guarding
     * against re-entrant passes within this process. Mirrors Swift `pickUpPendingCloudVaultRotations`.
     */
    suspend fun runPickup(
        uid: String,
        rotatingDeviceId: String,
        pending: List<PendingRequirement>,
        functions: FirebaseFunctions = Firebase.functions("us-central1"),
        firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
        issueNonce: suspend () -> String,
    ): PickupResult {
        val eligible = eligibleRequirements(pending, rotatingDeviceId)
        val completed = mutableListOf<String>()
        val failed = LinkedHashMap<String, String>()
        for (requirementId in eligible.filter { inFlightRotationPickups.add(it) }) {
            runPickupForRequirement(uid, requirementId, rotatingDeviceId, functions, firestore, issueNonce)
                ?.let { failed[requirementId] = it }
                ?: completed.add(requirementId)
        }
        return PickupResult(
            eligibleRequirementIds = eligible,
            completedRequirementIds = completed,
            failedRequirements = failed,
        )
    }

    /** Run one requirement's rotation under the in-flight reservation; returns a failure message or null. */
    @Suppress("TooGenericExceptionCaught") // rotation must REPORT any failure (mirrors Swift `catch`), not swallow specific kinds.
    @Suppress("TooGenericExceptionCaught") // reason: rotation must REPORT any failure (mirrors Swift `catch`), not swallow specific kinds.
    private suspend fun runPickupForRequirement(
        uid: String,
        requirementId: String,
        rotatingDeviceId: String,
        functions: FirebaseFunctions,
        firestore: FirebaseFirestore,
        issueNonce: suspend () -> String,
    ): String? =
        try {
            performRevocationCloudVaultRotation(uid, requirementId, rotatingDeviceId, functions, firestore, issueNonce = issueNonce)
            null
        } catch (error: Throwable) {
            error.message ?: "Cloud Vault rotation failed."
        } finally {
            inFlightRotationPickups.remove(requirementId)
        }

    /**
     * Generate the next vault key, wrap it to every survivor, call `rotateCloudVaultKey`, persist the
     * new key, and run the document/storage rewrap. Mirrors Swift `performRevocationCloudVaultRotation`.
     */
    suspend fun performRevocationCloudVaultRotation(
        uid: String,
        requirementId: String,
        rotatingDeviceId: String,
        functions: FirebaseFunctions = Firebase.functions("us-central1"),
        firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
        worker: CloudVaultRotationRewrapWorker = CloudVaultRotationRewrapWorker(firestore = firestore, functions = functions),
        issueNonce: suspend () -> String,
    ): RotationOutcome {
        val userRef = firestore.collection("users").document(uid)
        val requirement = readPendingRequirement(userRef, requirementId, rotatingDeviceId)
        val currentKey =
            AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore)
                ?: error("This device does not have the current Cloud Vault key needed to rotate after revocation.")
        check(currentKey.vaultKeyID == requirement.currentVaultKeyID) {
            "Cloud Vault rotation requirement expected ${requirement.currentVaultKeyID}, but this device has ${currentKey.vaultKeyID}."
        }

        val escrow = AndroidCloudVaultDeviceKeypair.loadOrCreate()
        val localIdentity = AndroidSignalIdentityKeyStore.loadOrCreate(escrow.deviceId, escrow.keyVersion)
        AndroidSignalIdentityKeyStore.publishIfNeeded(uid = uid, deviceId = escrow.deviceId, identity = localIdentity, firestore = firestore)

        val nextKey = CloudVaultCrypto.generateVaultKey()
        val nextVaultKeyID = CloudVaultCrypto.vaultKeyID(nextKey)
        val nextVaultGeneration = requirement.currentVaultGeneration + 1
        val survivorWrappers =
            buildSurvivorWrappers(uid, firestore, requirement.survivorDeviceIds, rotatingDeviceId, localIdentity, nextKey, nextVaultKeyID)

        val jobId =
            callRotateCloudVaultKey(
                functions = functions,
                rotatingDeviceId = rotatingDeviceId,
                requirementId = requirementId,
                currentVaultKeyID = requirement.currentVaultKeyID,
                nextVaultKeyID = nextVaultKeyID,
                nextVaultGeneration = nextVaultGeneration,
                survivorWrappers = survivorWrappers,
                nonce = issueNonce(),
            )
        AndroidCloudVaultKeyAccess.saveKey(uid, nextKey)

        val progress =
            runRewrapOrMarkFailed(worker, userRef, uid, rotatingDeviceId, jobId, currentKey.keyData, nextKey, nextVaultKeyID, nextVaultGeneration)
        return RotationOutcome(
            jobId = jobId,
            rewrappedDocuments = progress.rewrappedDocuments,
            rewrappedStorageBlobs = progress.rewrappedStorageBlobs,
        )
    }

    private data class ValidatedRequirement(
        val currentVaultKeyID: String,
        val currentVaultGeneration: Int,
        val survivorDeviceIds: List<String>,
    )

    private suspend fun readPendingRequirement(
        userRef: com.google.firebase.firestore.DocumentReference,
        requirementId: String,
        rotatingDeviceId: String,
    ): ValidatedRequirement {
        val requirement =
            userRef.collection("cloud_vault_rotation_requirements").document(requirementId).get().await().data
        check(
            requirement != null &&
                requirement["status"] == "pending" &&
                requirement["rotateCallable"] == "rotateCloudVaultKey",
        ) { "Cloud Vault rotation requirement is missing or already consumed." }
        val currentVaultKeyID =
            requirement["currentVaultKeyID"] as? String
                ?: error("Cloud Vault rotation requirement is missing or already consumed.")
        val survivorDeviceIds =
            (requirement["survivorDeviceIds"] as? List<*>).orEmpty()
                .mapNotNull { (it as? String)?.trim()?.takeIf { id -> id.isNotEmpty() } }
                .sorted()
        check(rotatingDeviceId in survivorDeviceIds) {
            "This device is not a surviving trusted device for the required Cloud Vault rotation."
        }
        return ValidatedRequirement(
            currentVaultKeyID = currentVaultKeyID,
            currentVaultGeneration = (requirement["currentVaultGeneration"] as? Number)?.toInt() ?: 1,
            survivorDeviceIds = survivorDeviceIds,
        )
    }

    private suspend fun buildSurvivorWrappers(
        uid: String,
        firestore: FirebaseFirestore,
        survivorDeviceIds: List<String>,
        rotatingDeviceId: String,
        localIdentity: AndroidSignalIdentityKeypair,
        nextKey: ByteArray,
        nextVaultKeyID: String,
    ): List<Map<String, Any>> =
        survivorDeviceIds.map { survivorDeviceId ->
            val survivor =
                AndroidCloudVaultTrustedDeviceChainVerifier.verifiedTrustedDeviceById(
                    uid = uid,
                    firestore = firestore,
                    deviceId = survivorDeviceId,
                    localIdentity = localIdentity,
                )
            val wrapped = CloudVaultCrypto.wrapVaultKey(nextKey, survivor.escrowPublicKeyData)
            mapOf(
                "wrapperId" to "${nextVaultKeyID}_${survivor.deviceId}_${survivor.keyVersion}",
                "targetDeviceId" to survivor.deviceId,
                "sourceDeviceId" to rotatingDeviceId,
                "publicKeyFingerprint" to survivor.escrowPublicKeyFingerprint,
                "keyVersion" to survivor.keyVersion,
                "vaultKeyID" to nextVaultKeyID,
                "wrappedVaultKey" to CloudVaultCryptoSupport.encodeBase64(wrapped),
            )
        }

    private suspend fun callRotateCloudVaultKey(
        functions: FirebaseFunctions,
        rotatingDeviceId: String,
        requirementId: String,
        currentVaultKeyID: String,
        nextVaultKeyID: String,
        nextVaultGeneration: Int,
        survivorWrappers: List<Map<String, Any>>,
        nonce: String,
    ): String {
        val rotationResult =
            functions.getHttpsCallable("rotateCloudVaultKey")
                .call(
                    mapOf(
                        "callerDeviceId" to rotatingDeviceId,
                        "currentVaultKeyID" to currentVaultKeyID,
                        "newVaultKeyID" to nextVaultKeyID,
                        "expectedVaultGeneration" to nextVaultGeneration,
                        "survivorWrappers" to survivorWrappers,
                        "reason" to "revocation_rewrap",
                        "rotationRequirementId" to requirementId,
                        "nonce" to nonce,
                    ),
                )
                .await()
        val rotationDict = rotationResult.getData() as? Map<*, *> ?: error("Cloud Vault key rotation was not queued.")
        check(rotationDict["ok"] == true) { "Cloud Vault key rotation was not queued." }
        return (rotationDict["jobId"] as? String)?.takeIf { it.isNotEmpty() } ?: error("Cloud Vault key rotation was not queued.")
    }

    @Suppress("LongParameterList", "TooGenericExceptionCaught") // mirrors Swift: any rewrap failure marks the job failed, then re-throws.
    @Suppress("LongParameterList", "TooGenericExceptionCaught") // reason: mirrors Swift: rewrap failure fails the job then re-throws; params are explicit DI.
    private suspend fun runRewrapOrMarkFailed(
        worker: CloudVaultRotationRewrapWorker,
        userRef: com.google.firebase.firestore.DocumentReference,
        uid: String,
        rotatingDeviceId: String,
        jobId: String,
        oldKey: ByteArray,
        newKey: ByteArray,
        newVaultKeyID: String,
        vaultGeneration: Int,
    ): CloudVaultRotationRewrapProgress =
        try {
            worker.runDocumentRewrap(
                uid = uid,
                deviceId = rotatingDeviceId,
                jobId = jobId,
                oldKey = oldKey,
                newKey = newKey,
                newVaultKeyID = newVaultKeyID,
                vaultGeneration = vaultGeneration,
            )
        } catch (rewrapError: Throwable) {
            runCatching {
                userRef.collection("cloud_vault_rotation_jobs").document(jobId).set(
                    mapOf(
                        "status" to "failed",
                        "failureReason" to (rewrapError.message?.take(500) ?: "rewrap failed"),
                        "failedAt" to FieldValue.serverTimestamp(),
                        "updatedAt" to FieldValue.serverTimestamp(),
                    ),
                    com.google.firebase.firestore.SetOptions.merge(),
                ).await()
            }
            error("Cloud Vault rotation job $jobId was queued, but local rewrap failed: ${rewrapError.message}")
        }
}
