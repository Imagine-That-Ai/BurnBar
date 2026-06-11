import Foundation
import CryptoKit

/// Mints short-lived, domain-tagged capability tokens for privileged input leaves.
public struct CapabilityTokenIssuer: Sendable {
    public static let remoteUnlockDefaultTTL: TimeInterval = 30
    public static let computerUseDefaultTTL: TimeInterval = 120

    public static let remoteUnlockAllowedActionKinds: [String] = [
        "click",
        "pointer_move",
        "key",
        "shortcut",
        "type_credential"
    ]

    private let signer = CapabilityTokenSigner()

    public init() {}

    public func mintRemoteUnlockToken(
        privateKey: Curve25519.Signing.PrivateKey,
        scopeHash: String,
        actionKind: String,
        boundEscrowDeviceId: String? = nil,
        attestationHashBlake3: String? = nil,
        ttl: TimeInterval = remoteUnlockDefaultTTL,
        now: Date = Date(),
        nonce: String = UUID().uuidString.lowercased()
    ) throws -> CapabilityToken {
        let allowed = Self.remoteUnlockAllowedActionKinds.contains(actionKind)
            ? [actionKind]
            : Self.remoteUnlockAllowedActionKinds
        let token = CapabilityToken(
            domain: .remoteUnlock,
            nonce: nonce,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            allowedActionKinds: allowed,
            scopeHash: scopeHash,
            actionBudget: 1,
            boundEscrowDeviceId: boundEscrowDeviceId,
            attestationHashBlake3: attestationHashBlake3
        )
        return try signer.sign(token: token, privateKey: privateKey)
    }

    public func mintComputerUseToken(
        privateKey: Curve25519.Signing.PrivateKey,
        scopeHash: String,
        allowedActionKinds: [String],
        actionBudget: Int,
        attestationHashBlake3: String? = nil,
        boundEscrowDeviceId: String? = nil,
        ttl: TimeInterval = computerUseDefaultTTL,
        now: Date = Date(),
        nonce: String = UUID().uuidString.lowercased()
    ) throws -> CapabilityToken {
        let token = CapabilityToken(
            domain: .computerUse,
            nonce: nonce,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            allowedActionKinds: allowedActionKinds,
            scopeHash: scopeHash,
            actionBudget: max(1, actionBudget),
            boundEscrowDeviceId: boundEscrowDeviceId,
            attestationHashBlake3: attestationHashBlake3
        )
        return try signer.sign(token: token, privateKey: privateKey)
    }
}
