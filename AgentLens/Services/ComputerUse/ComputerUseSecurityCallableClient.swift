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
            "nonce": nonce,
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
            "trustChain": trustChain,
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
    static func revokeEscrowDeviceTrust(deviceId: String) async throws {
        _ = try requireSignedInUser()
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        let result = try await functions.httpsCallable("revokeEscrowDeviceTrust").call([
            "deviceId": deviceId,
            "nonce": nonce,
        ])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Escrow device trust revocation failed.")
        }
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
            "nonce": nonce,
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
            "nonce": nonce,
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
            "nonce": nonce,
        ])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Iroh pairing record revocation failed.")
        }
    }
}
#endif
