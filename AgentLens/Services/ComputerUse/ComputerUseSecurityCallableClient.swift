#if canImport(AppKit)
import FirebaseAuth
import FirebaseFunctions
import Foundation

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

    /// Binds the signed-in user's Auth custom claims to the current App Check app id.
    /// Call after sign-in when cloud sync is enabled and before high-risk CU actions.
    static func bindAppCheckAttestation() async throws {
        guard Auth.auth().currentUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        _ = try await functions.httpsCallable("bindAppCheckAttestation").call([:])
        try await refreshAuthClaimsAfterBind()
    }

    /// Fetch a single-use, short-lived nonce to attach to a high-risk action,
    /// providing replay resistance on top of the 30-day attestation binding.
    static func issueHighRiskActionNonce() async throws -> String {
        guard Auth.auth().currentUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
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
        guard Auth.auth().currentUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
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
        guard let user = Auth.auth().currentUser else {
            throw ClientError.notAuthenticated
        }
        _ = try await user.getIDTokenResult(forcingRefresh: true)
    }

    /// Elevates an escrow device to `trusted` via the server-only callable (Firestore rules block client writes).
    static func approveEscrowDeviceTrust(deviceId: String, approverDeviceId: String? = nil) async throws {
        guard Auth.auth().currentUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        let nonce = try await issueHighRiskActionNonce()
        var payload: [String: Any] = [
            "deviceId": deviceId,
            "nonce": nonce,
        ]
        if let approverDeviceId, !approverDeviceId.isEmpty {
            payload["approverDeviceId"] = approverDeviceId
        }
        let result = try await functions.httpsCallable("approveEscrowDeviceTrust").call(payload)
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Escrow device trust approval failed.")
        }
    }

    /// Revokes escrow device trust and active grants server-side.
    static func revokeEscrowDeviceTrust(deviceId: String) async throws {
        guard Auth.auth().currentUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        let nonce = try await issueHighRiskActionNonce()
        let result = try await functions.httpsCallable("revokeEscrowDeviceTrust").call([
            "deviceId": deviceId,
            "nonce": nonce,
        ])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Escrow device trust revocation failed.")
        }
    }
}
#endif
