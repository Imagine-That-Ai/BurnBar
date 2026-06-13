#if canImport(AppKit)
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarSignalCore

/// WS4 Mac client for App Check attestation binding and escrow device trust callables.
enum ComputerUseSecurityCallableClient {
    struct EscrowDeviceTrustRevocationResult: Sendable, Equatable {
        let revokedCloudVaultWrappers: Int
        let cloudVaultRotationRequired: Bool
        let cloudVaultRotationRequirementId: String?
        let cloudVaultRotationBlockedReason: String?
        let cloudVaultRotationJobId: String?
        let cloudVaultRotationCompleted: Bool
        let cloudVaultRotationFailureMessage: String?
        let cloudVaultRotationRewrappedDocuments: Int
        let cloudVaultRotationRewrappedStorageBlobs: Int

        init(
            revokedCloudVaultWrappers: Int,
            cloudVaultRotationRequired: Bool,
            cloudVaultRotationRequirementId: String?,
            cloudVaultRotationBlockedReason: String?,
            cloudVaultRotationJobId: String? = nil,
            cloudVaultRotationCompleted: Bool = false,
            cloudVaultRotationFailureMessage: String? = nil,
            cloudVaultRotationRewrappedDocuments: Int = 0,
            cloudVaultRotationRewrappedStorageBlobs: Int = 0
        ) {
            self.revokedCloudVaultWrappers = revokedCloudVaultWrappers
            self.cloudVaultRotationRequired = cloudVaultRotationRequired
            self.cloudVaultRotationRequirementId = cloudVaultRotationRequirementId
            self.cloudVaultRotationBlockedReason = cloudVaultRotationBlockedReason
            self.cloudVaultRotationJobId = cloudVaultRotationJobId
            self.cloudVaultRotationCompleted = cloudVaultRotationCompleted
            self.cloudVaultRotationFailureMessage = cloudVaultRotationFailureMessage
            self.cloudVaultRotationRewrappedDocuments = cloudVaultRotationRewrappedDocuments
            self.cloudVaultRotationRewrappedStorageBlobs = cloudVaultRotationRewrappedStorageBlobs
        }

        func withCompletedCloudVaultRotation(jobId: String, progress: CloudVaultRotationRewrapProgress) -> Self {
            Self(
                revokedCloudVaultWrappers: revokedCloudVaultWrappers,
                cloudVaultRotationRequired: cloudVaultRotationRequired,
                cloudVaultRotationRequirementId: cloudVaultRotationRequirementId,
                cloudVaultRotationBlockedReason: cloudVaultRotationBlockedReason,
                cloudVaultRotationJobId: jobId,
                cloudVaultRotationCompleted: true,
                cloudVaultRotationFailureMessage: nil,
                cloudVaultRotationRewrappedDocuments: progress.rewrappedDocuments,
                cloudVaultRotationRewrappedStorageBlobs: progress.rewrappedStorageBlobs
            )
        }

        func withCloudVaultRotationFailure(_ message: String) -> Self {
            Self(
                revokedCloudVaultWrappers: revokedCloudVaultWrappers,
                cloudVaultRotationRequired: cloudVaultRotationRequired,
                cloudVaultRotationRequirementId: cloudVaultRotationRequirementId,
                cloudVaultRotationBlockedReason: cloudVaultRotationBlockedReason,
                cloudVaultRotationJobId: cloudVaultRotationJobId,
                cloudVaultRotationCompleted: false,
                cloudVaultRotationFailureMessage: message,
                cloudVaultRotationRewrappedDocuments: cloudVaultRotationRewrappedDocuments,
                cloudVaultRotationRewrappedStorageBlobs: cloudVaultRotationRewrappedStorageBlobs
            )
        }
    }

