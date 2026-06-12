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
            "nonce": rotationNonce,
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
        } catch {
            try? await userRef.collection("cloud_vault_rotation_jobs").document(jobId).setData([
                "status": "failed",
                "failureReason": String(error.localizedDescription.prefix(500)),
                "failedAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
            throw ClientError.invalidResponse(
                "Cloud Vault rotation job \(jobId) was queued, but local rewrap failed: \(error.localizedDescription)"
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
