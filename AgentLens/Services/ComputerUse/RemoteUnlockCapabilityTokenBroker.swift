#if canImport(AppKit) && !DISTRIBUTION_MAS
import CryptoKit
import Foundation
import OpenBurnBarComputerUseCore

/// Mints single-use Remote Unlock capability tokens only while an attested unlock session is pending.
@MainActor
public final class RemoteUnlockCapabilityTokenBroker {
    public static let shared = RemoteUnlockCapabilityTokenBroker()

    private let issuer = CapabilityTokenIssuer()
    private let readiness: MacRemoteUnlockReadinessService
    private let signingKeyStore: RemoteUnlockCapabilitySigningKeyStore

    public init(
        readiness: MacRemoteUnlockReadinessService = .shared,
        signingKeyStore: RemoteUnlockCapabilitySigningKeyStore = .shared
    ) {
        self.readiness = readiness
        self.signingKeyStore = signingKeyStore
    }

    /// Call after certification or first unlock setup so the bridge can verify tokens offline.
    public func ensureIssuerTrustPublished() throws {
        try signingKeyStore.publishIssuerTrust()
    }

    public func revokeIssuerTrust() throws {
        try signingKeyStore.revokePublishedTrust()
    }

    /// Returns a signed token for one Virtual HID `"input"` dispatch, or nil when no pending session exists.
    public func mintInputToken(
        actionKind: String,
        scopeHash: String,
        attestationHashBlake3: String? = nil,
        boundEscrowDeviceId: String? = nil,
        sessionId: String? = nil,
        peerNodeId: String? = nil,
        viewerDeviceId: String? = nil,
        now: Date = Date()
    ) throws -> CapabilityToken? {
        guard let sessionId, let peerNodeId else { return nil }
        guard readiness.isRemoteUnlockSessionActive(
            sessionId: sessionId,
            peerNodeId: peerNodeId,
            viewerDeviceId: viewerDeviceId,
            now: now
        ) else {
            return nil
        }
        let keyMaterial = try signingKeyStore.copyOrCreateKeyMaterial()
        return try issuer.mintRemoteUnlockToken(
            privateKey: keyMaterial.privateKey,
            scopeHash: scopeHash,
            actionKind: actionKind,
            boundEscrowDeviceId: boundEscrowDeviceId,
            attestationHashBlake3: attestationHashBlake3
        )
    }
}
#endif
