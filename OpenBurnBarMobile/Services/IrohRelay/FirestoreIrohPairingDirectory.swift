import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// Mobile (iOS / iPadOS) `IrohPairingDirectory`. Reads
/// `/users/{uid}/iroh_pairing/{connectionId}` written by the Mac via
/// `AgentLens/.../FirestoreIrohPairingDirectory.swift`. Mobile is a pure
/// reader; the `publish` / `revoke` calls are no-ops because mobile does
/// not host an iroh endpoint in Phase 4 (mobile is the dialer).
final class FirestoreIrohPairingDirectory: IrohPairingDirectory, @unchecked Sendable {
    static let shared = FirestoreIrohPairingDirectory()

    private let firestoreProvider: @Sendable () -> Firestore

    init(firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func publish(_ record: IrohPairingRecord, for uid: String) async throws {
        // Mobile never publishes — only the Mac signs records. Surface as a
        // no-op so the shared `IrohPairingPublisher.publish(...)` path stays
        // generic; in practice mobile callers should never reach this.
        return
    }

    func fetch(uid: String, connectionId: String) async throws -> IrohPairingRecord? {
        let snapshot = try await firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("iroh_pairing")
            .document(connectionId)
            .getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return decode(data: data, uid: uid)
    }

    func revoke(uid: String, connectionId: String) async throws {
        // Same rationale as `publish` — mobile is a reader only.
        return
    }

    private func decode(data: [String: Any], uid: String) -> IrohPairingRecord? {
        guard let id = data["id"] as? String,
              let nodeId = data["nodeId"] as? String,
              let publishedAtMillis = data["publishedAtMillis"] as? Int64
                ?? (data["publishedAtMillis"] as? NSNumber)?.int64Value,
              let signature = data["signature"] as? String else {
            return nil
        }
        let protocolVersion = (data["protocolVersion"] as? Int)
            ?? (data["protocolVersion"] as? NSNumber)?.intValue
            ?? IrohRelayProtocol.frameProtocolVersion
        return IrohPairingRecord(
            uid: uid,
            connectionId: id,
            nodeId: nodeId,
            publishedAtMillis: publishedAtMillis,
            protocolVersion: protocolVersion,
            signature: signature
        )
    }
}
