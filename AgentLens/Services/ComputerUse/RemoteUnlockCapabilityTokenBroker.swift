#if canImport(AppKit) && !DISTRIBUTION_MAS
import CryptoKit
import Foundation
import OpenBurnBarComputerUseCore

/// Mints single-use Remote Unlock capability tokens only while an attested unlock session is pending.
@MainActor
public final class RemoteUnlockCapabilityTokenBroker {
    public static let shared = RemoteUnlockCapabilityTokenBroker(
        readiness: MacRemoteUnlockReadinessService.shared,
        signingKeyStore: .shared
    )

    private let issuer = CapabilityTokenIssuer()
    private let readiness: MacRemoteUnlockReadinessService
    private let signingKeyStore: RemoteUnlockCapabilitySigningKeyStore
    private let sessionContextStore: RemoteUnlockSessionContextSnapshotStore
    private let sessionContextSigner: RemoteUnlockSessionContextSnapshotSigner

    init(
        readiness: MacRemoteUnlockReadinessService,
        signingKeyStore: RemoteUnlockCapabilitySigningKeyStore,
        sessionContextStore: RemoteUnlockSessionContextSnapshotStore = RemoteUnlockSessionContextSnapshotStore(),
        sessionContextSigner: RemoteUnlockSessionContextSnapshotSigner = RemoteUnlockSessionContextSnapshotSigner()
    ) {
        self.readiness = readiness
        self.signingKeyStore = signingKeyStore
        self.sessionContextStore = sessionContextStore
        self.sessionContextSigner = sessionContextSigner
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
        let activeBinding = readiness.activeRemoteUnlockBinding(
            sessionId: sessionId,
            peerNodeId: peerNodeId,
            viewerDeviceId: viewerDeviceId,
            now: now
        )
        let keyMaterial = try signingKeyStore.copyOrCreateKeyMaterial()
        let token = try issuer.mintRemoteUnlockToken(
            privateKey: keyMaterial.privateKey,
            scopeHash: scopeHash,
            actionKind: actionKind,
            boundEscrowDeviceId: boundEscrowDeviceId ?? activeBinding?.viewerDeviceId,
            attestationHashBlake3: attestationHashBlake3 ?? activeBinding?.attestationHashBlake3
        )
        let snapshot = RemoteUnlockSessionContextSnapshot(
            sessionId: sessionId,
            peerNodeId: peerNodeId,
            scopeHash: token.scopeHash,
            escrowDeviceId: token.boundEscrowDeviceId,
            attestationHashBlake3: token.attestationHashBlake3,
            issuedAt: token.issuedAt,
            expiresAt: token.expiresAt,
            issuerKeyId: keyMaterial.keyId
        )
        let signedSnapshot = try sessionContextSigner.sign(
            snapshot: snapshot,
            privateKey: keyMaterial.privateKey
        )
        try sessionContextStore.save(signedSnapshot, now: now)
        return token
    }
}
#endif
