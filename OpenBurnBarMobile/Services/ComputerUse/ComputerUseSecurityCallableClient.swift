import CryptoKit
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import UIKit

/// WS4 iOS client for App Check attestation binding and escrow device trust callables.
enum ComputerUseSecurityCallableClient {
    private static let relaySenderProofProtocolVersion = "3"

    static let linuxAppCheckApproveActionKind = "linux_app_check_device_approve"
    static let linuxAppCheckRevokeActionKind = "linux_app_check_device_revoke"

    struct LinuxAppCheckTrustMutationDescriptor: Sendable, Equatable {
        let callableName: String
        let actionKind: String
        let subjectId: String
        let deviceId: String
        let approverDeviceId: String
        let approve: Bool
    }

    struct LinuxAppCheckDeviceListDependencies {
        let authenticatedUID: () -> String?
        let bindAppCheckAttestation: () async throws -> Void
        let callListDevices: (_ approverDeviceId: String) async throws -> Any
    }

    private struct EmptyCallableRequest: Encodable {}

    private struct OkCallableResponse: Decodable {
        let ok: Bool
    }

    private struct HighRiskNonceResponse: Decodable {
        let nonce: String
    }

    private struct LinuxAppCheckDevicesRequest: Encodable {
        let approverDeviceId: String
    }

    private struct LinuxAppCheckDevicesResponse: Decodable {
        let ok: Bool
        let devices: [LinuxAppCheckDevicePayload]
    }

    private struct LinuxAppCheckDevicePayload: Decodable {
        let deviceId: String
        let deviceName: String
        let platform: String
        let publicKeyBase64: String
        let safetyFingerprint: String
        let trustState: String
        let createdAtMillis: Int64
        let approvedAtMillis: Int64?
        let revokedAtMillis: Int64?
    }

    private struct PublishPhoneControlAuthorityRequest: Encodable {
        let deviceId: String
        let connectionId: String
        let peerNodeId: String
        let publicKeyBase64: String
        let publishedAtMillis: Int64
        let protocolVersion: Int
        let expectedUid: String
        let nonce: String
        let keyKind: String?
    }

    private struct IssueIrohControllerRouteChallengeRequest: Encodable {
        let sourceDeviceId: String
        let connectionId: String
        let authorityPeerNodeId: String
        let transportNodeId: String
        let expectedUid: String
        let nonce: String
    }

    private struct IrohControllerRouteChallengeResponse: Decodable {
        let challengeId: String
        let canonicalPayloadBase64: String
        let signatureAlgorithm: String
        let proofKind: String
        let registrationGeneration: Int64
        let issuedAtMillis: Int64
        let expiresAtMillis: Int64
    }

    private struct RegisterIrohControllerRouteRequest: Encodable {
        let challengeId: String
        let transportSignatureBase64: String
        let expectedUid: String
        let authoritySignatureBase64: String?
    }

    private struct IrohControllerRouteRegistrationResponse: Decodable {
        let ok: Bool
        let connectionId: String
        let sourceDeviceId: String
        let transportNodeId: String
        let authorityPeerNodeId: String
        let generation: Int64
        let expiresAtMillis: Int64
    }

    private struct RevokeIrohControllerRouteRequest: Encodable {
        let sourceDeviceId: String
        let connectionId: String
        let expectedUid: String
        let nonce: String
    }

    private struct RevokeIrohControllerRouteResponse: Decodable {
        let ok: Bool
        let sourceDeviceId: String
        let connectionId: String
        let generation: Int64
    }

    private struct QueueAgentCapabilityGrantCallableRequest: Encodable {
        let requestId: String
        let runtime: String
        let threadId: String
        let preset: String
        let capabilities: [String]
        let trustMode: String
        let deliveryMode: String
        let requestedAt: Date
        let expiresAt: Date
        let grantDurationSeconds: Double
        let sourceDeviceId: String
        let clientIntentId: String
        let localAuthenticationSatisfied: Bool
        let localAuthProof: HermesRealtimeRelayAgentGrantLocalAuthProof?
        let authority: HermesRealtimeRelayAuthorityEnvelope
        let nonce: String

