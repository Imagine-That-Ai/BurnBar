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

    struct RevocationCloudVaultRotationRequirement: Equatable {
        let currentVaultKeyID: String
        let currentVaultGeneration: Int
        let survivorDeviceIds: [String]

        init(data: [String: Any], rotatingDeviceId: String) throws {
            guard data["status"] as? String == "pending",
                  data["rotateCallable"] as? String == "rotateCloudVaultKey",
                  let currentVaultKeyID = data["currentVaultKeyID"] as? String,
                  !currentVaultKeyID.isEmpty else {
                throw ClientError.invalidResponse("Cloud Vault rotation requirement is missing or already consumed.")
            }
            let survivorDeviceIds = (data["survivorDeviceIds"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
            guard survivorDeviceIds.contains(rotatingDeviceId) else {
                throw ClientError.invalidResponse(
                    "This Mac is not a surviving trusted device for the required Cloud Vault rotation."
                )
            }

            self.currentVaultKeyID = currentVaultKeyID
            currentVaultGeneration = Self.intValue(data["currentVaultGeneration"]) ?? 1
            self.survivorDeviceIds = survivorDeviceIds
        }

        private static func intValue(_ raw: Any?) -> Int? {
            if let value = raw as? Int { return value }
            if let value = raw as? NSNumber { return value.intValue }
            return nil
        }
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

    /// Auth custom claims are account-level, so another signed-in platform can overwrite the
    /// `obb_app_check` binding between our bind and the nonce mint. Re-run the full
    /// bind -> claims refresh -> nonce sequence once when the mint is rejected at the
    /// App Check binding gate; rethrow every other failure unchanged.
    static func reboundHighRiskActionNonce(
        afterBindingConflict error: Error,
        rebindAttestation: () async throws -> Void = { try await bindAppCheckAttestation() }, // cov:ignore -- live App Check rebind + Auth claims refresh; the recovery decision is unit-tested with injected closures
        issueNonce: () async throws -> String = { try await issueHighRiskActionNonce() } // cov:ignore -- live Firebase nonce mint
    ) async throws -> String {
        guard isAppCheckBindingConflictError(error) else { throw error }
        try await rebindAttestation()
        return try await issueNonce()
    }

    static func isAppCheckBindingConflictError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code),
              code == .permissionDenied || code == .failedPrecondition else {
            return false
        }
        let message = nsError.localizedDescription
        return message.contains("App Check") || message.contains("bindAppCheckAttestation")
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
        // cov:ignore-start -- live Firebase attestation bind + nonce mint; the binding-conflict recovery decision is unit-tested with injected closures in ComputerUseSecurityCallableClientTests
        try await bindAppCheckAttestation()
        let nonce: String
        do {
            nonce = try await issueHighRiskActionNonce()
        } catch {
            nonce = try await reboundHighRiskActionNonce(afterBindingConflict: error)
        }
        // cov:ignore-end
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
        try await bindAppCheckAttestation() // cov:ignore -- live Firebase attestation bind before protected trust-chain writes
        let resolvedApproverDeviceId = approverDeviceId?.isEmpty == false ? approverDeviceId! : deviceId
        let trustChain = try await buildTrustChainProof(
            uid: uid,
            targetDeviceId: deviceId,
            approverDeviceId: resolvedApproverDeviceId
        )
        // cov:ignore-start -- live Firebase nonce mint; the binding-conflict recovery decision is unit-tested with injected closures in ComputerUseSecurityCallableClientTests
        let nonce: String
        do {
            nonce = try await issueHighRiskActionNonce()
        } catch {
            nonce = try await reboundHighRiskActionNonce(afterBindingConflict: error)
        }
        // cov:ignore-end
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
        guard let dict = result.data as? [String: Any] else {
            throw ClientError.invalidResponse("Escrow device trust revocation failed.")
        }
        let revocation = try parseEscrowDeviceTrustRevocationResult(dict)
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
                rotatingDeviceId: rotatingDeviceId,
                environment: .live(uid: uid, rotatingDeviceId: rotatingDeviceId)
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
    /// device is offline or cannot finish rotation locally,
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

        let pending = try await listPendingCloudVaultRotationRequirements(callerDeviceId: rotatingDeviceId)
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
                    rotatingDeviceId: rotatingDeviceId,
                    environment: .live(uid: uid, rotatingDeviceId: rotatingDeviceId)
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

    static func listPendingCallablePayload(callerDeviceId: String) -> [String: Any] {
        ["callerDeviceId": callerDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Lists the user's pending Cloud Vault rotation requirements via S1's
    /// server-only callable. The server is the source of truth for which
    /// requirements remain unconsumed; this client filters by survivor locally.
    static func listPendingCloudVaultRotationRequirements(
        callerDeviceId: String
    ) async throws -> [PendingCloudVaultRotationRequirement] {
        let callerDeviceId = callerDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callerDeviceId.isEmpty else {
            throw ClientError.invalidResponse("Could not list pending Cloud Vault rotation requirements.")
        }
        _ = try requireSignedInUser()
        let result = try await functions.httpsCallable("listPendingCloudVaultRotationRequirements")
            .call(listPendingCallablePayload(callerDeviceId: callerDeviceId))
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

    static func parseEscrowDeviceTrustRevocationResult(
        _ dict: [String: Any]
    ) throws -> EscrowDeviceTrustRevocationResult {
        guard dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Escrow device trust revocation failed.")
        }
        return EscrowDeviceTrustRevocationResult(
            revokedCloudVaultWrappers: dict["revokedCloudVaultWrappers"] as? Int ?? 0,
            cloudVaultRotationRequired: dict["cloudVaultRotationRequired"] as? Bool ?? false,
            cloudVaultRotationRequirementId: dict["cloudVaultRotationRequirementId"] as? String,
            cloudVaultRotationBlockedReason: dict["cloudVaultRotationBlockedReason"] as? String
        )
    }

    struct RevocationCloudVaultRotationResult {
        let jobId: String
        let progress: CloudVaultRotationRewrapProgress
    }

    struct RevocationCloudVaultRotationEnvironment {
        let loadRequirement: (String) async throws -> [String: Any]?
        let loadCurrentKey: () async throws -> CloudVaultResolvedKey?
        let loadLocalIdentity: () throws -> OpenBurnBarSignalIdentityKeypair
        let publishLocalIdentity: (OpenBurnBarSignalIdentityKeypair) async throws -> Void
        let verifiedTrustedDevice: (String, OpenBurnBarSignalIdentityKeypair) async throws -> CloudVaultVerifiedTrustedDevice
        let issueNonce: () async throws -> String
        let rotateCloudVaultKey: ([String: Any]) async throws -> [String: Any]
        let saveNextKey: (Data) throws -> Void
        let runDocumentRewrap: (String, Data, Data, String, Int) async throws -> CloudVaultRotationRewrapProgress
        let markRotationFailed: (String, Error) async -> Void

        // cov:ignore-start -- live Firebase/Firestore/keychain wiring; injected environment covers rotation logic
        static func live(uid: String, rotatingDeviceId: String) -> Self {
            let firestore = Firestore.firestore()
            let userRef = firestore.collection("users").document(uid)
            return Self(
                loadRequirement: { requirementId in
                    try await userRef.collection("cloud_vault_rotation_requirements")
                        .document(requirementId)
                        .getDocument()
                        .data()
                },
                loadCurrentKey: {
                    try await MacCloudVaultKeyAccess.keyForReading(
                        uid: uid,
                        deviceId: rotatingDeviceId,
                        firestore: firestore
                    )
                },
                loadLocalIdentity: {
                    try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(uid: uid, deviceId: rotatingDeviceId)
                },
                publishLocalIdentity: { localIdentity in
                    try await SignalIdentityPublicKeyPublisher.publishIfNeeded(
                        userRef: userRef,
                        deviceId: rotatingDeviceId,
                        platform: "macOS",
                        identity: localIdentity
                    )
                },
                verifiedTrustedDevice: { survivorDeviceId, localIdentity in
                    try await CloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevice(
                        uid: uid,
                        userRef: userRef,
                        deviceId: survivorDeviceId,
                        localIdentity: localIdentity
                    )
                },
                issueNonce: {
                    try await ComputerUseSecurityCallableClient.issueHighRiskActionNonce()
                },
                rotateCloudVaultKey: { payload in
                    let result = try await ComputerUseSecurityCallableClient.functions
                        .httpsCallable("rotateCloudVaultKey")
                        .call(payload)
                    guard let dict = result.data as? [String: Any] else {
                        return [:]
                    }
                    return dict
                },
                saveNextKey: { nextKey in
                    try CloudVaultKeyStore().saveKey(nextKey, uid: uid)
                },
                runDocumentRewrap: { jobId, oldKeyData, newKeyData, nextVaultKeyID, nextVaultGeneration in
                    var worker = CloudVaultRotationRewrapWorker()
                    worker.firestore = firestore
                    return try await worker.runDocumentRewrap(
                        uid: uid,
                        deviceId: rotatingDeviceId,
                        jobId: jobId,
                        oldKeyData: oldKeyData,
                        newKeyData: newKeyData,
                        newVaultKeyID: nextVaultKeyID,
                        vaultGeneration: nextVaultGeneration
                    )
                },
                markRotationFailed: { jobId, error in
                    do {
                        try await userRef.collection("cloud_vault_rotation_jobs").document(jobId).setData([
                            "status": "failed",
                            "failureReason": String(error.localizedDescription.prefix(500)),
                            "failedAt": FieldValue.serverTimestamp(),
                            "updatedAt": FieldValue.serverTimestamp()
                        ], merge: true)
                    } catch let statusWriteError {
                        // The caller still receives the local rewrap failure; this best-effort
                        // status write must not mask the actionable rotation error.
                        _ = statusWriteError.localizedDescription
                    }
                }
            )
        }
        // cov:ignore-end
    }

    static func performRevocationCloudVaultRotation(
        uid: String,
        requirementId: String,
        rotatingDeviceId: String,
        environment: RevocationCloudVaultRotationEnvironment
    ) async throws -> RevocationCloudVaultRotationResult {
        guard let requirement = try await environment.loadRequirement(requirementId) else {
            throw ClientError.invalidResponse("Cloud Vault rotation requirement is missing or already consumed.")
        }
        let rotationRequirement = try RevocationCloudVaultRotationRequirement(
            data: requirement,
            rotatingDeviceId: rotatingDeviceId
        )

        guard let currentKey = try await environment.loadCurrentKey() else {
            throw ClientError.invalidResponse("This Mac does not have the current Cloud Vault key needed to rotate after revocation.")
        }
        guard currentKey.vaultKeyID == rotationRequirement.currentVaultKeyID else {
            throw ClientError.invalidResponse(
                "Cloud Vault rotation requirement expected \(rotationRequirement.currentVaultKeyID), but this Mac has \(currentKey.vaultKeyID)."
            )
        }

        let localIdentity = try environment.loadLocalIdentity()
        try await environment.publishLocalIdentity(localIdentity)

        let nextKey = try CloudVaultCrypto.generateVaultKey()
        let nextVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: nextKey)
        let nextVaultGeneration = rotationRequirement.currentVaultGeneration + 1
        var survivorWrappers: [[String: Any]] = []
        for survivorDeviceId in rotationRequirement.survivorDeviceIds {
            let survivor = try await environment.verifiedTrustedDevice(survivorDeviceId, localIdentity)
            survivorWrappers.append(try survivorWrapper(
                nextKey: nextKey,
                nextVaultKeyID: nextVaultKeyID,
                rotatingDeviceId: rotatingDeviceId,
                survivor: survivor
            ))
        }

        let rotationNonce = try await environment.issueNonce()
        let rotationDict = try await environment.rotateCloudVaultKey(rotationCallablePayload(
            rotatingDeviceId: rotatingDeviceId,
            currentVaultKeyID: rotationRequirement.currentVaultKeyID,
            nextVaultKeyID: nextVaultKeyID,
            nextVaultGeneration: nextVaultGeneration,
            survivorWrappers: survivorWrappers,
            requirementId: requirementId,
            nonce: rotationNonce
        ))
        guard rotationDict["ok"] as? Bool == true,
              let jobId = rotationDict["jobId"] as? String,
              !jobId.isEmpty else {
            throw ClientError.invalidResponse("Cloud Vault key rotation was not queued.")
        }

        try environment.saveNextKey(nextKey)

        do {
            let progress = try await environment.runDocumentRewrap(
                jobId,
                currentKey.keyData,
                nextKey,
                nextVaultKeyID,
                nextVaultGeneration
            )
            return RevocationCloudVaultRotationResult(jobId: jobId, progress: progress)
        } catch let rewrapError {
            await environment.markRotationFailed(jobId, rewrapError)
            throw ClientError.invalidResponse(
                "Cloud Vault rotation job \(jobId) was queued, but local rewrap failed: \(rewrapError.localizedDescription)"
            )
        }
    }

    static func survivorWrapper(
        nextKey: Data,
        nextVaultKeyID: String,
        rotatingDeviceId: String,
        survivor: CloudVaultVerifiedTrustedDevice
    ) throws -> [String: Any] {
        let wrapped = try CloudVaultCrypto.wrapVaultKey(
            nextKey,
            recipientPublicKey: survivor.escrowPublicKeyData
        )
        return [
            "wrapperId": "\(nextVaultKeyID)_\(survivor.deviceId)_\(survivor.keyVersion)",
            "targetDeviceId": survivor.deviceId,
            "sourceDeviceId": rotatingDeviceId,
            "publicKeyFingerprint": survivor.escrowPublicKeyFingerprint,
            "keyVersion": survivor.keyVersion,
            "vaultKeyID": nextVaultKeyID,
            "wrappedVaultKey": wrapped.base64EncodedString()
        ]
    }

    static func rotationCallablePayload(
        rotatingDeviceId: String,
        currentVaultKeyID: String,
        nextVaultKeyID: String,
        nextVaultGeneration: Int,
        survivorWrappers: [[String: Any]],
        requirementId: String,
        nonce: String
    ) -> [String: Any] {
        [
            "callerDeviceId": rotatingDeviceId,
            "currentVaultKeyID": currentVaultKeyID,
            "newVaultKeyID": nextVaultKeyID,
            "expectedVaultGeneration": nextVaultGeneration,
            "survivorWrappers": survivorWrappers,
            "reason": "revocation_rewrap",
            "rotationRequirementId": requirementId,
            "nonce": nonce
        ]
    }

    static func publishIrohPairingPublicKey(
        deviceId: String,
        roleId: String = "host",
        publicKeyBase64: String
    ) async throws {
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        // cov:ignore-start -- live Firebase nonce mint; the binding-conflict recovery decision is unit-tested with injected closures in ComputerUseSecurityCallableClientTests
        let nonce: String
        do {
            nonce = try await issueHighRiskActionNonce()
        } catch {
            nonce = try await reboundHighRiskActionNonce(afterBindingConflict: error)
        }
        // cov:ignore-end
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
        // cov:ignore-start -- live Firebase nonce mint; the binding-conflict recovery decision is unit-tested with injected closures in ComputerUseSecurityCallableClientTests
        let nonce: String
        do {
            nonce = try await issueHighRiskActionNonce()
        } catch {
            nonce = try await reboundHighRiskActionNonce(afterBindingConflict: error)
        }
        // cov:ignore-end
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

    static func issuePhoneControlEnrollmentGrant(
        hostDeviceId: String,
        connectionId: String,
        controllerDeviceId: String,
        controllerPeerNodeId: String
    ) async throws {
        // cov:ignore-start -- live Firebase App Check bind, nonce mint, and callable invocation; the binding-conflict recovery decision is unit-tested with injected closures in ComputerUseSecurityCallableClientTests, and the router-side grant wiring is covered by MercuryRouterTests
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        let nonce: String
        do {
            nonce = try await issueHighRiskActionNonce()
        } catch {
            nonce = try await reboundHighRiskActionNonce(afterBindingConflict: error)
        }
        let result = try await functions.httpsCallable("issuePhoneControlEnrollmentGrant").call([
            "hostDeviceId": hostDeviceId,
            "connectionId": connectionId,
            "controllerDeviceId": controllerDeviceId,
            "controllerPeerNodeId": controllerPeerNodeId,
            "nonce": nonce
        ])
        guard let dict = result.data as? [String: Any],
              dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Phone-control enrollment approval failed.")
        }
        // cov:ignore-end
    }

    static func resolveActiveIrohControllerRoutes(
        uid: String,
        connectionId: String,
        authenticatedUID: () throws -> String = { try requireSignedInUser().uid },
        invokeCallable: (String) async throws -> Any = { connectionId in
            try await functions.httpsCallable("resolveActiveIrohControllerRoutes").call([
                "connectionId": connectionId
            ]).data
        }
    ) async throws -> [IrohControllerRouteBinding] {
        guard try authenticatedUID() == uid else {
            throw ClientError.invalidResponse("The active account changed before controller-route resolution.")
        }
        let raw = try await invokeCallable(connectionId)
        guard try authenticatedUID() == uid else {
            throw ClientError.invalidResponse("The active account changed during controller-route resolution.")
        }
        return try parseActiveIrohControllerRoutes(
            raw,
            expectedUID: uid,
            expectedConnectionId: connectionId
        )
    }

    static func parseActiveIrohControllerRoutes(
        _ raw: Any,
        expectedUID: String,
        expectedConnectionId: String,
        nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> [IrohControllerRouteBinding] {
        let maximumControllerRoutes = 16
        let response = try decodeCallableJSON(
            ActiveIrohControllerRoutesResponse.self,
            from: raw,
            invalidResponseMessage: "Active iroh controller-route resolution was malformed or stale."
        )
        guard response.uid == expectedUID,
              response.connectionId == expectedConnectionId,
              let resolvedAtMillis = response.resolvedAtMillis,
              resolvedAtMillis >= nowMillis - 60_000,
              resolvedAtMillis <= nowMillis + 30_000,
              response.routes.count <= maximumControllerRoutes else {
            throw ClientError.invalidResponse("Active iroh controller-route resolution was malformed or stale.")
        }
        var sourceDeviceIDs = Set<String>()
        var transportNodeIDs = Set<String>()
        var bindings: [IrohControllerRouteBinding] = []
        bindings.reserveCapacity(response.routes.count)
        for route in response.routes {
            guard
                route.connectionId == expectedConnectionId,
                route.generation > 0,
                route.registeredAtMillis <= resolvedAtMillis,
                route.expiresAtMillis > resolvedAtMillis,
                route.expiresAtMillis > nowMillis,
                sourceDeviceIDs.insert(route.sourceDeviceId).inserted,
                let binding = IrohControllerRouteBinding(
                    sourceDeviceId: route.sourceDeviceId,
                    transportNodeId: route.transportNodeId,
                    authorityPeerNodeId: route.authorityPeerNodeId,
                    generation: route.generation,
                    registeredAtMillis: route.registeredAtMillis,
                    expiresAtMillis: route.expiresAtMillis
                ),
                transportNodeIDs.insert(binding.transportNodeId).inserted else {
                throw ClientError.invalidResponse("Active iroh controller-route resolution was malformed or stale.")
            }
            bindings.append(binding)
        }
        return bindings
    }

    private struct ActiveIrohControllerRoutesResponse: Decodable {
        let uid: String
        let connectionId: String
        let resolvedAtMillis: Int64?
        let routes: [ActiveIrohControllerRouteResponse]
    }

    private struct ActiveIrohControllerRouteResponse: Decodable {
        let connectionId: String
        let sourceDeviceId: String
        let transportNodeId: String
        let authorityPeerNodeId: String
        let generation: UInt64
        let registeredAtMillis: Int64
        let expiresAtMillis: Int64
    }

    private static func decodeCallableJSON<Response: Decodable>(
        _ type: Response.Type,
        from raw: Any,
        invalidResponseMessage: String
    ) throws -> Response {
        guard JSONSerialization.isValidJSONObject(raw) else {
            throw ClientError.invalidResponse(invalidResponseMessage)
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: raw)
        } catch {
            throw ClientError.invalidResponse(invalidResponseMessage)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ClientError.invalidResponse(invalidResponseMessage)
        }
    }

    static func loadOrCreateLocalDeviceId(defaults: UserDefaults = .standard) -> String {
        OpenBurnBarCore.OpenBurnBarMigration.migrateUserDefaults()
        if let stored = defaults.string(forKey: OpenBurnBarCore.OpenBurnBarIdentity.deviceIDKey), !stored.isEmpty {
            return stored
        }
        for legacyKey in OpenBurnBarCore.OpenBurnBarIdentity.legacyDeviceIDKeys {
            if let stored = defaults.string(forKey: legacyKey), !stored.isEmpty {
                defaults.set(stored, forKey: OpenBurnBarCore.OpenBurnBarIdentity.deviceIDKey)
                return stored
            }
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: OpenBurnBarCore.OpenBurnBarIdentity.deviceIDKey)
        return created
    }

    /// Sanitizes provider account ids the same way `accountIDFor` does server-side.
    static func providerAccountSubjectId(provider: String, accountID: String?) -> String {
        let raw: String
        if let accountID, !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Preserve the ORIGINAL (untrimmed) account id; the sanitizer below
            // collapses and edge-trims the whitespace-derived hyphens.
            raw = accountID
        } else {
            raw = "\(provider)_default"
        }
        let sanitized = sanitizedProviderAccountSubjectFragment(raw)
        let fallback = sanitizedProviderAccountSubjectFragment("\(provider)_default")
        return sanitized.isEmpty ? fallback : sanitized
    }

    private static func sanitizedProviderAccountSubjectFragment(_ raw: String) -> String {
        var collapsed = ""
        var previousWasHyphen = false
        for scalar in raw.lowercased().unicodeScalars {
            let fragment: String
            switch scalar.value {
            case 48...57, 97...122, 95:
                fragment = String(scalar)
            case 45:
                fragment = "-"
            default:
                fragment = "-"
            }
            if fragment == "-" {
                guard !previousWasHyphen else { continue }
                previousWasHyphen = true
            } else {
                previousWasHyphen = false
            }
            collapsed.append(fragment)
        }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Builds nonce + trusted-device action proof fields for owner-action callables.
    static func highRiskOwnerActionEnvelope(
        actionKind: String,
        subjectId: String,
        deviceId: String,
        approve: Bool = true
    ) async throws -> [String: any Sendable] {
        let uid = try requireSignedInUser().uid
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        let identity = try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(uid: uid, deviceId: deviceId)
        let userRef = Firestore.firestore().collection("users").document(uid)
        try await SignalIdentityPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: deviceId,
            platform: "macOS",
            identity: identity
        )
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let proofPayload = CloudVaultTrustedDeviceActionProofPayload(
            uid: uid,
            deviceId: deviceId,
            actionKind: actionKind,
            subjectId: subjectId,
            approve: approve,
            nonce: nonce,
            issuedAtMillis: issuedAtMillis,
            deviceSignalIdentityKeyId: identity.identityKeyId,
            deviceSignalIdentityPublicKeyFingerprint: identity.publicKeyFingerprint
        )
        let signature = try CloudVaultTrustedDeviceActionProof.sign(proofPayload, identity: identity)
        let actionProof: [String: any Sendable] = [
            "version": CloudVaultTrustedDeviceActionProof.version,
            "algorithm": CloudVaultTrustedDeviceActionProof.algorithm,
            "deviceSignalIdentityKeyId": identity.identityKeyId,
            "deviceSignalIdentityPublicKeyFingerprint": identity.publicKeyFingerprint,
            "issuedAtMillis": issuedAtMillis,
            "signature": signature
        ]
        return [
            "nonce": nonce,
            "trustedDeviceId": deviceId,
            "actionProof": actionProof
        ]
    }

    @discardableResult
    static func callHighRiskOwnerAction(
        _ callableName: String,
        deviceId: String,
        actionKind: String,
        subjectId: String,
        payload: [String: any Sendable] = [:],
        approve: Bool = true
    ) async throws -> HTTPSCallableResult {
        var merged = payload
        let envelope = try await highRiskOwnerActionEnvelope(
            actionKind: actionKind,
            subjectId: subjectId,
            deviceId: deviceId,
            approve: approve
        )
        for (key, value) in envelope {
            merged[key] = value
        }
        return try await functions.httpsCallable(callableName).call(merged)
    }

    static func publishMissionApprovalCeiling(
        requestId: String,
        deviceId: String,
        canonical: [String: any Sendable],
        ceilingDigest: String,
        signature: String
    ) async throws {
        _ = try await callHighRiskOwnerAction(
            "publishMissionApprovalCeiling",
            deviceId: deviceId,
            actionKind: "mission_approval_ceiling_publish",
            subjectId: requestId,
            payload: [
                "requestId": requestId,
                "deviceId": deviceId,
                "canonical": canonical,
                "ceilingDigest": ceilingDigest,
                "signature": signature
            ]
        )
    }

    static func redeemMissionApprovalAnswer(
        requestId: String,
        deviceId: String,
        ceilingDigest: String,
        requestedGrant: [String: any Sendable]
    ) async throws {
        _ = try await callHighRiskOwnerAction(
            "redeemMissionApprovalAnswer",
            deviceId: deviceId,
            actionKind: "mission_approval_answer_redeem",
            subjectId: "\(requestId):\(ceilingDigest):approve",
            payload: [
                "requestId": requestId,
                "deviceId": deviceId,
                "ceilingDigest": ceilingDigest,
                "requestedGrant": requestedGrant
            ]
        )
    }

    static func createCliAgentMission(payload: [String: any Sendable], deviceId: String) async throws -> String {
        let requestId = payload["requestId"] as? String ?? ""
        let result = try await callHighRiskOwnerAction(
            "createCliAgentMission",
            deviceId: deviceId,
            actionKind: "cli_agent_mission_create",
            subjectId: requestId,
            payload: payload.merging(["deviceId": deviceId]) { _, new in new }
        )
        guard let dict = result.data as? [String: Any],
              dict["ok"] as? Bool == true,
              let id = dict["requestId"] as? String
        else {
            throw ClientError.invalidResponse("Mission create failed.")
        }
        return id
    }

    static func claimCliAgentMission(
        requestId: String,
        deviceId: String,
        nextStatus: String,
        selectedRuntime: String,
        selectedRuntimeName: String,
        selectedModelID: String?,
        approvalRequestId: String?,
        sealedStatePayload: [String: any Sendable]
    ) async throws -> String {
        var payload: [String: any Sendable] = [
            "requestId": requestId,
            "deviceId": deviceId,
            "nextStatus": nextStatus,
            "selectedRuntime": selectedRuntime,
            "selectedRuntimeName": selectedRuntimeName,
            "sealedStatePayload": sealedStatePayload
        ]
        if let selectedModelID { payload["selectedModelID"] = selectedModelID }
        if let approvalRequestId { payload["approvalRequestId"] = approvalRequestId }
        let result = try await callHighRiskOwnerAction(
            "claimCliAgentMission",
            deviceId: deviceId,
            actionKind: "cli_agent_mission_claim",
            subjectId: requestId,
            payload: payload
        )
        guard let dict = result.data as? [String: Any],
              dict["ok"] as? Bool == true,
              let nonce = dict["hostWriteNonce"] as? String
        else {
            throw ClientError.invalidResponse("Mission claim failed.")
        }
        return nonce
    }

    static func updateCliAgentMissionStatus(
        requestId: String,
        deviceId: String,
        status: String,
        hostWriteNonce: String,
        sealedStatePayload: [String: any Sendable],
        approvalRequestId: String? = nil,
        releaseClaim: Bool = false
    ) async throws {
        var payload: [String: any Sendable] = [
            "requestId": requestId,
            "deviceId": deviceId,
            "status": status,
            "hostWriteNonce": hostWriteNonce,
            "sealedStatePayload": sealedStatePayload
        ]
        if let approvalRequestId { payload["approvalRequestId"] = approvalRequestId }
        if releaseClaim { payload["releaseClaim"] = true }
        let result = try await callHighRiskOwnerAction(
            "updateCliAgentMissionStatus",
            deviceId: deviceId,
            actionKind: "cli_agent_mission_status",
            subjectId: requestId,
            payload: payload
        )
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Mission status update failed.")
        }
    }

    static func appendCliAgentMissionEvent(
        requestId: String,
        deviceId: String,
        hostWriteNonce: String,
        eventId: String,
        sealedEvent: [String: any Sendable],
        publicEventShape: [String: any Sendable]
    ) async throws {
        let result = try await callHighRiskOwnerAction(
            "appendCliAgentMissionEvent",
            deviceId: deviceId,
            actionKind: "cli_agent_mission_append_event",
            subjectId: requestId,
            payload: [
                "requestId": requestId,
                "deviceId": deviceId,
                "hostWriteNonce": hostWriteNonce,
                "eventId": eventId,
                "sealedEvent": sealedEvent,
                "publicEventShape": publicEventShape
            ]
        )
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Mission event append failed.")
        }
    }

    static func beginBurnbarAttachment(
        byteCount: Int64,
        contentBlake3: String,
        deviceId: String,
        transport: String = "cloud"
    ) async throws -> (id: String, chunkCount: Int) {
        let result = try await callHighRiskOwnerAction(
            "beginBurnbarAttachment",
            deviceId: deviceId,
            actionKind: "burnbar_attachment_begin",
            subjectId: "begin",
            payload: [
                "byteCount": byteCount,
                "contentBlake3": contentBlake3,
                "transport": transport,
                "deviceId": deviceId
            ]
        )
        guard let dict = result.data as? [String: Any],
              let id = dict["id"] as? String,
              let chunkCount = dict["chunkCount"] as? Int
        else {
            throw ClientError.invalidResponse("beginBurnbarAttachment failed.")
        }
        return (id, chunkCount)
    }

    static func mintBurnbarAttachmentPartURL(
        id: String,
        partIndex: Int,
        contentLength: Int64,
        deviceId: String
    ) async throws -> URL {
        let result = try await callHighRiskOwnerAction(
            "mintBurnbarAttachmentPartURL",
            deviceId: deviceId,
            actionKind: "burnbar_attachment_part",
            subjectId: id,
            payload: [
                "id": id,
                "partIndex": partIndex,
                "contentLength": contentLength,
                "deviceId": deviceId
            ]
        )
        guard let dict = result.data as? [String: Any],
              let urlString = dict["url"] as? String,
              let url = URL(string: urlString)
        else {
            throw ClientError.invalidResponse("mintBurnbarAttachmentPartURL failed.")
        }
        return url
    }

    static func composeBurnbarAttachment(id: String, deviceId: String) async throws {
        _ = try await callHighRiskOwnerAction(
            "composeBurnbarAttachment",
            deviceId: deviceId,
            actionKind: "burnbar_attachment_compose",
            subjectId: id,
            payload: ["id": id, "deviceId": deviceId]
        )
    }

    static func finalizeBurnbarAttachment(id: String, deviceId: String) async throws {
        _ = try await callHighRiskOwnerAction(
            "finalizeBurnbarAttachment",
            deviceId: deviceId,
            actionKind: "burnbar_attachment_finalize",
            subjectId: id,
            payload: ["id": id, "deviceId": deviceId]
        )
    }

    static func respondMissionApproval(requestId: String, approve: Bool, deviceId: String) async throws {
        let result = try await callHighRiskOwnerAction(
            "respondMissionApproval",
            deviceId: deviceId,
            actionKind: "computer_use_mission_approval",
            subjectId: requestId,
            payload: [
                "requestId": requestId,
                "approve": approve,
                "deviceId": deviceId
            ],
            approve: approve
        )
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Mission approval response failed.")
        }
    }

    static func respondHermesGatewayApproval(approvalId: String, approve: Bool, deviceId: String) async throws {
        let result = try await callHighRiskOwnerAction(
            "respondHermesGatewayApproval",
            deviceId: deviceId,
            actionKind: "hermes_gateway_approval",
            subjectId: approvalId,
            payload: [
                "approvalId": approvalId,
                "approve": approve,
                "deviceId": deviceId
            ],
            approve: approve
        )
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Gateway approval response failed.")
        }
    }
}
#endif
