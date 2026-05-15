import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// Firestore-backed `IrohPairingDirectory`. Mac side: writes
/// `/users/{uid}/iroh_pairing/{connectionId}` whenever the iroh endpoint
/// boots and on heartbeat. iOS side: reads + verifies before dialing.
///
/// Schema matches `IrohPairingRecordDoc` in `functions/src/types.ts`:
///
/// ```
/// {
///   id: <connectionId>,
///   nodeId: <base32 NodeId>,
///   publishedAtMillis: <ms since epoch>,
///   protocolVersion: 1,
///   signature: <base64 Ed25519 signature>,
///   createdAt: <ISO8601>,
///   updatedAt: <ISO8601>,
///   schemaVersion: 1
/// }
/// ```
final class FirestoreIrohPairingDirectory: IrohPairingDirectory, @unchecked Sendable {
    static let shared = FirestoreIrohPairingDirectory()

    private let firestoreProvider: @Sendable () -> Firestore
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func publish(_ record: IrohPairingRecord, for uid: String) async throws {
        let now = isoFormatter.string(from: Date())
        let payload: [String: Any] = [
            "id": record.connectionId,
            "nodeId": record.nodeId,
            "publishedAtMillis": record.publishedAtMillis,
            "protocolVersion": record.protocolVersion,
            "signature": record.signature,
            "createdAt": now,
            "updatedAt": now,
            "schemaVersion": 1
        ]
        try await firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("iroh_pairing")
            .document(record.connectionId)
            .setData(payload, merge: true)
    }

    func fetch(uid: String, connectionId: String) async throws -> IrohPairingRecord? {
        let snapshot = try await firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("iroh_pairing")
            .document(connectionId)
            .getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return FirestoreIrohPairingDirectory.decode(data: data, uid: uid)
    }

    func revoke(uid: String, connectionId: String) async throws {
        try await firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("iroh_pairing")
            .document(connectionId)
            .delete()
    }

    static func decode(data: [String: Any], uid: String) -> IrohPairingRecord? {
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
