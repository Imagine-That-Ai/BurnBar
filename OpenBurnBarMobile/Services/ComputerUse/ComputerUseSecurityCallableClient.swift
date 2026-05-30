import FirebaseAuth
import FirebaseFunctions
import Foundation

/// WS4 iOS client for App Check attestation binding and escrow device trust callables.
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

    static func bindAppCheckAttestation() async throws {
        guard Auth.auth().currentUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        _ = try await functions.httpsCallable("bindAppCheckAttestation").call([:])
        try await refreshAuthClaimsAfterBind()
    }

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

    private static func refreshAuthClaimsAfterBind() async throws {
        guard let user = Auth.auth().currentUser else {
            throw ClientError.notAuthenticated
        }
        _ = try await user.getIDTokenResult(forcingRefresh: true)
    }
}
