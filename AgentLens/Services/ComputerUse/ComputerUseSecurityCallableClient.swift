#if canImport(AppKit)
import FirebaseAuth
import FirebaseCore
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

    private static var signedInUser: User? {
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth().currentUser
    }

    /// Binds the signed-in user's Auth custom claims to the current App Check app id.
    /// Call after sign-in when cloud sync is enabled and before high-risk CU actions.
    static func bindAppCheckAttestation() async throws {
        guard signedInUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        _ = try await functions.httpsCallable("bindAppCheckAttestation").call([:])
        try await refreshAuthClaimsAfterBind()
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
        guard signedInUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        var payload: [String: Any] = [
            "deviceId": deviceId,
            "deviceName": deviceName,
            "platform": platform,
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
        guard let user = signedInUser else {
            throw ClientError.notAuthenticated
        }
        _ = try await user.getIDTokenResult(forcingRefresh: true)
    }

    /// Elevates an escrow device to `trusted` via the server-only callable (Firestore rules block client writes).
    static func approveEscrowDeviceTrust(deviceId: String) async throws {
        guard signedInUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        let result = try await functions.httpsCallable("approveEscrowDeviceTrust").call([
            "deviceId": deviceId
        ])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Escrow device trust approval failed.")
        }
    }

    /// Revokes escrow device trust and active grants server-side.
    static func revokeEscrowDeviceTrust(deviceId: String) async throws {
        guard signedInUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        let result = try await functions.httpsCallable("revokeEscrowDeviceTrust").call([
            "deviceId": deviceId
        ])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Escrow device trust revocation failed.")
        }
    }
}
#endif
