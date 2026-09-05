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
    /// Raw SDK handle for APIs whose signatures require a `Firestore` value
    /// (e.g. `MacCloudVaultSignalPayloads` / `MacCloudVaultKeyAccess`). Only the
    /// live gateway owns a real handle; fakes return `nil` so tests never
    /// resolve the global singleton.
    func rawSignalPayloadFirestore() -> Firestore?
}

extension CloudSyncFirestoreGateway {
    func rawSignalPayloadFirestore() -> Firestore? { nil }
}

protocol CloudSyncCollectionGateway: AnyObject, Sendable {
    func document(_ documentPath: String) -> CloudSyncDocumentGateway
    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway
    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway
    func whereDocumentID(isGreaterThan value: String) -> CloudSyncQueryGateway
    func whereDocumentID(isLessThan value: String) -> CloudSyncQueryGateway
    func orderByDocumentID(descending: Bool) -> CloudSyncQueryGateway
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
    /// Resume strictly AFTER the document whose ordered values are `values`, in
    /// this query's own `order(by:)` sequence — Firestore's `Query.start(after:)`.
    ///
    /// The composite cursor a stable pagination needs. Ordering by a
    /// non-unique field alone (`updatedAt`, say) cannot express "the rest of
    /// this instant": a `>` filter skips the whole tie group and a `>=` filter
    /// re-reads it for ever. `order(by: field)` + `orderByDocumentID()` +
    /// `start(afterOrderedValues: [instant, docID])` says exactly where to
    /// resume.
    func start(afterOrderedValues values: [Any]) -> CloudSyncQueryGateway
    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway
    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway
    func whereDocumentID(isGreaterThan value: String) -> CloudSyncQueryGateway
    func whereDocumentID(isLessThan value: String) -> CloudSyncQueryGateway
    func orderByDocumentID(descending: Bool) -> CloudSyncQueryGateway
    func order(by field: String, descending: Bool) -> CloudSyncQueryGateway
    func limit(to limit: Int) -> CloudSyncQueryGateway
    func getDocuments() async throws -> CloudSyncQuerySnapshotGateway
    /// Server-side `SUM(field)` aggregation over the documents matching this
    /// query. Transfers one aggregate result instead of every document —
    /// the cloud-total fetch uses this so a 90-day usage window no longer
    /// downloads O(document-count) payloads per sync cycle.
    func aggregateSum(field: String) async throws -> Double
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
    /// Sanctioned resolution point for the raw Firestore handle (R-GH6 raw
    /// Firestore ratchet). Call sites that must hand the concrete SDK handle
    /// to vault/Signal helpers resolve it here instead of calling
    /// `Firestore.firestore()` directly, so handle configuration stays owned
    /// by the gateway layer.
    static var sdkHandle: Firestore { Firestore.firestore() }

    private let firestoreOverride: Firestore?

    init(firestore: Firestore? = nil) {
        self.firestoreOverride = firestore
    }

    /// Returns the live SDK handle for legacy adapters that still accept a
    /// Firestore value instead of the gateway protocol.
    static func defaultFirestore() -> Firestore {
        Firestore.firestore()
    }

    static func firestoreData(_ value: NSDictionary) -> [String: Any] {
        value as? [String: Any] ?? [:]
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

    // cov:ignore-start -- returns the live SDK handle; resolving it requires a configured FirebaseApp, which unit tests never have. The nil default is unit-tested via CloudSyncFirestoreFakeGateway.
    func rawSignalPayloadFirestore() -> Firestore? {
        firestore
    }
    // cov:ignore-end

    private var firestore: Firestore {
        firestoreOverride ?? Self.defaultFirestore()
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

    func whereDocumentID(isGreaterThan value: String) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: reference.whereField(FieldPath.documentID(), isGreaterThan: value))
    }

    func whereDocumentID(isLessThan value: String) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: reference.whereField(FieldPath.documentID(), isLessThan: value))
    }

    func orderByDocumentID(descending: Bool) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: reference.order(by: FieldPath.documentID(), descending: descending))
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

    func start(afterOrderedValues values: [Any]) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: query.start(after: values))
    }

    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: query.whereField(field, isGreaterThan: value))
    }

    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: query.whereField(field, isEqualTo: value))
    }

    func whereDocumentID(isGreaterThan value: String) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: query.whereField(FieldPath.documentID(), isGreaterThan: value))
    }

    func whereDocumentID(isLessThan value: String) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: query.whereField(FieldPath.documentID(), isLessThan: value))
    }

    func orderByDocumentID(descending: Bool) -> CloudSyncQueryGateway {
        CloudSyncQueryLiveGateway(query: query.order(by: FieldPath.documentID(), descending: descending))
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

    func aggregateSum(field: String) async throws -> Double {
        let sumField = AggregateField.sum(field)
        let snapshot = try await query.aggregate([sumField]).getAggregation(source: .server)
        return (snapshot.get(sumField) as? NSNumber)?.doubleValue ?? 0
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
