import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarKernel
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
///   relayURL: <home relay URL>,
///   directAddresses: <direct socket addresses>,
///   publishedAtMillis: <ms since epoch>,
///   protocolVersion: 1,
///   signature: <base64 Ed25519 signature>,
///   createdAt: <ISO8601>,
///   updatedAt: <ISO8601>,
///   schemaVersion: 1
/// }
/// ```
///
/// Wave 3.4 macOS back: publish/revoke stay here (server-only callables
/// via `ComputerUseSecurityCallableClient`); document decoding lives in
/// `IrohPairingRecord.decodeFirestoreDocument` (OpenBurnBarIrohRelay),
/// shared with the iOS reader back.
final class FirestoreIrohPairingDirectory: IrohPairingDirectory, Sendable {
    private let firestoreProvider: @Sendable () -> Firestore
    private let deviceIDProvider: @Sendable () async -> String

    init(
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        deviceIDProvider: @escaping @Sendable () async -> String
    ) {
        self.firestoreProvider = firestoreProvider
        self.deviceIDProvider = deviceIDProvider
    }

    func publish(_ record: IrohPairingRecord, for uid: String) async throws {
        try await ComputerUseSecurityCallableClient.publishIrohPairingRecord(
            deviceId: await deviceIDProvider(),
            record: record
        )
    }

    func fetch(uid: String, connectionId: String) async throws -> IrohPairingRecord? {
        let snapshot = try await firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("iroh_pairing")
            .document(connectionId)
            .getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return IrohPairingRecord.decodeFirestoreDocument(data, uid: uid)
    }

    func revoke(uid: String, connectionId: String) async throws {
        try await ComputerUseSecurityCallableClient.revokeIrohPairingRecord(
            deviceId: await deviceIDProvider(),
            connectionId: connectionId
        )
    }
}
