import Foundation

/// Short-lived, domain-tagged capability for privileged input leaves (Remote Unlock vs Computer Use).
///
/// Schema-synced via `tools/schema-sync/typespec/domains/computer-use.tsp`. Remote Unlock tokens are
/// single-use and verified offline at the bridge; Computer Use tokens are minted in-process by the PDP.
public struct CapabilityToken: Codable, Hashable, Sendable {
    public enum Domain: String, Codable, Sendable, Hashable, CaseIterable {
        case remoteUnlock = "remote_unlock"
        case computerUse = "computer_use"
    }

    public static let schemaVersion: Int = 1

    public let schemaVersion: Int
    public let domain: Domain
    public let nonce: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let allowedActionKinds: [String]
    public let scopeHash: String
    public let actionBudget: Int
    public let boundEscrowDeviceId: String?
    public let attestationHashBlake3: String?
    public var signatureEd25519Base64: String?

    public init(
        domain: Domain,
        nonce: String,
        issuedAt: Date,
        expiresAt: Date,
        allowedActionKinds: [String],
        scopeHash: String,
        actionBudget: Int,
        boundEscrowDeviceId: String? = nil,
        attestationHashBlake3: String? = nil,
        signatureEd25519Base64: String? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.domain = domain
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.allowedActionKinds = allowedActionKinds
        self.scopeHash = scopeHash
        self.actionBudget = actionBudget
        self.boundEscrowDeviceId = boundEscrowDeviceId
        self.attestationHashBlake3 = attestationHashBlake3
        self.signatureEd25519Base64 = signatureEd25519Base64
    }

    public static func canonicalDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        now >= expiresAt
    }

    public func allows(actionKind: String) -> Bool {
        let normalized = actionKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowedActionKinds.contains { $0.lowercased() == normalized }
    }
}
