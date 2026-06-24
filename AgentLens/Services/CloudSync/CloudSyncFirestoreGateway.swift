import FirebaseFirestore
import Foundation

// MARK: - Firestore Gateway Protocols

/// Abstract gateway for Firestore operations used by CloudSync domain services.
/// Enables deterministic testing with an in-memory fake backend.
protocol CloudSyncFirestoreGateway: AnyObject, Sendable {
    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway
    func batch() -> CloudSyncWriteBatchGateway
    func runTransaction(
        _ updateBlock: @escaping (CloudSyncTransactionGateway) throws -> Bool
    ) async throws -> Bool
}

protocol CloudSyncCollectionGateway: AnyObject, Sendable {
    func document(_ documentPath: String) -> CloudSyncDocumentGateway
    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway
    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway
    func order(by field: String, descending: Bool) -> CloudSyncQueryGateway
    func limit(to limit: Int) -> CloudSyncQueryGateway
    func getDocuments() async throws -> CloudSyncQuerySnapshotGateway
}

protocol CloudSyncDocumentGateway: AnyObject, Sendable {
    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway
    func getData() async throws -> [String: Any]?
    func setData(_ data: [String: Any], merge: Bool) async throws
    /// Hard-deletes the document. Used by tombstone GC to remove a conversation's
    /// session-log manifest, search-index chunks, and metadata after retention.
    func deleteDocument() async throws
}

protocol CloudSyncQueryGateway: AnyObject, Sendable {
    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway
    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway
    func order(by field: String, descending: Bool) -> CloudSyncQueryGateway
    func limit(to limit: Int) -> CloudSyncQueryGateway
    func getDocuments() async throws -> CloudSyncQuerySnapshotGateway
}

protocol CloudSyncWriteBatchGateway: AnyObject, Sendable {
    func setData(_ data: [String: Any], forDocument document: CloudSyncDocumentGateway, merge: Bool)
    func deleteDocument(_ document: CloudSyncDocumentGateway)
    func commit() async throws
}

protocol CloudSyncTransactionGateway: AnyObject {
    func getData(forDocument document: CloudSyncDocumentGateway) throws -> [String: Any]?
    func setData(_ data: [String: Any], forDocument document: CloudSyncDocumentGateway, merge: Bool) throws
}

protocol CloudSyncQuerySnapshotGateway: AnyObject, Sendable {
    var documents: [CloudSyncDocumentSnapshotGateway] { get }
}

protocol CloudSyncDocumentSnapshotGateway: AnyObject, Sendable {
    var documentID: String { get }
    func data() -> [String: Any]
}

// MARK: - Live Implementations

// AUDIT(@unchecked Sendable): wraps a non-Sendable Firebase `Firestore` handle
// (override for tests); the SDK is internally thread-safe. sendable-allowlist: firebase-sdk-handle
/// Thin wrapper around real Firebase Firestore SDK.
final class CloudSyncFirestoreLiveGateway: CloudSyncFirestoreGateway, @unchecked Sendable {
    private let firestoreOverride: Firestore?

    init(firestore: Firestore? = nil) {
        self.firestoreOverride = firestore
    }

    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway {
        CloudSyncCollectionLiveGateway(reference: firestore.collection(collectionPath))
    }

    func batch() -> CloudSyncWriteBatchGateway {
        CloudSyncWriteBatchLiveGateway(batch: firestore.batch())
    }

    func runTransaction(
        _ updateBlock: @escaping (CloudSyncTransactionGateway) throws -> Bool
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            firestore.runTransaction({ transaction, errorPointer in
                do {
                    return try updateBlock(CloudSyncTransactionLiveGateway(transaction: transaction)) as NSNumber
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }, completion: { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (result as? NSNumber)?.boolValue ?? false)
            })
        }
    }

    private var firestore: Firestore {
        firestoreOverride ?? Firestore.firestore()
    }
}

// AUDIT(@unchecked Sendable): wraps a non-Sendable Firebase Firestore SDK
// reference; the SDK is internally thread-safe. sendable-allowlist: firebase-sdk-handle
final class CloudSyncCollectionLiveGateway: CloudSyncCollectionGateway, @unchecked Sendable {
    private let reference: CollectionReference

    init(reference: CollectionReference) {
        self.reference = reference
    }

    func document(_ documentPath: String) -> CloudSyncDocumentGateway {
        CloudSyncDocumentLiveGateway(reference: reference.document(documentPath))
    }

    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: reference.whereField(field, isGreaterThan: value))
    }

    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: reference.whereField(field, isEqualTo: value))
    }

    func order(by field: String, descending: Bool) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: reference.order(by: field, descending: descending))
    }

    func limit(to limit: Int) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: reference.limit(to: limit))
    }

    func getDocuments() async throws -> CloudSyncQuerySnapshotGateway {
        let snapshot = try await reference.getDocuments()
        return CloudSyncQuerySnapshotLiveGateway(snapshot: snapshot)
    }
}

