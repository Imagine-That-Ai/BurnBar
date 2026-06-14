#if canImport(UIKit)
import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Publishes the phone-control signing public key to Firestore before the
/// `control.input` stream is classified.
///
/// The Mac must not trust a public key carried inside the same stream that key
/// is meant to authenticate. This publisher anchors the key in the user's
/// trusted-device namespace under the active `iroh_pairing/{connectionId}` doc
/// so the Mac can fetch it independently by `authorityPeerNodeId`.
protocol PhoneControlAuthorityPublishing: Sendable {
    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKey: Curve25519.Signing.PublicKey
    ) async throws

    /// F2: key-kind-aware publish — uploads the canonical published bytes
    /// (32-byte raw Ed25519 / 65-byte X9.63 P-256) plus the `keyKind`
    /// discriminator the server persists as `signingKeyKind`.
    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKeyRepresentation: Data,
        keyKind: PhoneControlSigningKeyKind
    ) async throws
}

final class PhoneControlAuthorityPublisher: PhoneControlAuthorityPublishing, Sendable {
    static let shared = PhoneControlAuthorityPublisher()

    init() {}

    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKey: Curve25519.Signing.PublicKey
    ) async throws {
        try await publish(
            uid: uid,
            connectionId: connectionId,
            deviceId: deviceId,
            peerNodeId: peerNodeId,
            publicKeyRepresentation: publicKey.rawRepresentation,
            keyKind: .ed25519
        )
    }

    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKeyRepresentation: Data,
        keyKind: PhoneControlSigningKeyKind
    ) async throws {
        try await ComputerUseSecurityCallableClient.publishPhoneControlAuthority(
            deviceId: deviceId,
            connectionId: connectionId,
            peerNodeId: peerNodeId,
            publicKeyBase64: publicKeyRepresentation.base64EncodedString(),
            publishedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            protocolVersion: HermesRealtimeRelayProtocol.version,
            keyKind: keyKind
        )
    }
}
#endif
