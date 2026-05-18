#if canImport(UIKit)
import CryptoKit
import Foundation
@preconcurrency import FirebaseFirestore
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

    private let firestoreProvider: @Sendable () -> Firestore

    init(firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKey: Curve25519.Signing.PublicKey
    ) async throws {
        let payload: [String: Any] = [
            "id": peerNodeId,
            "connectionId": connectionId,
            "peerNodeId": peerNodeId,
            "deviceId": deviceId,
            "publicKeyBase64": publicKey.rawRepresentation.base64EncodedString(),
            "publishedAtMillis": Int64(Date().timeIntervalSince1970 * 1000),
            "protocolVersion": HermesRealtimeRelayProtocol.version,
            "schemaVersion": 1
        ]
        try await firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("iroh_pairing")
            .document(connectionId)
            .collection("controllers")
            .document(peerNodeId)
            .setData(payload, merge: true)
    }
}
#endif