// AUDIT(@unchecked Sendable): wraps a non-Sendable Firebase Firestore SDK
// reference; the SDK is internally thread-safe. sendable-allowlist: firebase-sdk-handle
final class CloudSyncDocumentLiveGateway: CloudSyncDocumentGateway, @unchecked Sendable {
    let reference: DocumentReference

    init(reference: DocumentReference) {
        self.reference = reference
    }

    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway {
        CloudSyncCollectionLiveGateway(reference: reference.collection(collectionPath))
    }

    func getData() async throws -> [String: Any]? {
        try await reference.getDocument().data()
    }

    func setData(_ data: [String: Any], merge: Bool) async throws {
        try await reference.setData(data, merge: merge)
    }

    func deleteDocument() async throws {
        try await reference.delete()
    }
}

// AUDIT(@unchecked Sendable): wraps a non-Sendable Firebase Firestore SDK
// reference; the SDK is internally thread-safe. sendable-allowlist: firebase-sdk-handle
final class CloudSyncQueryLiveGateway: CloudSyncQueryGateway, @unchecked Sendable {
    private let query: Query

    init(query: Query) {
        self.query = query
    }

    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: query.whereField(field, isGreaterThan: value))
    }

    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: query.whereField(field, isEqualTo: value))
    }

    func order(by field: String, descending: Bool) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: query.order(by: field, descending: descending))
    }

    func limit(to limit: Int) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: query.limit(to: limit))
    }

    func getDocuments() async throws -> CloudSyncQuerySnapshotGateway {
        let snapshot = try await query.getDocuments()
        return CloudSyncQuerySnapshotLiveGateway(snapshot: snapshot)
    }
}

// AUDIT(@unchecked Sendable): wraps a non-Sendable Firebase Firestore SDK
// reference; the SDK is internally thread-safe. sendable-allowlist: firebase-sdk-handle
final class CloudSyncWriteBatchLiveGateway: CloudSyncWriteBatchGateway, @unchecked Sendable {
    private let batch: WriteBatch

    init(batch: WriteBatch) {
        self.batch = batch
    }

    func setData(_ data: [String: Any], forDocument document: CloudSyncDocumentGateway, merge: Bool) {
        guard let liveDoc = document as? CloudSyncDocumentLiveGateway else {
            AppLogger.sync.error(
                "cloud_sync_gateway_implementation_mismatch",
                metadata: ["expected": "CloudSyncDocumentLiveGateway"]
            )
            return
        }
        batch.setData(data, forDocument: liveDoc.reference, merge: merge)
    }

    func deleteDocument(_ document: CloudSyncDocumentGateway) {
        guard let liveDoc = document as? CloudSyncDocumentLiveGateway else {
            AppLogger.sync.error(
                "cloud_sync_gateway_implementation_mismatch",
                metadata: ["expected": "CloudSyncDocumentLiveGateway"]
            )
            return
        }
        batch.deleteDocument(liveDoc.reference)
    }

    func commit() async throws {
        try await batch.commit()
    }
}

final class CloudSyncTransactionLiveGateway: CloudSyncTransactionGateway {
    private let transaction: Transaction

    init(transaction: Transaction) {
        self.transaction = transaction
    }

    func getData(forDocument document: CloudSyncDocumentGateway) throws -> [String: Any]? {
        guard let liveDoc = document as? CloudSyncDocumentLiveGateway else {
            throw CloudSyncGatewayError.documentImplementationMismatch(expected: "CloudSyncDocumentLiveGateway")
        }
        return try transaction.getDocument(liveDoc.reference).data()
    }

    func setData(_ data: [String: Any], forDocument document: CloudSyncDocumentGateway, merge: Bool) throws {
        guard let liveDoc = document as? CloudSyncDocumentLiveGateway else {
            throw CloudSyncGatewayError.documentImplementationMismatch(expected: "CloudSyncDocumentLiveGateway")
        }
        transaction.setData(data, forDocument: liveDoc.reference, merge: merge)
    }
}

enum CloudSyncGatewayError: LocalizedError {
    case documentImplementationMismatch(expected: String)

    var errorDescription: String? {
        switch self {
        case .documentImplementationMismatch(let expected):
            "Cloud sync gateway document implementation mismatch; expected \(expected)."
        }
    }
}

final class CloudSyncQuerySnapshotLiveGateway: CloudSyncQuerySnapshotGateway, Sendable {
    private let snapshot: QuerySnapshot

    init(snapshot: QuerySnapshot) {
        self.snapshot = snapshot
    }

    var documents: [CloudSyncDocumentSnapshotGateway] {
        snapshot.documents.map { CloudSyncDocumentSnapshotLiveGateway(document: $0) }
    }
}

final class CloudSyncDocumentSnapshotLiveGateway: CloudSyncDocumentSnapshotGateway, Sendable {
    private let document: DocumentSnapshot

    init(document: DocumentSnapshot) {
        self.document = document
    }

    var documentID: String { document.documentID }

    func data() -> [String: Any] {
        document.data() ?? [:]
    }
}