        init(wirePayload: HermesRealtimeRelayAgentGrantRequest, nonce: String) {
            self.requestId = wirePayload.requestId
            self.runtime = wirePayload.runtime
            self.threadId = wirePayload.threadId
            self.preset = wirePayload.preset
            self.capabilities = wirePayload.capabilities
            self.trustMode = wirePayload.trustMode
            self.deliveryMode = wirePayload.deliveryMode
            self.requestedAt = wirePayload.requestedAt
            self.expiresAt = wirePayload.expiresAt
            self.grantDurationSeconds = wirePayload.grantDurationSeconds
            self.sourceDeviceId = wirePayload.sourceDeviceId
            self.clientIntentId = wirePayload.clientIntentId
            self.localAuthenticationSatisfied = wirePayload.localAuthenticationSatisfied
            self.localAuthProof = wirePayload.localAuthProof
            self.authority = wirePayload.authority
            self.nonce = nonce
        }
    }

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

        func withCompletedCloudVaultRotation(
            jobId: String,
            progress: MobileCloudVaultRotationRewrapProgress
        ) -> Self {
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

    private static let appCheckBindMaxAttempts = 3
    private static let appCheckBindRetryDelayNanoseconds: UInt64 = 1_500_000_000

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

    private struct TrustedSignalIdentityRepairChallengeResponse: Decodable {
        let ok: Bool
        let challengeId: String
        let challengeCiphertextBase64: String
        let schemaVersion: Int
    }

    private struct TrustedSignalIdentityRepairResponse: Decodable {
        let ok: Bool
        let reapprovalRequired: Bool
    }

    private static var functions: Functions {
        Functions.functions(region: "us-central1")
    }

    private static var signedInUser: User? {
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth().currentUser
    }

    static var authenticatedUID: String? {
        guard let user = signedInUser, user.isAnonymous == false else { return nil }
        return user.uid
    }

    private static func requireSignedInUser(expectedUID: String? = nil) throws -> User {
        guard let user = signedInUser, user.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        if let expectedUID, user.uid != expectedUID {
            throw ClientError.notAuthenticated
        }
        return user
    }

    private static func decodeCallableResponse<Value: Decodable>(
        _ rawValue: Any,
        as _: Value.Type,
        invalidMessage: String
    ) throws -> Value {
        guard JSONSerialization.isValidJSONObject(rawValue) else {
            throw ClientError.invalidResponse(invalidMessage)
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: rawValue)
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw ClientError.invalidResponse(invalidMessage)
        }
    }

    static func bindAppCheckAttestation() async throws {
        try await AppCheckAttestationBindingCoordinator.shared.run {
            try await bindAppCheckAttestationWithRetry()
        }
    }

    private static func bindAppCheckAttestationWithRetry() async throws {
        _ = try requireSignedInUser()

        for attempt in 1...appCheckBindMaxAttempts {
            do {
                _ = try await functions.httpsCallable("bindAppCheckAttestation").call([:])
                try await refreshAuthClaimsAfterBind()
                return
            } catch {
                guard attempt < appCheckBindMaxAttempts, isRetryableAppCheckBindError(error) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(attempt) * appCheckBindRetryDelayNanoseconds)
            }
        }

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
    private static func reboundHighRiskActionNonce(afterBindingConflict error: Error) async throws -> String {
        guard isAppCheckBindingConflictError(error) else { throw error }
        try await bindAppCheckAttestation()
        return try await issueHighRiskActionNonce()
    }

