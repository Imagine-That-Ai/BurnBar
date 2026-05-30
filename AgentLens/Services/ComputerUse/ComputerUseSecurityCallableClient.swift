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
    }

    /// Elevates an escrow device to `trusted` via the server-only callable (Firestore rules block client writes).
    static func approveEscrowDeviceTrust(deviceId: String) async throws {
        guard Auth.auth().currentUser?.isAnonymous == false else {
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
        guard Auth.auth().currentUser?.isAnonymous == false else {
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
