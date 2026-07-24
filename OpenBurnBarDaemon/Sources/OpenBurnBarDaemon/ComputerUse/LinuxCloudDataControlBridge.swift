#if os(Linux)
import Foundation

/// The two cloud data-control actions that require a trusted-device step-up.
/// The Linux installation never signs either action itself.
public enum LinuxCloudDataControlOperation: String, Codable, Hashable, Sendable {
    case export
    case delete
}

public enum LinuxCloudDataControlPhase: String, Codable, Hashable, Sendable {
    case unavailable
    case awaitingTrustedDevice = "awaiting_trusted_device"
    case executing
    case completed
    case failed
}

/// Redacted state safe for the shell/status RPC. It intentionally contains no
/// nonce, Firebase credential, proof, account UID, or export bytes.
public struct LinuxCloudDataControlStatus: Codable, Hashable, Sendable {
    public let phase: LinuxCloudDataControlPhase
    public let operation: LinuxCloudDataControlOperation?
    public let requestID: String?
    public let requestedAt: String?
    public let expiresAt: String?
    public let detail: String?

    public init(
        phase: LinuxCloudDataControlPhase,
        operation: LinuxCloudDataControlOperation? = nil,
        requestID: String? = nil,
        requestedAt: String? = nil,
        expiresAt: String? = nil,
        detail: String? = nil
    ) {
        self.phase = phase
        self.operation = operation
        self.requestID = requestID
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.detail = detail
    }

    public static let trustedDeviceBridgeUnavailable = LinuxCloudDataControlStatus(
        phase: .unavailable,
        detail: "trusted_device_bridge_unavailable"
    )
}

/// Request sent to the trusted-device transport. `subjectID` is used only by
/// the trusted device when constructing the canonical proof payload; it is not
/// surfaced by the Linux shell. The deletion request carries an explicit
/// confirmation requirement so a remote UI cannot silently turn an export
/// approval into an irreversible erase.
public struct LinuxCloudDataControlAuthorizationRequest: Sendable, Equatable {
    public let requestID: String
    public let operation: LinuxCloudDataControlOperation
    public let actionKind: String
    public let subjectID: String
    public let domains: [String]?
    public let requiresExplicitConfirmation: Bool
    public let requestedAt: Date
    public let expiresAt: Date

    public init(
        requestID: String,
        operation: LinuxCloudDataControlOperation,
        actionKind: String,
        subjectID: String,
        domains: [String]? = nil,
        requiresExplicitConfirmation: Bool,
        requestedAt: Date,
        expiresAt: Date
    ) {
        self.requestID = requestID
        self.operation = operation
        self.actionKind = actionKind
        self.subjectID = subjectID
        self.domains = domains
        self.requiresExplicitConfirmation = requiresExplicitConfirmation
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }
}

/// Opaque authorization returned by the trusted device. The daemon forwards
/// these values immediately and never persists them or exposes them to the
/// renderer.
public struct LinuxCloudTrustedDeviceAuthorization: Sendable, Equatable {
    public let nonce: String
    public let trustedDeviceID: String
    public let actionProof: LinuxCloudTrustedDeviceActionProof

    public init(
        nonce: String,
        trustedDeviceID: String,
        actionProof: LinuxCloudTrustedDeviceActionProof
    ) {
        self.nonce = nonce
        self.trustedDeviceID = trustedDeviceID
        self.actionProof = actionProof
    }

    /// Cheap local validation prevents malformed material from reaching a
    /// callable. Cryptographic validity and nonce consumption remain server
    /// responsibilities.
    func isWellFormed(now: Date) -> Bool {
        guard Self.isBoundedIdentifier(nonce),
              Self.isBoundedIdentifier(trustedDeviceID),
              actionProof.version == 1,
              actionProof.algorithm == "signal-identity-xeddsa-v1",
              Self.isBoundedIdentifier(actionProof.deviceSignalIdentityKeyId),
              Self.isBoundedIdentifier(actionProof.deviceSignalIdentityPublicKeyFingerprint),
              actionProof.issuedAtMillis > 0,
              let signatureData = Data(base64Encoded: actionProof.signature),
              (64...256).contains(signatureData.count) else {
            return false
        }
        let issuedAt = Date(timeIntervalSince1970: Double(actionProof.issuedAtMillis) / 1_000)
        return abs(now.timeIntervalSince(issuedAt)) <= 5 * 60
    }

    private static func isBoundedIdentifier(_ value: String) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= 256
            && value.contains("\n") == false
            && value.contains("\r") == false
            && value.allSatisfy { $0.isLetter || $0.isNumber || "._:+-/=".contains($0) }
    }
}

public enum LinuxCloudTrustedDeviceActionAuthorizationError: Error, Equatable, Sendable {
    case unavailable
    case rejected
    case expired
}

/// Implemented by the existing trusted-device/Iroh integration when that
/// transport can display the request and have the trusted device mint a fresh
/// nonce-bound XEdDSA proof. No default implementation is provided: an absent
/// authorizer is deliberately an unavailable state, never an implicit local
/// approval.
public protocol LinuxCloudTrustedDeviceActionAuthorizing: Sendable {
    func authorize(
        _ request: LinuxCloudDataControlAuthorizationRequest
    ) async throws -> LinuxCloudTrustedDeviceAuthorization
}

/// Small adapter useful for the eventual Iroh/mobile bridge and deterministic
/// daemon tests. The closure receives no Linux private key or Firebase token.
public struct LinuxCloudTrustedDeviceActionAuthorizer: LinuxCloudTrustedDeviceActionAuthorizing {
    private let handler: @Sendable (
        LinuxCloudDataControlAuthorizationRequest
    ) async throws -> LinuxCloudTrustedDeviceAuthorization

    public init(
        _ handler: @escaping @Sendable (
            LinuxCloudDataControlAuthorizationRequest
        ) async throws -> LinuxCloudTrustedDeviceAuthorization
    ) {
        self.handler = handler
    }

    public func authorize(
        _ request: LinuxCloudDataControlAuthorizationRequest
    ) async throws -> LinuxCloudTrustedDeviceAuthorization {
        try await handler(request)
    }
}
#endif
