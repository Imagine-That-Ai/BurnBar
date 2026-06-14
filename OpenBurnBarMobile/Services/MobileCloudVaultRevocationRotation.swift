import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import UIKit

/// RR-5 — iOS survivor-side Cloud Vault rotation chain, mirroring Mac
/// `ComputerUseSecurityCallableClient` rotation methods and Android
/// `AndroidCloudVaultRevocationRotation`.
enum MobileCloudVaultRevocationRotation {
    enum RotationError: LocalizedError {
        case notAuthenticated
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Sign in before performing Cloud Vault rotation."
            case .invalidResponse(let detail):
                return detail
            }
        }
    }

    /// Outcome of one survivor-side rotation pickup pass.
    struct CloudVaultRotationPickupResult: Sendable, Equatable {
        let eligibleRequirementIds: [String]
        let completedRequirementIds: [String]
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

    /// A pending Cloud Vault rotation requirement, as returned by S1's server callable.
    struct PendingCloudVaultRotationRequirement: Sendable, Equatable {
        let requirementId: String
        let survivorDeviceIds: [String]
    }

    struct RevocationCloudVaultRotationResult {
        let jobId: String
        let progress: MobileCloudVaultRotationRewrapProgress
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
                throw RotationError.invalidResponse("Cloud Vault rotation requirement is missing or already consumed.")
            }
            let survivorDeviceIds = (data["survivorDeviceIds"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
            guard survivorDeviceIds.contains(rotatingDeviceId) else {
                throw RotationError.invalidResponse(
                    "This device is not a surviving trusted device for the required Cloud Vault rotation."
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

    struct RevocationCloudVaultRotationEnvironment {
        let loadRequirement: (String) async throws -> [String: Any]?
        let loadCurrentKey: () async throws -> MobileCloudVaultResolvedKey?
        let loadLocalIdentity: () throws -> OpenBurnBarSignalIdentityKeypair
        let publishLocalIdentity: (OpenBurnBarSignalIdentityKeypair) async throws -> Void
        let verifiedTrustedDevice: (String, OpenBurnBarSignalIdentityKeypair) async throws -> MobileCloudVaultVerifiedTrustedDevice
        let issueNonce: () async throws -> String
        let rotateCloudVaultKey: ([String: Any]) async throws -> [String: Any]
        let saveNextKey: (Data) throws -> Void
        let runDocumentRewrap: (String, Data, Data, String, Int) async throws -> MobileCloudVaultRotationRewrapProgress
        let markRotationFailed: (String, Error) async -> Void

        static func live(uid: String, rotatingDeviceId: String) -> Self {
            let firestore = Firestore.firestore()
            let userRef = firestore.collection("users").document(uid)
            let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
            return Self(
                loadRequirement: { requirementId in
                    try await userRef.collection("cloud_vault_rotation_requirements")
                        .document(requirementId)
                        .getDocument()
                        .data()
                },
                loadCurrentKey: {
                    try await MobileCloudVaultKeyAccess.keyForReading(uid: uid, firestore: firestore)
                },
                loadLocalIdentity: {
                    try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(uid: uid, deviceId: rotatingDeviceId)
                },
                publishLocalIdentity: { localIdentity in
                    try await MobileSignalIdentityPublicKeyPublisher.publishIfNeeded(
                        userRef: userRef,
                        deviceId: rotatingDeviceId,
                        platform: platform,
                        identity: localIdentity
                    )
                },
                verifiedTrustedDevice: { survivorDeviceId, localIdentity in
                    try await MobileCloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevice(
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
                    let result = try await Functions.functions(region: "us-central1")
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
                    var worker = MobileCloudVaultRotationRewrapWorker()
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
                    } catch {
                        _ = error.localizedDescription
                    }
                }
            )
        }
    }

    private static let inFlightRotationPickups = InFlightRotationPickupTracker()

    private actor InFlightRotationPickupTracker {
        private var ids: Set<String> = []

        func reserve(_ id: String) -> Bool {
            ids.insert(id).inserted
        }

        func release(_ id: String) {
            ids.remove(id)
        }
    }

    private static var functions: Functions {
        Functions.functions(region: "us-central1")
    }

    private static func requireSignedInUser() throws -> User {
        guard let user = Auth.auth().currentUser, user.isAnonymous == false else {
            throw RotationError.notAuthenticated
        }
        return user
    }

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

    static func listPendingCallablePayload(callerDeviceId: String) -> [String: Any] {
        ["callerDeviceId": callerDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    static func listPendingCloudVaultRotationRequirements(callerDeviceId: String) async throws -> [PendingCloudVaultRotationRequirement] {
        let callerDeviceId = callerDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callerDeviceId.isEmpty else {
            throw RotationError.invalidResponse("Could not list pending Cloud Vault rotation requirements.")
        }
        _ = try requireSignedInUser()
        let result = try await functions.httpsCallable("listPendingCloudVaultRotationRequirements")
            .call(listPendingCallablePayload(callerDeviceId: callerDeviceId))
        guard let dict = result.data as? [String: Any],
              let rawRequirements = dict["requirements"] as? [[String: Any]] else {
            throw RotationError.invalidResponse("Could not list pending Cloud Vault rotation requirements.")
        }
        return parsePendingRequirements(rawRequirements)
    }

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

    static func performRevocationCloudVaultRotation(
        uid: String,
        requirementId: String,
        rotatingDeviceId: String,
        environment: RevocationCloudVaultRotationEnvironment
    ) async throws -> RevocationCloudVaultRotationResult {
        guard let requirement = try await environment.loadRequirement(requirementId) else {
            throw RotationError.invalidResponse("Cloud Vault rotation requirement is missing or already consumed.")
        }
        let rotationRequirement = try RevocationCloudVaultRotationRequirement(
            data: requirement,
            rotatingDeviceId: rotatingDeviceId
        )

        guard let currentKey = try await environment.loadCurrentKey() else {
            throw RotationError.invalidResponse(
                "This device does not have the current Cloud Vault key needed to rotate after revocation."
            )
        }
        guard currentKey.vaultKeyID == rotationRequirement.currentVaultKeyID else {
            throw RotationError.invalidResponse(
                "Cloud Vault rotation requirement expected \(rotationRequirement.currentVaultKeyID), but this device has \(currentKey.vaultKeyID)."
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
            throw RotationError.invalidResponse("Cloud Vault key rotation was not queued.")
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
            throw RotationError.invalidResponse(
                "Cloud Vault rotation job \(jobId) was queued, but local rewrap failed: \(rewrapError.localizedDescription)"
            )
        }
    }

    static func survivorWrapper(
        nextKey: Data,
        nextVaultKeyID: String,
        rotatingDeviceId: String,
        survivor: MobileCloudVaultVerifiedTrustedDevice
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
}