    private static func isAppCheckBindingConflictError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code),
              code == .permissionDenied || code == .failedPrecondition else {
            return false
        }
        let message = nsError.localizedDescription
        return message.contains("App Check") || message.contains("bindAppCheckAttestation")
    }

    static func listLinuxAppCheckDevices(approverDeviceId: String) async throws -> [LinuxAppCheckDeviceRecord] {
        try await listLinuxAppCheckDevices(
            approverDeviceId: approverDeviceId,
            dependencies: LinuxAppCheckDeviceListDependencies(
                authenticatedUID: { authenticatedUID },
                bindAppCheckAttestation: { try await bindAppCheckAttestation() },
                callListDevices: { approverDeviceId in
                    try await typedCallable(
                        "listLinuxAppCheckDevices",
                        LinuxAppCheckDevicesRequest(approverDeviceId: approverDeviceId),
                        invalidMessage: "Linux device list response was invalid.",
                        as: LinuxAppCheckDevicesResponse.self
                    )
                }
            )
        )
    }

    static func listLinuxAppCheckDevices(
        approverDeviceId: String,
        dependencies: LinuxAppCheckDeviceListDependencies
    ) async throws -> [LinuxAppCheckDeviceRecord] {
        guard let expectedUID = dependencies.authenticatedUID() else {
            throw ClientError.notAuthenticated
        }
        try await dependencies.bindAppCheckAttestation()
        guard dependencies.authenticatedUID() == expectedUID else {
            throw ClientError.notAuthenticated
        }
        let response = try await dependencies.callListDevices(approverDeviceId)
        guard dependencies.authenticatedUID() == expectedUID else {
            throw ClientError.notAuthenticated
        }
        return try parseLinuxAppCheckDevicesResponse(response)
    }

    static func setLinuxAppCheckDeviceTrust(
        deviceId: String,
        approverDeviceId: String,
        approve: Bool
    ) async throws {
        let descriptor = linuxAppCheckTrustMutationDescriptor(
            deviceId: deviceId,
            approverDeviceId: approverDeviceId,
            approve: approve
        )
        let result = try await callHighRiskOwnerAction(
            descriptor.callableName,
            deviceId: descriptor.approverDeviceId,
            actionKind: descriptor.actionKind,
            subjectId: descriptor.subjectId,
            payload: [
                "deviceId": descriptor.deviceId,
                "approverDeviceId": descriptor.approverDeviceId
            ],
            approve: descriptor.approve
        )
        let response = try decodeCallableResponse(
            OkCallableResponse.self,
            from: result.data,
            invalidMessage: approve ? "Linux device approval failed." : "Linux device revocation failed."
        )
        guard response.ok else {
            throw ClientError.invalidResponse(
                approve ? "Linux device approval failed." : "Linux device revocation failed."
            )
        }
    }

    static func linuxAppCheckTrustMutationDescriptor(
        deviceId: String,
        approverDeviceId: String,
        approve: Bool
    ) -> LinuxAppCheckTrustMutationDescriptor {
        LinuxAppCheckTrustMutationDescriptor(
            callableName: approve ? "approveLinuxAppCheckDevice" : "revokeLinuxAppCheckDevice",
            actionKind: approve ? linuxAppCheckApproveActionKind : linuxAppCheckRevokeActionKind,
            subjectId: deviceId,
            deviceId: deviceId,
            approverDeviceId: approverDeviceId,
            approve: approve
        )
    }

    static func parseLinuxAppCheckDevicesResponse(_ raw: Any) throws -> [LinuxAppCheckDeviceRecord] {
        let response: LinuxAppCheckDevicesResponse
        if let typed = raw as? LinuxAppCheckDevicesResponse {
            response = typed
        } else {
            response = try decodeCallableResponse(
                LinuxAppCheckDevicesResponse.self,
                from: raw,
                invalidMessage: "Linux device list response was invalid."
            )
        }
        guard response.ok else {
            throw ClientError.invalidResponse("Linux device list response was invalid.")
        }
        return try response.devices.map(validatedLinuxAppCheckDevice)
    }

    static func registerEscrowDevice(
        deviceId: String,
        deviceName: String,
        platform: String,
        appVersion: String? = nil,
        publicKeyFingerprint: String? = nil,
        keyVersion: Int? = nil
    ) async throws {
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        let nonce: String
        do {
            nonce = try await issueHighRiskActionNonce()
        } catch {
            nonce = try await reboundHighRiskActionNonce(afterBindingConflict: error)
        }
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

    static func approveEscrowDeviceTrust(deviceId: String, approverDeviceId: String? = nil) async throws {
        let uid = try requireSignedInUser().uid
        try await bindAppCheckAttestation()
        let resolvedApproverDeviceId = approverDeviceId?.isEmpty == false ? approverDeviceId! : deviceId
        let trustChain = try await buildTrustChainProof(
            uid: uid,
            targetDeviceId: deviceId,
            approverDeviceId: resolvedApproverDeviceId
        )
        let nonce: String
        do {
            nonce = try await issueHighRiskActionNonce()
        } catch {
            nonce = try await reboundHighRiskActionNonce(afterBindingConflict: error)
        }
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

    static func repairTrustedSignalIdentity(
        uid: String,
        deviceId: String,
        identity: OpenBurnBarSignalIdentityKeypair
    ) async throws {
        let user = try requireSignedInUser()
        guard user.uid == uid else {
            throw ClientError.invalidResponse("Signal identity repair user mismatch.")
        }
        try await bindAppCheckAttestation()

        let challengeResult = try await functions
            .httpsCallable("issueTrustedSignalIdentityRepairChallenge")
            .call(["deviceId": deviceId])
        let challenge = try decodeCallableResponse(
            challengeResult.data,
            as: TrustedSignalIdentityRepairChallengeResponse.self,
            invalidMessage: "Signal identity repair challenge was invalid."
        )
        guard challenge.ok,
              challenge.challengeId.isEmpty == false,
              let ciphertext = Data(base64Encoded: challenge.challengeCiphertextBase64),
              challenge.schemaVersion == MobileTrustedSignalIdentityRepairContract.challengeVersion else {
            throw ClientError.invalidResponse("Signal identity repair challenge was invalid.")
        }

        let escrowKeypair = try iOSDeviceKeypair()
        guard escrowKeypair.keyVersion == identity.keyVersion else {
            throw ClientError.invalidResponse("Signal identity and escrow key versions do not match.")
        }
        let plaintext = try escrowKeypair.decrypt(
            ciphertext,
            authenticating: MobileTrustedSignalIdentityRepairContract.challengeAAD(
                uid: uid,
                deviceId: deviceId,
                challengeId: challenge.challengeId
            )
        )
        let nonce = try await issueHighRiskActionNonce()
        let repairResult = try await functions.httpsCallable("repairTrustedSignalIdentity").call([
            "deviceId": deviceId,
            "challengeId": challenge.challengeId,
            "challengePlaintextBase64": plaintext.base64EncodedString(),
            "identityKeyId": identity.identityKeyId,
            "publicKeyData": identity.publicKeyBase64,
            "publicKeyFingerprint": identity.publicKeyFingerprint,
            "keyVersion": identity.keyVersion,
            "nonce": nonce
        ])
        let response = try decodeCallableResponse(
            repairResult.data,
            as: TrustedSignalIdentityRepairResponse.self,
            invalidMessage: "Signal identity repair failed."
        )
        guard response.ok, response.reapprovalRequired else {
            throw ClientError.invalidResponse("Signal identity repair failed.")
        }
    }

    private static func buildTrustChainProof(
        uid: String,
        targetDeviceId: String,
        approverDeviceId: String
    ) async throws -> [String: any Sendable] {
        let userRef = Firestore.firestore().collection("users").document(uid)
        let platform = await MainActor.run {
            UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        }
        let approverIdentity = try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(
            uid: uid,
            deviceId: approverDeviceId
        )
        try await MobileSignalIdentityPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: approverDeviceId,
            platform: platform,
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

    /// Revokes escrow device trust and, when required, drives the Cloud Vault rotation chain
    /// inline (mirrors Mac/Android). Pass `rotatingDeviceId` so this device can finish rotation.
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
                "Cloud Vault rotation is required, but this device's trusted device identity is unavailable."
            )
        }

        do {
            let rotation = try await MobileCloudVaultRevocationRotation.performRevocationCloudVaultRotation(
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

    static func publishPhoneControlAuthority(
        expectedUID: String,
        deviceId: String,
        connectionId: String,
        peerNodeId: String,
        publicKeyBase64: String,
        publishedAtMillis: Int64,
        protocolVersion: Int,
        keyKind: PhoneControlSigningKeyKind = .ed25519
    ) async throws {
        _ = try requireSignedInUser(expectedUID: expectedUID)
        try await bindAppCheckAttestation()
        _ = try requireSignedInUser(expectedUID: expectedUID)
        let nonce = try await issueHighRiskActionNonce(expectedUID: expectedUID)
        let response = try await typedCallable(
            "publishPhoneControlAuthority",
            PublishPhoneControlAuthorityRequest(
                deviceId: deviceId,
                connectionId: connectionId,
                peerNodeId: peerNodeId,
                publicKeyBase64: publicKeyBase64,
                publishedAtMillis: publishedAtMillis,
                protocolVersion: protocolVersion,
                expectedUid: expectedUID,
                nonce: nonce,
                keyKind: keyKind == .ed25519 ? nil : keyKind.rawValue
            ),
            invalidMessage: "Phone-control authority publication failed.",
            as: OkCallableResponse.self
        )
        _ = try requireSignedInUser(expectedUID: expectedUID)
        guard response.ok else {
            throw ClientError.invalidResponse("Phone-control authority publication failed.")
        }
    }

    static func issueIrohControllerRouteChallenge(
        expectedUID: String,
        sourceDeviceId: String,
        connectionId: String,
        authorityPeerNodeId: String,
        transportNodeId: String
    ) async throws -> IrohControllerRouteChallenge {
        _ = try requireSignedInUser(expectedUID: expectedUID)
        try await bindAppCheckAttestation()
        _ = try requireSignedInUser(expectedUID: expectedUID)
        let nonce = try await issueHighRiskActionNonce(expectedUID: expectedUID)
        let response = try await typedCallable(
            "issueIrohControllerRouteChallenge",
            IssueIrohControllerRouteChallengeRequest(
                sourceDeviceId: sourceDeviceId,
                connectionId: connectionId,
                authorityPeerNodeId: authorityPeerNodeId,
                transportNodeId: transportNodeId,
                expectedUid: expectedUID,
                nonce: nonce
            ),
            invalidMessage: "Controller-route challenge response was malformed.",
            as: IrohControllerRouteChallengeResponse.self
        )
        _ = try requireSignedInUser(expectedUID: expectedUID)
        guard let challengeId = nonempty(response.challengeId),
              let canonicalPayloadBase64 = nonempty(response.canonicalPayloadBase64),
              let signatureAlgorithm = nonempty(response.signatureAlgorithm),
              let proofKind = IrohControllerRouteProofKind(rawValue: response.proofKind),
              response.registrationGeneration > 0,
              response.issuedAtMillis > 0,
              response.expiresAtMillis > response.issuedAtMillis else {
            throw ClientError.invalidResponse("Controller-route challenge response was malformed.")
        }
        return IrohControllerRouteChallenge(
            challengeId: challengeId,
            canonicalPayloadBase64: canonicalPayloadBase64,
            signatureAlgorithm: signatureAlgorithm,
            proofKind: proofKind,
            registrationGeneration: response.registrationGeneration,
            issuedAtMillis: response.issuedAtMillis,
            expiresAtMillis: response.expiresAtMillis
        )
    }

    static func registerIrohControllerRoute(
        expectedUID: String,
        challengeId: String,
        transportSignatureBase64: String,
        authoritySignatureBase64: String?
    ) async throws -> IrohControllerRouteRegistration {
        _ = try requireSignedInUser(expectedUID: expectedUID)
        let response = try await typedCallable(
            "registerIrohControllerRoute",
            RegisterIrohControllerRouteRequest(
                challengeId: challengeId,
                transportSignatureBase64: transportSignatureBase64,
                expectedUid: expectedUID,
                authoritySignatureBase64: authoritySignatureBase64
            ),
            invalidMessage: "Controller-route registration response was malformed.",
            as: IrohControllerRouteRegistrationResponse.self
        )
        _ = try requireSignedInUser(expectedUID: expectedUID)
        guard response.ok,
              let connectionId = nonempty(response.connectionId),
              let sourceDeviceId = nonempty(response.sourceDeviceId),
              let transportNodeId = nonempty(response.transportNodeId),
              let authorityPeerNodeId = nonempty(response.authorityPeerNodeId),
              response.generation > 0,
              response.expiresAtMillis > 0 else {
            throw ClientError.invalidResponse("Controller-route registration response was malformed.")
        }
        return IrohControllerRouteRegistration(
            connectionId: connectionId,
            sourceDeviceId: sourceDeviceId,
            transportNodeId: transportNodeId,
            authorityPeerNodeId: authorityPeerNodeId,
            generation: response.generation,
            expiresAtMillis: response.expiresAtMillis
        )
    }

    static func revokeIrohControllerRoute(
        expectedUID: String,
        sourceDeviceId: String,
        connectionId: String
    ) async throws {
        _ = try requireSignedInUser(expectedUID: expectedUID)
        try await bindAppCheckAttestation()
        _ = try requireSignedInUser(expectedUID: expectedUID)
        let nonce = try await issueHighRiskActionNonce(expectedUID: expectedUID)
        let response = try await typedCallable(
            "revokeIrohControllerRoute",
            RevokeIrohControllerRouteRequest(
                sourceDeviceId: sourceDeviceId,
                connectionId: connectionId,
                expectedUid: expectedUID,
                nonce: nonce
            ),
            invalidMessage: "Controller-route revocation response was malformed.",
            as: RevokeIrohControllerRouteResponse.self
        )
        _ = try requireSignedInUser(expectedUID: expectedUID)
        guard response.ok,
              response.sourceDeviceId == sourceDeviceId,
              response.connectionId == connectionId,
              response.generation >= 0 else {
            throw ClientError.invalidResponse("Controller-route revocation response was malformed.")
        }
    }

    private static func issueHighRiskActionNonce(expectedUID: String) async throws -> String {
        _ = try requireSignedInUser(expectedUID: expectedUID)
        let result = try await functions.httpsCallable("issueHighRiskActionNonce").call([:])
        _ = try requireSignedInUser(expectedUID: expectedUID)
        let response = try decodeCallableResponse(
            HighRiskNonceResponse.self,
            from: result.data,
            invalidMessage: "Could not obtain a high-risk action nonce."
        )
        guard !response.nonce.isEmpty else {
            throw ClientError.invalidResponse("Could not obtain a high-risk action nonce.")
        }
        return response.nonce
    }

    static func positiveInt64(_ raw: Any?) -> Int64? {
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let doubleValue = number.doubleValue
            let decimalValue = number.decimalValue
            var integralValue = Decimal()
            var valueToRound = decimalValue
            NSDecimalRound(&integralValue, &valueToRound, 0, .down)
            guard doubleValue.isFinite,
                  decimalValue > 0,
                  decimalValue <= Decimal(Int64.max),
                  integralValue == decimalValue else {
                return nil
            }
            return NSDecimalNumber(decimal: decimalValue).int64Value
        }
        if let integer = raw as? Int64, integer > 0 { return integer }
        if let integer = raw as? Int, integer > 0 { return Int64(integer) }
        return nil
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private static func groupedFingerprint(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    private static func typedCallable<Request: Encodable, Response: Decodable>(
        _ name: String,
        _ request: Request,
        invalidMessage: String,
        as responseType: Response.Type
    ) async throws -> Response {
        do {
            return try await FirebaseCallableExecutor.call(name, request, using: functions)
        } catch FunctionsError.responseDecodingFailed {
            throw ClientError.invalidResponse(invalidMessage)
        }
    }

    private static func decodeCallableResponse<Response: Decodable>(
        _ responseType: Response.Type,
        from raw: Any?,
        invalidMessage: String
    ) throws -> Response {
        do {
            return try FirebaseCallableExecutor.decodeResponse(responseType, from: raw)
        } catch FunctionsError.responseDecodingFailed {
            throw ClientError.invalidResponse(invalidMessage)
        }
    }

    private static func validatedLinuxAppCheckDevice(
        _ payload: LinuxAppCheckDevicePayload
    ) throws -> LinuxAppCheckDeviceRecord {
        guard !payload.deviceId.isEmpty,
              !payload.deviceName.isEmpty,
              payload.platform == "Linux",
              let publicKey = Data(base64Encoded: payload.publicKeyBase64),
              publicKey.count == 32,
              let trustState = LinuxAppCheckDeviceTrustState(rawValue: payload.trustState)
        else {
            throw ClientError.invalidResponse("A Linux device record was invalid.")
        }
        let digestHex = SHA256.hash(data: publicKey)
            .map { String(format: "%02x", $0) }
            .joined()
        let safetyFingerprint = groupedFingerprint(digestHex.uppercased())
        guard payload.deviceId == "linux_\(digestHex)",
              payload.safetyFingerprint == safetyFingerprint else {
            throw ClientError.invalidResponse("A Linux device safety fingerprint did not match its public key.")
        }
        return LinuxAppCheckDeviceRecord(
            deviceId: payload.deviceId,
            deviceName: payload.deviceName,
            safetyFingerprint: safetyFingerprint,
            trustState: trustState,
            createdAtMillis: payload.createdAtMillis,
            approvedAtMillis: payload.approvedAtMillis,
            revokedAtMillis: payload.revokedAtMillis
        )
    }

    static func publishRelaySenderKey(
        deviceId: String,
        peerNodeId: String,
        keyId: String,
        publicKeyBase64: String,
        relayKeyVersion: Int,
        publishedAtMillis: Int64,
        signalIdentityKeyId: String,
        signalIdentityKeyVersion: Int,
        signalIdentityPublicKeyFingerprint: String
    ) async throws {
        let subjectId = try relaySenderKeyPublishProofSubjectId(
            deviceId: deviceId,
            peerNodeId: peerNodeId,
            keyId: keyId,
            publicKeyBase64: publicKeyBase64,
            publishedAtMillis: publishedAtMillis,
            signalIdentityKeyId: signalIdentityKeyId,
            signalIdentityKeyVersion: signalIdentityKeyVersion,
            signalIdentityPublicKeyFingerprint: signalIdentityPublicKeyFingerprint
        )
        var payload: [String: any Sendable] = [
            "deviceId": deviceId,
            "peerNodeId": peerNodeId,
            "keyId": keyId,
            "publicKeyBase64": publicKeyBase64,
            "relayKeyVersion": relayKeyVersion,
            "publishedAtMillis": publishedAtMillis,
            "signalIdentityKeyId": signalIdentityKeyId,
            "signalIdentityKeyVersion": signalIdentityKeyVersion,
            "signalIdentityPublicKeyFingerprint": signalIdentityPublicKeyFingerprint
        ]
        let envelope = try await highRiskOwnerActionEnvelope(
            actionKind: "relay_sender_key_publish",
            subjectId: subjectId,
            deviceId: deviceId
        )
        for (key, value) in envelope {
            payload[key] = value
        }
        let result = try await functions.httpsCallable("publishRelaySenderKey").call(payload)
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Relay sender-key publication failed.")
        }
    }

    static func publishAgentGrantAuthority(
        deviceId: String,
        peerNodeId: String,
        publicKeyBase64: String,
        keyKind: PhoneControlSigningKeyKind = .ed25519
    ) async throws {
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        var payload: [String: Any] = [
            "deviceId": deviceId,
            "peerNodeId": peerNodeId,
            "publicKeyBase64": publicKeyBase64,
            "nonce": nonce
        ]
        if keyKind != .ed25519 {
            payload["keyKind"] = keyKind.rawValue
        }
        let result = try await functions.httpsCallable("publishAgentGrantAuthority").call(payload)
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Agent grant authority publication failed.")
        }
    }

    static func queueAgentCapabilityGrantRequest(_ wirePayload: HermesRealtimeRelayAgentGrantRequest) async throws {
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        let response = try await typedCallable(
            "queueAgentCapabilityGrantRequest",
            QueueAgentCapabilityGrantCallableRequest(wirePayload: wirePayload, nonce: nonce),
            invalidMessage: "Agent grant request queueing failed.",
            as: OkCallableResponse.self
        )
        guard response.ok else {
            throw ClientError.invalidResponse("Agent grant request queueing failed.")
        }
    }

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

    private static func relaySenderKeyPublishProofSubjectId(
        deviceId: String,
        peerNodeId: String,
        keyId: String,
        publicKeyBase64: String,
        publishedAtMillis: Int64,
        signalIdentityKeyId: String,
        signalIdentityKeyVersion: Int,
        signalIdentityPublicKeyFingerprint: String
    ) throws -> String {
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
            throw ClientError.invalidResponse("Relay sender public key is not valid base64.")
        }
        let publicKeySHA256Hex = SHA256.hash(data: publicKeyData)
            .map { String(format: "%02x", $0) }
            .joined()
        let segments = [
            "version",
            "1",
            "deviceId",
            deviceId,
            "peerNodeId",
            peerNodeId,
            "keyId",
            keyId,
            "publicKeySHA256Hex",
            publicKeySHA256Hex,
            "relayKeyVersion",
            relaySenderProofProtocolVersion,
            "publishedAtMillis",
            "\(publishedAtMillis)",
            "signalIdentityKeyId",
            signalIdentityKeyId,
            "signalIdentityKeyVersion",
            "\(signalIdentityKeyVersion)",
            "signalIdentityPublicKeyFingerprint",
            signalIdentityPublicKeyFingerprint
        ]
        var canonical = "OpenBurnBar-RelaySenderKeyPublish-v1\n"
        for segment in segments {
            canonical += "\(Data(segment.utf8).count):\(segment)\n"
        }
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

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
        let platform = await MainActor.run {
            UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        }
        let userRef = Firestore.firestore().collection("users").document(uid)
        try await MobileSignalIdentityPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: deviceId,
            platform: platform,
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

    /// Narrows an untyped JSON object to the value types Firebase can safely
    /// carry across this Swift 6 async boundary.
    static func sendableJSONPayload(_ object: [String: Any]) -> [String: any Sendable] {
        object.reduce(into: [String: any Sendable]()) { result, entry in
            if let value = sendableJSONValue(entry.value) {
                result[entry.key] = value
            }
        }
    }

    private static func sendableJSONValue(_ value: Any) -> (any Sendable)? {
        switch value {
        case let value as String: return value
        case let value as Bool: return value
        case let value as Int: return value
        case let value as Double: return value
        case let value as NSNumber: return value.doubleValue
        case is NSNull: return nil
        case let value as [Any]: return value.compactMap(sendableJSONValue)
        case let value as [String: Any]: return sendableJSONPayload(value)
        default: return nil
        }
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

    static func createCliAgentMission(
        payload: [String: any Sendable],
        deviceId: String
    ) async throws -> String {
        let requestId = payload["requestId"] as? String ?? ""
        var callablePayload = payload
        callablePayload["deviceId"] = deviceId
        let result = try await callHighRiskOwnerAction(
            "createCliAgentMission",
            deviceId: deviceId,
            actionKind: "cli_agent_mission_create",
            subjectId: requestId,
            payload: callablePayload
        )
        guard let dict = result.data as? [String: Any],
              dict["ok"] as? Bool == true,
              let id = dict["requestId"] as? String
        else {
            throw ClientError.invalidResponse("Mission create failed.")
        }
        return id
    }

    static func cancelCliAgentMission(
        requestId: String,
        deviceId: String,
        sealedStatePayload: [String: any Sendable]
    ) async throws {
        let result = try await callHighRiskOwnerAction(
            "cancelCliAgentMission",
            deviceId: deviceId,
            actionKind: "cli_agent_mission_cancel",
            subjectId: requestId,
            payload: [
                "requestId": requestId,
                "deviceId": deviceId,
                "sealedStatePayload": sealedStatePayload
            ]
        )
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Mission cancel failed.")
        }
    }

    /// Bind a CLI-agent mission approve/reject decision to this trusted native
    /// escrow device via the App-Check-enforced `respondMissionApproval` callable.
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

    /// Bind a Hermes Gateway oversight approve/reject decision to this trusted
    /// native escrow device via the App-Check-enforced
    /// `respondHermesGatewayApproval` callable. Mirrors `respondMissionApproval`
    /// but targets the gateway's own `hermes_gateway_approvals` collection.
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

    private static func refreshAuthClaimsAfterBind() async throws {
        let user = try requireSignedInUser()
        _ = try await user.getIDTokenResult(forcingRefresh: true)
    }

    private static func isRetryableAppCheckBindError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == FunctionsErrorDomain,
           let code = FunctionsErrorCode(rawValue: nsError.code) {
            switch code {
            case .deadlineExceeded, .unavailable, .internal, .resourceExhausted, .aborted:
                return true
            default:
                return false
            }
        }

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNotConnectedToInternet:
                return true
            default:
                return false
            }
        }

        let normalizedDescription = nsError.localizedDescription
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        return normalizedDescription.contains("deadlineexceeded")
            || normalizedDescription.contains("timedout")
    }
}

private actor AppCheckAttestationBindingCoordinator {
    static let shared = AppCheckAttestationBindingCoordinator()

    private var inFlight: Task<Void, Error>?

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        if let inFlight {
            try await inFlight.value
            return
        }

        let task = Task {
            try await operation()
        }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
        return
    }
}
