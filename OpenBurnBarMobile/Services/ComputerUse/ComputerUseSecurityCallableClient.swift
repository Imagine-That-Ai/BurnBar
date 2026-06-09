import FirebaseAuth
import FirebaseFunctions
import Foundation

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

    static func bindAppCheckAttestation() async throws {
        try await AppCheckAttestationBindingCoordinator.shared.run {
            try await bindAppCheckAttestationWithRetry()
        }
    }

    private static func bindAppCheckAttestationWithRetry() async throws {
        guard Auth.auth().currentUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }

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
        guard Auth.auth().currentUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
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

    static func revokeEscrowDeviceTrust(deviceId: String) async throws {
        guard Auth.auth().currentUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
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

    static func publishPhoneControlAuthority(
        deviceId: String,
        connectionId: String,
        peerNodeId: String,
        publicKeyBase64: String,
        publishedAtMillis: Int64,
        protocolVersion: Int
    ) async throws {
        guard Auth.auth().currentUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        try await bindAppCheckAttestation()
        let nonce = try await issueHighRiskActionNonce()
        let result = try await functions.httpsCallable("publishPhoneControlAuthority").call([
            "deviceId": deviceId,
            "connectionId": connectionId,
            "peerNodeId": peerNodeId,
            "publicKeyBase64": publicKeyBase64,
            "publishedAtMillis": publishedAtMillis,
            "protocolVersion": protocolVersion,
            "nonce": nonce,
        ])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Phone-control authority publication failed.")
        }
    }

    /// Bind a CLI-agent mission approve/reject decision to this trusted native
    /// escrow device via the App-Check-enforced `respondMissionApproval` callable.
    static func respondMissionApproval(requestId: String, approve: Bool, deviceId: String) async throws {
        guard Auth.auth().currentUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        let result = try await functions.httpsCallable("respondMissionApproval").call([
            "requestId": requestId,
            "approve": approve,
            "deviceId": deviceId,
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
        guard Auth.auth().currentUser?.isAnonymous == false else {
            throw ClientError.notAuthenticated
        }
        let result = try await functions.httpsCallable("respondHermesGatewayApproval").call([
            "approvalId": approvalId,
            "approve": approve,
            "deviceId": deviceId,
        ])
        guard let dict = result.data as? [String: Any], dict["ok"] as? Bool == true else {
            throw ClientError.invalidResponse("Gateway approval response failed.")
        }
    }

    private static func refreshAuthClaimsAfterBind() async throws {
        guard let user = Auth.auth().currentUser else {
            throw ClientError.notAuthenticated
        }
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
            return try await inFlight.value
        }

        let task = Task {
            try await operation()
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
