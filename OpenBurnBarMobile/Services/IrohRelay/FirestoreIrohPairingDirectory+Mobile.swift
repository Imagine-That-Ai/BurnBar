import Foundation
import FirebaseCore
@preconcurrency import FirebaseFirestore
import OpenBurnBarKernel
import OpenBurnBarIrohRelay

/// Mobile (iOS / iPadOS) `IrohPairingDirectory`. Reads
/// `/users/{uid}/iroh_pairing/{connectionId}` written by the Mac. Mobile is
/// a pure reader; the `publish` / `revoke` calls throw because mobile does
/// not host an iroh endpoint in Phase 4 (mobile is the dialer). Silently
/// no-oping these would have masked a coding error if a future mobile
/// caller wired itself into the shared publisher.
///
/// Wave 3.4 iOS back: the reader guard + fetch stay here; document decoding
/// lives in `IrohPairingRecord.decodeFirestoreDocument`
/// (OpenBurnBarIrohRelay), shared with the macOS publisher back.
final class FirestoreIrohPairingDirectory: IrohPairingDirectory, Sendable {
    static let shared = FirestoreIrohPairingDirectory()

    private let firestoreProvider: @Sendable () -> Firestore
    private let firebaseConfigured: @Sendable () -> Bool

    init(
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        firebaseConfigured: @escaping @Sendable () -> Bool = { FirebaseApp.app() != nil }
    ) {
        self.firestoreProvider = firestoreProvider
        self.firebaseConfigured = firebaseConfigured
    }

    func publish(_ record: IrohPairingRecord, for uid: String) async throws {
        throw IrohPairingDirectoryError.unsupportedOnReader
    }

    func fetch(uid: String, connectionId: String) async throws -> IrohPairingRecord? {
        guard firebaseConfigured() else {
            throw FirestoreIrohPairingDirectoryError.firebaseUnavailable
        }
        let snapshot = try await firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("iroh_pairing")
            .document(connectionId)
            .getDocument(source: .server)
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return IrohPairingRecord.decodeFirestoreDocument(data, uid: uid)
    }

    func revoke(uid: String, connectionId: String) async throws {
        throw IrohPairingDirectoryError.unsupportedOnReader
    }
}

enum FirestoreIrohPairingDirectoryError: LocalizedError, Equatable {
    case firebaseUnavailable

    var errorDescription: String? {
        "Firebase is not configured on this device."
    }
}
