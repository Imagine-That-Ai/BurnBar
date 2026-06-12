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

    private static func requireSignedInUser() throws -> User {
        guard let user = signedInUser, user.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
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

    static func revokeEscrowDeviceTrust(deviceId: String) async throws {
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        let result = try await functions.httpsCallable("revokeEscrowDeviceTrust").call([
            "deviceId": deviceId,
            "nonce": nonce
        ])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Escrow device trust revocation failed.")
        }
    }

    static func publishPhoneControlAuthority(
        deviceId: String,
        connectionId: String,
        peerNodeId: String,
        publicKeyBase64: String,
        publishedAtMillis: Int64,
        protocolVersion: Int,
        keyKind: PhoneControlSigningKeyKind = .ed25519
    ) async throws {
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        var payload: [String: Any] = [
            "deviceId": deviceId,
            "connectionId": connectionId,
            "peerNodeId": peerNodeId,
            "publicKeyBase64": publicKeyBase64,
            "publishedAtMillis": publishedAtMillis,
            "protocolVersion": protocolVersion,
            "nonce": nonce
        ]
        // F2: legacy publishes stay byte-identical (no keyKind field); an
        // SE-P256 identity sends the discriminator the server persists as
        // `signingKeyKind` (schemaVersion 3).
        if keyKind != .ed25519 {
            payload["keyKind"] = keyKind.rawValue
        }
        let result = try await functions.httpsCallable("publishPhoneControlAuthority").call(payload)
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Phone-control authority publication failed.")
        }
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
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        let result = try await functions.httpsCallable("publishRelaySenderKey").call([
            "deviceId": deviceId,
            "peerNodeId": peerNodeId,
            "keyId": keyId,
            "publicKeyBase64": publicKeyBase64,
            "relayKeyVersion": relayKeyVersion,
            "publishedAtMillis": publishedAtMillis,
            "signalIdentityKeyId": signalIdentityKeyId,
            "signalIdentityKeyVersion": signalIdentityKeyVersion,
            "signalIdentityPublicKeyFingerprint": signalIdentityPublicKeyFingerprint,
            "nonce": nonce
        ])
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

    static func queueAgentCapabilityGrantRequest(_ wirePayload: [String: Any]) async throws {
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

    /// Bind a CLI-agent mission approve/reject decision to this trusted native
    /// escrow device via the App-Check-enforced `respondMissionApproval` callable.
    static func respondMissionApproval(requestId: String, approve: Bool, deviceId: String) async throws {
        _ = try requireSignedInUser()
        let result = try await functions.httpsCallable("respondMissionApproval").call([
            "requestId": requestId,
            "approve": approve,
            "deviceId": deviceId
        ])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Mission approval response failed.")
        }
    }

    /// Bind a Hermes Gateway oversight approve/reject decision to this trusted
    /// native escrow device via the App-Check-enforced
    /// `respondHermesGatewayApproval` callable. Mirrors `respondMissionApproval`
    /// but targets the gateway's own `hermes_gateway_approvals` collection.
    static func respondHermesGatewayApproval(approvalId: String, approve: Bool, deviceId: String) async throws {
        _ = try requireSignedInUser()
        let result = try await functions.httpsCallable("respondHermesGatewayApproval").call([
            "approvalId": approvalId,
            "approve": approve,
            "deviceId": deviceId
        ])
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
