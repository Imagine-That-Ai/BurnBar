import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// Mobile (iOS / iPadOS) `IrohPairingDirectory`. Reads
/// `/users/{uid}/iroh_pairing/{connectionId}` written by the Mac via
/// `AgentLens/.../FirestoreIrohPairingDirectory.swift`. Mobile is a pure
/// reader; the `publish` / `revoke` calls throw because mobile does not
/// host an iroh endpoint in Phase 4 (mobile is the dialer). Silently
/// no-oping these would have masked a coding error if a future mobile
/// caller wired itself into the shared publisher.
final class FirestoreIrohPairingDirectory: IrohPairingDirectory, @unchecked Sendable {
    static let shared = FirestoreIrohPairingDirectory()

    private let firestoreProvider: @Sendable () -> Firestore

    init(firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func publish(_ record: IrohPairingRecord, for uid: String) async throws {
        throw IrohPairingDirectoryError.unsupportedOnReader
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
        throw IrohPairingDirectoryError.unsupportedOnReader
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
            relayURL: data["relayURL"] as? String,
            directAddresses: data["directAddresses"] as? [String] ?? [],
            publishedAtMillis: publishedAtMillis,
            protocolVersion: protocolVersion,
            signature: signature
        )
    }
}
