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

    private static func requireSignedInUser() throws -> User {
        guard let user = signedInUser, user.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        return user
    }

    private static func requireSignedInUser(expectedUID: String) throws -> User {
        let user = try requireSignedInUser()
        guard user.uid == expectedUID else { throw ClientError.notAuthenticated }
        return user
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

    static func listLinuxAppCheckDevices(approverDeviceId: String) async throws -> [LinuxAppCheckDeviceRecord] {
        try await listLinuxAppCheckDevices(
            approverDeviceId: approverDeviceId,
            dependencies: LinuxAppCheckDeviceListDependencies(
                authenticatedUID: { authenticatedUID },
                bindAppCheckAttestation: { try await bindAppCheckAttestation() },
                callListDevices: { approverDeviceId in
                    let result = try await functions.httpsCallable("listLinuxAppCheckDevices").call([
                        "approverDeviceId": approverDeviceId
                    ])
                    return result.data
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
        guard let response = result.data as? [String: Any], response["ok"] as? Bool == true else {
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
        guard let response = raw as? [String: Any],
              response["ok"] as? Bool == true,
              let devices = response["devices"] as? [[String: Any]]
        else {
            throw ClientError.invalidResponse("Linux device list response was invalid.")
        }
        return try devices.map { try LinuxAppCheckDeviceRecord(callablePayload: $0) }
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
        var payload: [String: Any] = [
            "deviceId": deviceId,
            "connectionId": connectionId,
            "peerNodeId": peerNodeId,
            "publicKeyBase64": publicKeyBase64,
            "publishedAtMillis": publishedAtMillis,
            "protocolVersion": protocolVersion,
            "expectedUid": expectedUID,
            "nonce": nonce
        ]
        // F2: legacy publishes stay byte-identical (no keyKind field); an
        // SE-P256 identity sends the discriminator the server persists as
        // `signingKeyKind` (schemaVersion 3).
        if keyKind != .ed25519 {
            payload["keyKind"] = keyKind.rawValue
        }
        let result = try await functions.httpsCallable("publishPhoneControlAuthority").call(payload)
        _ = try requireSignedInUser(expectedUID: expectedUID)
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
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
        let result = try await functions.httpsCallable("issueIrohControllerRouteChallenge").call([
            "sourceDeviceId": sourceDeviceId,
            "connectionId": connectionId,
            "authorityPeerNodeId": authorityPeerNodeId,
            "transportNodeId": transportNodeId,
            "expectedUid": expectedUID,
            "nonce": nonce
        ])
        _ = try requireSignedInUser(expectedUID: expectedUID)
        guard let dict = result.data as? [String: Any],
              let challengeId = requiredNonemptyString(dict, key: "challengeId"),
              let canonicalPayloadBase64 = requiredNonemptyString(dict, key: "canonicalPayloadBase64"),
              let signatureAlgorithm = requiredNonemptyString(dict, key: "signatureAlgorithm"),
              let proofKindRaw = requiredNonemptyString(dict, key: "proofKind"),
              let proofKind = IrohControllerRouteProofKind(rawValue: proofKindRaw),
              let registrationGeneration = positiveInt64(dict, key: "registrationGeneration"),
              let issuedAtMillis = positiveInt64(dict, key: "issuedAtMillis"),
              let expiresAtMillis = positiveInt64(dict, key: "expiresAtMillis"),
              expiresAtMillis > issuedAtMillis else {
            throw ClientError.invalidResponse("Controller-route challenge response was malformed.")
        }
        return IrohControllerRouteChallenge(
            challengeId: challengeId,
            canonicalPayloadBase64: canonicalPayloadBase64,
            signatureAlgorithm: signatureAlgorithm,
            proofKind: proofKind,
            registrationGeneration: registrationGeneration,
            issuedAtMillis: issuedAtMillis,
            expiresAtMillis: expiresAtMillis
        )
    }

    static func registerIrohControllerRoute(
        expectedUID: String,
        challengeId: String,
        transportSignatureBase64: String,
        authoritySignatureBase64: String?
    ) async throws -> IrohControllerRouteRegistration {
        _ = try requireSignedInUser(expectedUID: expectedUID)
        var payload: [String: Any] = [
            "challengeId": challengeId,
            "transportSignatureBase64": transportSignatureBase64,
            "expectedUid": expectedUID
        ]
        if let authoritySignatureBase64 {
            payload["authoritySignatureBase64"] = authoritySignatureBase64
        }
        let result = try await functions.httpsCallable("registerIrohControllerRoute").call(payload)
        _ = try requireSignedInUser(expectedUID: expectedUID)
        guard let dict = result.data as? [String: Any],
              dict["ok"] as? Bool == true,
              let connectionId = requiredNonemptyString(dict, key: "connectionId"),
              let sourceDeviceId = requiredNonemptyString(dict, key: "sourceDeviceId"),
              let transportNodeId = requiredNonemptyString(dict, key: "transportNodeId"),
              let authorityPeerNodeId = requiredNonemptyString(dict, key: "authorityPeerNodeId"),
              let generation = positiveInt64(dict, key: "generation"),
              let expiresAtMillis = positiveInt64(dict, key: "expiresAtMillis") else {
            throw ClientError.invalidResponse("Controller-route registration response was malformed.")
        }
        return IrohControllerRouteRegistration(
            connectionId: connectionId,
            sourceDeviceId: sourceDeviceId,
            transportNodeId: transportNodeId,
            authorityPeerNodeId: authorityPeerNodeId,
            generation: generation,
            expiresAtMillis: expiresAtMillis
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
        let result = try await functions.httpsCallable("revokeIrohControllerRoute").call([
            "sourceDeviceId": sourceDeviceId,
            "connectionId": connectionId,
            "expectedUid": expectedUID,
            "nonce": nonce
        ])
        _ = try requireSignedInUser(expectedUID: expectedUID)
        guard let dict = result.data as? [String: Any],
              dict["ok"] as? Bool == true,
              requiredNonemptyString(dict, key: "sourceDeviceId") == sourceDeviceId,
              requiredNonemptyString(dict, key: "connectionId") == connectionId,
              nonnegativeInt64(dict, key: "generation") != nil else {
            throw ClientError.invalidResponse("Controller-route revocation response was malformed.")
        }
    }

    private static func issueHighRiskActionNonce(expectedUID: String) async throws -> String {
        _ = try requireSignedInUser(expectedUID: expectedUID)
        let result = try await functions.httpsCallable("issueHighRiskActionNonce").call([:])
        _ = try requireSignedInUser(expectedUID: expectedUID)
        guard let dict = result.data as? [String: Any],
              let nonce = dict["nonce"] as? String,
              !nonce.isEmpty else {
            throw ClientError.invalidResponse("Could not obtain a high-risk action nonce.")
        }
        return nonce
    }

    private static func requiredNonemptyString(_ dictionary: [String: Any], key: String) -> String? {
        guard let value = dictionary[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    static func positiveInt64(_ dictionary: [String: Any], key: String) -> Int64? {
        if let number = dictionary[key] as? NSNumber {
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
        if let integer = dictionary[key] as? Int64, integer > 0 { return integer }
        if let integer = dictionary[key] as? Int, integer > 0 { return Int64(integer) }
        return nil
    }

    private static func nonnegativeInt64(_ dictionary: [String: Any], key: String) -> Int64? {
        guard let number = dictionary[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let decimalValue = number.decimalValue
        var integralValue = Decimal()
        var valueToRound = decimalValue
        NSDecimalRound(&integralValue, &valueToRound, 0, .down)
        guard number.doubleValue.isFinite,
              decimalValue >= 0,
              decimalValue <= Decimal(Int64.max),
              integralValue == decimalValue else { return nil }
        return NSDecimalNumber(decimal: decimalValue).int64Value
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

    static func queueAgentCapabilityGrantRequest(_ wirePayload: sending [String: Any]) async throws {
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        var payload = wirePayload
        payload["nonce"] = nonce
        let result = try await functions.httpsCallable("queueAgentCapabilityGrantRequest").call(payload)
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
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
