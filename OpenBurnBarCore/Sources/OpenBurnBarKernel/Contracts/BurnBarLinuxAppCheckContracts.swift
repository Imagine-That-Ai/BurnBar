import Foundation

public enum BurnBarLinuxAppCheckState: String, Codable, Hashable, Sendable {
    case unavailable
    case acquiring
    case ready
}

/// Redacted daemon status for Linux Firebase App Check. The bearer token and
/// attestation evidence never cross the daemon RPC boundary.
public struct BurnBarLinuxAppCheckStatusResponse: Codable, Hashable, Sendable {
    public let state: BurnBarLinuxAppCheckState
    public let trustClass: String
    public let expiresAt: String?

    public init(
        state: BurnBarLinuxAppCheckState,
        trustClass: String = "linux_lower_trust",
        expiresAt: String? = nil
    ) {
        self.state = state
        self.trustClass = trustClass
        self.expiresAt = expiresAt
    }
}