    enum ClientError: LocalizedError {
        case notAuthenticated
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Sign in before performing this Computer Use security action."
            case .invalidResponse(let detail):
                return detail
            }
        }
    }

    private static var functions: Functions {
        Functions.functions(region: "us-central1")
    }

    private static var signedInUser: User? {
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth().currentUser
    }

    private static func requireSignedInUser() throws -> User {
        guard let user = signedInUser, user.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        return user
    }

    /// Binds the signed-in user's Auth custom claims to the current App Check app id.
    /// Call after sign-in when cloud sync is enabled and before high-risk CU actions.
    static func bindAppCheckAttestation() async throws {
        _ = try requireSignedInUser()
        _ = try await functions.httpsCallable("bindAppCheckAttestation").call([:])
        try await refreshAuthClaimsAfterBind()
    }

    /// Fetch a single-use, short-lived nonce to attach to a high-risk action,
    /// providing replay resistance on top of the 30-day attestation binding.
    static func issueHighRiskActionNonce() async throws -> String {
        _ = try requireSignedInUser()
        let result = try await functions.httpsCallable("issueHighRiskActionNonce").call([:])
        guard let dict = result.data as? [String: Any], let nonce = dict["nonce"] as? String, !nonce.isEmpty else {
            throw ClientError.invalidResponse("Could not obtain a high-risk action nonce.")
        }
        return nonce
    }

    /// Registers a pending escrow device via the server-only callable (clients cannot elevate trust).
    static func registerEscrowDevice(
        deviceId: String,
        deviceName: String,
        platform: String,
        appVersion: String? = nil,
        publicKeyFingerprint: String? = nil,
        keyVersion: Int? = nil
    ) async throws {
        _ = try requireSignedInUser()
        let nonce = try await issueHighRiskActionNonce()
        var payload: [String: Any] = [
            "deviceId": deviceId,
            "deviceName": deviceName,
            "platform": platform,
            "nonce": nonce
        ]
        if let appVersion, !appVersion.isEmpty { payload["appVersion"] = appVersion }
        if let publicKeyFingerprint, !publicKeyFingerprint.isEmpty {
            payload["publicKeyFingerprint"] = publicKeyFingerprint
        }
        if let keyVersion { payload["keyVersion"] = keyVersion }
        let result = try await functions.httpsCallable("registerEscrowDevice").call(payload)
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Escrow device registration failed.")
        }
    }

    /// Forces an ID token refresh so `obb_app_check` custom claims propagate before high-risk callables.
    private static func refreshAuthClaimsAfterBind() async throws {
        let user = try requireSignedInUser()
        _ = try await user.getIDTokenResult(forcingRefresh: true)
    }

    /// Elevates an escrow device to `trusted` via the server-only callable (Firestore rules block client writes).
    static func approveEscrowDeviceTrust(deviceId: String, approverDeviceId: String? = nil) async throws {
        let uid = try requireSignedInUser().uid
        let resolvedApproverDeviceId = approverDeviceId?.isEmpty == false ? approverDeviceId! : deviceId
        let trustChain = try await buildTrustChainProof(
            uid: uid,
            targetDeviceId: deviceId,
            approverDeviceId: resolvedApproverDeviceId
        )
        let nonce = try await issueHighRiskActionNonce()
        var payload: [String: Any] = [
            "deviceId": deviceId,
            "nonce": nonce,
            "trustChain": trustChain
        ]
        payload["approverDeviceId"] = resolvedApproverDeviceId
        let result = try await functions.httpsCallable("approveEscrowDeviceTrust").call(payload)
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Escrow device trust approval failed.")
        }
    }

    private static func buildTrustChainProof(
        uid: String,
        targetDeviceId: String,
        approverDeviceId: String
    ) async throws -> [String: Any] {
        let userRef = Firestore.firestore().collection("users").document(uid)
        let approverIdentity = try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(
            uid: uid,
            deviceId: approverDeviceId
        )
        try await SignalIdentityPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: approverDeviceId,
            platform: "macOS",
            identity: approverIdentity
        )

        let targetDevice = try await userRef.collection("escrow_devices").document(targetDeviceId).getDocument()
        guard let targetData = targetDevice.data(),
              let targetKeyVersion = targetData["keyVersion"] as? Int,
              let targetEscrowFingerprint = targetData["publicKeyFingerprint"] as? String else {
            throw ClientError.invalidResponse("Target device escrow key is not published.")
        }
        let targetSignalIdentityKeyId = OpenBurnBarSignalIdentityKeyStore.identityKeyId(
            deviceId: targetDeviceId,
            keyVersion: targetKeyVersion
        )
        let targetIdentity = try await userRef.collection("signal_identity_public_keys")
            .document(targetSignalIdentityKeyId)
            .getDocument()
        guard let targetIdentityData = targetIdentity.data(),
              targetIdentityData["deviceId"] as? String == targetDeviceId,
              targetIdentityData["identityKeyId"] as? String == targetSignalIdentityKeyId,
              targetIdentityData["keyVersion"] as? Int == targetKeyVersion,
              let targetSignalFingerprint = targetIdentityData["publicKeyFingerprint"] as? String else {
            throw ClientError.invalidResponse("Target device Signal identity is not published.")
        }

        let payload = CloudVaultDeviceTrustChainPayload(
            uid: uid,
            targetDeviceId: targetDeviceId,
            targetEscrowPublicKeyFingerprint: targetEscrowFingerprint,
            targetKeyVersion: targetKeyVersion,
            targetSignalIdentityKeyId: targetSignalIdentityKeyId,
            targetSignalIdentityPublicKeyFingerprint: targetSignalFingerprint,
            approverDeviceId: approverDeviceId,
            approverSignalIdentityKeyId: approverIdentity.identityKeyId,
            approverSignalIdentityPublicKeyFingerprint: approverIdentity.publicKeyFingerprint
        )
        let signature = try CloudVaultDeviceTrustChain.sign(payload, approverIdentity: approverIdentity)
        return [
            "version": CloudVaultDeviceTrustChain.version,
            "algorithm": CloudVaultDeviceTrustChain.algorithm,
            "targetSignalIdentityKeyId": targetSignalIdentityKeyId,
            "targetSignalIdentityPublicKeyFingerprint": targetSignalFingerprint,
            "approverSignalIdentityKeyId": approverIdentity.identityKeyId,
            "approverSignalIdentityPublicKeyFingerprint": approverIdentity.publicKeyFingerprint,
            "signature": signature
        ]
    }

    /// Revokes escrow device trust and active grants server-side.
    @discardableResult
    static func revokeEscrowDeviceTrust(
        deviceId: String,
        rotatingDeviceId: String? = nil
    ) async throws -> EscrowDeviceTrustRevocationResult {
        let uid = try requireSignedInUser().uid
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        let result = try await functions.httpsCallable("revokeEscrowDeviceTrust").call([
            "deviceId": deviceId,
            "nonce": nonce
        ])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Escrow device trust revocation failed.")
        }
        let revocation = EscrowDeviceTrustRevocationResult(
            revokedCloudVaultWrappers: dict["revokedCloudVaultWrappers"] as? Int ?? 0,
            cloudVaultRotationRequired: dict["cloudVaultRotationRequired"] as? Bool ?? false,
            cloudVaultRotationRequirementId: dict["cloudVaultRotationRequirementId"] as? String,
            cloudVaultRotationBlockedReason: dict["cloudVaultRotationBlockedReason"] as? String
        )
        guard revocation.cloudVaultRotationRequired else { return revocation }
        guard let requirementId = revocation.cloudVaultRotationRequirementId,
              !requirementId.isEmpty,
              let rotatingDeviceId,
              !rotatingDeviceId.isEmpty else {
            return revocation.withCloudVaultRotationFailure(
                "Cloud Vault rotation is required, but this Mac's trusted device identity is unavailable."
            )
        }

        do {
            let rotation = try await performRevocationCloudVaultRotation(
                uid: uid,
                requirementId: requirementId,
                rotatingDeviceId: rotatingDeviceId
            )
            return revocation.withCompletedCloudVaultRotation(jobId: rotation.jobId, progress: rotation.progress)
        } catch {
            return revocation.withCloudVaultRotationFailure(error.localizedDescription)
        }
    }

    /// Outcome of one survivor-side rotation pickup pass.
    struct CloudVaultRotationPickupResult: Sendable, Equatable {
        /// Pending requirements this Mac was eligible to satisfy (survivor + not
        /// already actioned this session).
        let eligibleRequirementIds: [String]
        /// Requirements this pass rotated successfully.
        let completedRequirementIds: [String]
        /// Requirements that failed this pass, with the failure message.
        let failedRequirements: [String: String]

        init(
            eligibleRequirementIds: [String] = [],
            completedRequirementIds: [String] = [],
            failedRequirements: [String: String] = [:]
        ) {
            self.eligibleRequirementIds = eligibleRequirementIds
            self.completedRequirementIds = completedRequirementIds
            self.failedRequirements = failedRequirements
        }
    }

    /// Requirement ids this process has already taken responsibility for, so a
    /// second foreground/launch pass does not double-run the rotation chain for
    /// the same revocation while the first is still settling.
    private static let inFlightRotationPickups = InFlightRotationPickupTracker()

    private actor InFlightRotationPickupTracker {
        private var ids: Set<String> = []

        /// Reserves `id` for this process. Returns `false` when it was already
        /// reserved (so the caller skips it).
        func reserve(_ id: String) -> Bool {
            ids.insert(id).inserted
        }

        func release(_ id: String) {
            ids.remove(id)
        }
    }

    /// Picks up any pending Cloud Vault rotation requirements this Mac is a
    /// survivor for and runs the rotation chain locally.
    ///
    /// Revocation normally rotates the vault from the revoking device. When that
    /// device is offline or runs Android (which cannot rotate the Cloud Vault),
    /// the rotation requirement stays `pending` and the revoked device's cached
    /// key is not yet retired. Calling this on launch/foreground (and after any
    /// local revoke) lets a surviving Mac finish the rotation instead, making
    /// revocation resilient to the revoking device's availability/platform.
    ///
    /// Mirrors the post-revoke chain: it reuses ``performRevocationCloudVaultRotation``
    /// (which re-validates the survivor set, the current vault key, and the
    /// `rotateCloudVaultKey` callable's generation/requirement idempotency), and
    /// guards against re-entrant passes within this process.
    @discardableResult
    static func pickUpPendingCloudVaultRotations(
        rotatingDeviceId: String
    ) async throws -> CloudVaultRotationPickupResult {
        let uid = try requireSignedInUser().uid
        let rotatingDeviceId = rotatingDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rotatingDeviceId.isEmpty else {
            return CloudVaultRotationPickupResult()
        }

        let pending = try await listPendingCloudVaultRotationRequirements()
        let eligible = eligibleRequirements(from: pending, rotatingDeviceId: rotatingDeviceId)
        var completed: [String] = []
        var failed: [String: String] = [:]

        for requirementId in eligible {
            // Idempotency: skip a requirement another pass in this process owns.
            guard await inFlightRotationPickups.reserve(requirementId) else { continue }
            defer { Task { await inFlightRotationPickups.release(requirementId) } }

            do {
                _ = try await performRevocationCloudVaultRotation(
                    uid: uid,
                    requirementId: requirementId,
                    rotatingDeviceId: rotatingDeviceId
                )
                completed.append(requirementId)
            } catch {
                failed[requirementId] = error.localizedDescription
            }
        }

        return CloudVaultRotationPickupResult(
            eligibleRequirementIds: eligible,
            completedRequirementIds: completed,
            failedRequirements: failed
        )
    }

    /// Pure survivor filter: keeps requirements where this Mac is a listed
    /// survivor, dropping `alreadyActioned` ids and de-duplicating repeats so a
    /// single pass runs each requirement at most once.
    static func eligibleRequirements(
        from requirements: [PendingCloudVaultRotationRequirement],
        rotatingDeviceId: String,
        alreadyActioned: Set<String> = []
    ) -> [String] {
        let rotatingDeviceId = rotatingDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rotatingDeviceId.isEmpty else { return [] }
        var seen = alreadyActioned
        var eligible: [String] = []
        for requirement in requirements {
            guard requirement.survivorDeviceIds.contains(rotatingDeviceId) else { continue }
            guard seen.insert(requirement.requirementId).inserted else { continue }
            eligible.append(requirement.requirementId)
        }
        return eligible
    }

    /// A pending Cloud Vault rotation requirement, as returned by S1's server
    /// callable. Only the fields the pickup chain needs are decoded.
    struct PendingCloudVaultRotationRequirement: Sendable, Equatable {
        let requirementId: String
        let survivorDeviceIds: [String]

        init(requirementId: String, survivorDeviceIds: [String]) {
            self.requirementId = requirementId
            self.survivorDeviceIds = survivorDeviceIds
        }
    }

    /// Lists the user's pending Cloud Vault rotation requirements via S1's
    /// server-only callable. The server is the source of truth for which
    /// requirements remain unconsumed; this client filters by survivor locally.
    static func listPendingCloudVaultRotationRequirements() async throws -> [PendingCloudVaultRotationRequirement] {
        _ = try requireSignedInUser()
        let result = try await functions.httpsCallable("listPendingCloudVaultRotationRequirements").call([:])
        guard let dict = result.data as? [String: Any],
              let rawRequirements = dict["requirements"] as? [[String: Any]] else {
            throw ClientError.invalidResponse("Could not list pending Cloud Vault rotation requirements.")
        }
        return parsePendingRequirements(rawRequirements)
    }

    /// Pure decoder for S1's `listPendingCloudVaultRotationRequirements` payload.
    /// Accepts either `requirementId` or `id` for the requirement key (S1 may
    /// name it either way; flagged for cross-check) and trims/filters survivors.
    static func parsePendingRequirements(_ raw: [[String: Any]]) -> [PendingCloudVaultRotationRequirement] {
        raw.compactMap { entry in
            guard let requirementId = (entry["requirementId"] as? String ?? entry["id"] as? String),
                  !requirementId.isEmpty else { return nil }
            let survivors = (entry["survivorDeviceIds"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return PendingCloudVaultRotationRequirement(
                requirementId: requirementId,
                survivorDeviceIds: survivors
            )
        }
    }

    private struct RevocationCloudVaultRotationResult {
        let jobId: String
        let progress: CloudVaultRotationRewrapProgress
    }

    private static func performRevocationCloudVaultRotation(
        uid: String,
        requirementId: String,
        rotatingDeviceId: String
    ) async throws -> RevocationCloudVaultRotationResult {
        let firestore = Firestore.firestore()
        let userRef = firestore.collection("users").document(uid)
        let requirementSnapshot = try await userRef.collection("cloud_vault_rotation_requirements")
            .document(requirementId)
            .getDocument()
        guard let requirement = requirementSnapshot.data(),
              requirement["status"] as? String == "pending",
              requirement["rotateCallable"] as? String == "rotateCloudVaultKey",
              let currentVaultKeyID = requirement["currentVaultKeyID"] as? String else {
            throw ClientError.invalidResponse("Cloud Vault rotation requirement is missing or already consumed.")
        }
        let currentVaultGeneration = intValue(requirement["currentVaultGeneration"]) ?? 1
        let survivorDeviceIds = (requirement["survivorDeviceIds"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        guard survivorDeviceIds.contains(rotatingDeviceId) else {
            throw ClientError.invalidResponse("This Mac is not a surviving trusted device for the required Cloud Vault rotation.")
        }

        guard let currentKey = try await MacCloudVaultKeyAccess.keyForReading(
            uid: uid,
            deviceId: rotatingDeviceId,
            firestore: firestore
        ) else {
            throw ClientError.invalidResponse("This Mac does not have the current Cloud Vault key needed to rotate after revocation.")
        }
        guard currentKey.vaultKeyID == currentVaultKeyID else {
            throw ClientError.invalidResponse(
                "Cloud Vault rotation requirement expected \(currentVaultKeyID), but this Mac has \(currentKey.vaultKeyID)."
            )
        }

        let localIdentity = try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(uid: uid, deviceId: rotatingDeviceId)
        try await SignalIdentityPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: rotatingDeviceId,
            platform: "macOS",
            identity: localIdentity
        )

        let nextKey = CloudVaultCrypto.generateVaultKey()
        let nextVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: nextKey)
        let nextVaultGeneration = currentVaultGeneration + 1
        var survivorWrappers: [[String: Any]] = []
        for survivorDeviceId in survivorDeviceIds {
            let survivor = try await CloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevice(
                uid: uid,
                userRef: userRef,
                deviceId: survivorDeviceId,
                localIdentity: localIdentity
            )
            let wrapped = try CloudVaultCrypto.wrapVaultKey(
                nextKey,
                recipientPublicKey: survivor.escrowPublicKeyData
            )
            survivorWrappers.append([
                "wrapperId": "\(nextVaultKeyID)_\(survivor.deviceId)_\(survivor.keyVersion)",
                "targetDeviceId": survivor.deviceId,
                "sourceDeviceId": rotatingDeviceId,
                "publicKeyFingerprint": survivor.escrowPublicKeyFingerprint,
                "keyVersion": survivor.keyVersion,
                "vaultKeyID": nextVaultKeyID,
                "wrappedVaultKey": wrapped.base64EncodedString()
            ])
        }

        let rotationNonce = try await issueHighRiskActionNonce()
        let rotationResult = try await functions.httpsCallable("rotateCloudVaultKey").call([
            "callerDeviceId": rotatingDeviceId,
            "currentVaultKeyID": currentVaultKeyID,
            "newVaultKeyID": nextVaultKeyID,
            "expectedVaultGeneration": nextVaultGeneration,
            "survivorWrappers": survivorWrappers,
            "reason": "revocation_rewrap",
            "rotationRequirementId": requirementId,
            "nonce": rotationNonce
        ])
        guard let rotationDict = rotationResult.data as? [String: Any],
              rotationDict["ok"] as? Bool == true,
              let jobId = rotationDict["jobId"] as? String,
              !jobId.isEmpty else {
            throw ClientError.invalidResponse("Cloud Vault key rotation was not queued.")
        }

        try CloudVaultKeyStore().saveKey(nextKey, uid: uid)

        var worker = CloudVaultRotationRewrapWorker()
        worker.firestore = firestore
        do {
            let progress = try await worker.runDocumentRewrap(
                uid: uid,
                deviceId: rotatingDeviceId,
                jobId: jobId,
                oldKeyData: currentKey.keyData,
                newKeyData: nextKey,
                newVaultKeyID: nextVaultKeyID,
                vaultGeneration: nextVaultGeneration
            )
            return RevocationCloudVaultRotationResult(jobId: jobId, progress: progress)
        } catch let rewrapError {
            do {
                try await userRef.collection("cloud_vault_rotation_jobs").document(jobId).setData([
                    "status": "failed",
                    "failureReason": String(rewrapError.localizedDescription.prefix(500)),
                    "failedAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
            } catch let statusWriteError {
                // The caller still receives the local rewrap failure below; this best-effort
                // status write must not mask the actionable rotation error.
                _ = statusWriteError.localizedDescription
            }
            throw ClientError.invalidResponse(
                "Cloud Vault rotation job \(jobId) was queued, but local rewrap failed: \(rewrapError.localizedDescription)"
            )
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    static func publishIrohPairingPublicKey(
        deviceId: String,
        roleId: String = "host",
        publicKeyBase64: String
    ) async throws {
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        let result = try await functions.httpsCallable("publishIrohPairingPublicKey").call([
            "deviceId": deviceId,
            "roleId": roleId,
            "publicKeyBase64": publicKeyBase64,
            "nonce": nonce
        ])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Iroh pairing public-key publication failed.")
        }
    }

    static func publishIrohPairingRecord(deviceId: String, record: IrohPairingRecord) async throws {
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        var payload: [String: Any] = [
            "deviceId": deviceId,
            "connectionId": record.connectionId,
            "nodeId": record.nodeId,
            "directAddresses": record.directAddresses,
            "publishedAtMillis": record.publishedAtMillis,
            "protocolVersion": record.protocolVersion,
            "signature": record.signature,
            "nonce": nonce
        ]
        if let relayURL = record.relayURL, !relayURL.isEmpty {
            payload["relayURL"] = relayURL
        }
        let result = try await functions.httpsCallable("publishIrohPairingRecord").call(payload)
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Iroh pairing record publication failed.")
        }
    }

    static func revokeIrohPairingRecord(deviceId: String, connectionId: String) async throws {
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        let result = try await functions.httpsCallable("revokeIrohPairingRecord").call([
            "deviceId": deviceId,
            "connectionId": connectionId,
            "nonce": nonce
        ])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Iroh pairing record revocation failed.")
        }
    }
}
#endif
