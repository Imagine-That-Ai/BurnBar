#if canImport(UIKit)
import CryptoKit
import Foundation
import OpenBurnBarCore

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
}

final class PhoneControlAuthorityPublisher: PhoneControlAuthorityPublishing, @unchecked Sendable {
    static let shared = PhoneControlAuthorityPublisher()

    init() {}

    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKey: Curve25519.Signing.PublicKey
    ) async throws {
        try await ComputerUseSecurityCallableClient.publishPhoneControlAuthority(
            deviceId: deviceId,
            connectionId: connectionId,
            peerNodeId: peerNodeId,
            publicKeyBase64: publicKey.rawRepresentation.base64EncodedString(),
            publishedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            protocolVersion: HermesRealtimeRelayProtocol.version
        )
    }
}
#endif
