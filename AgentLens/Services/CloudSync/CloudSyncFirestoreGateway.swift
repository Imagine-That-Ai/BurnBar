import FirebaseFirestore
import Foundation

// MARK: - Firestore Gateway Protocols

/// Abstract gateway for Firestore operations used by CloudSync domain services.
/// Enables deterministic testing with an in-memory fake backend.
@MainActor
protocol CloudSyncFirestoreGateway: AnyObject {
    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway
    func batch() -> CloudSyncWriteBatchGateway
}

@MainActor
protocol CloudSyncCollectionGateway: AnyObject {
    func document(_ documentPath: String) -> CloudSyncDocumentGateway
    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway
    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway
    func order(by field: String, descending: Bool) -> CloudSyncQueryGateway
    func limit(to limit: Int) -> CloudSyncQueryGateway
    func getDocuments() async throws -> CloudSyncQuerySnapshotGateway
}

@MainActor
protocol CloudSyncDocumentGateway: AnyObject {
    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway
    func setData(_ data: [String: Any], merge: Bool) async throws
}

@MainActor
protocol CloudSyncQueryGateway: AnyObject {
    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway
    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway
    func order(by field: String, descending: Bool) -> CloudSyncQueryGateway
    func limit(to limit: Int) -> CloudSyncQueryGateway
    func getDocuments() async throws -> CloudSyncQuerySnapshotGateway
}

@MainActor
protocol CloudSyncWriteBatchGateway: AnyObject {
    func setData(_ data: [String: Any], forDocument document: CloudSyncDocumentGateway, merge: Bool)
    func commit() async throws
}

@MainActor
protocol CloudSyncQuerySnapshotGateway: AnyObject {
    var documents: [CloudSyncDocumentSnapshotGateway] { get }
}

@MainActor
protocol CloudSyncDocumentSnapshotGateway: AnyObject {
    var documentID: String { get }
    func data() -> [String: Any]
}

// MARK: - Live Implementations

/// Thin wrapper around real Firebase Firestore SDK.
@MainActor
final class CloudSyncFirestoreLiveGateway: CloudSyncFirestoreGateway {
    private let firestore: Firestore

    init(firestore: Firestore = Firestore.firestore()) {
        self.firestore = firestore
    }

    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway {
        CloudSyncCollectionLiveGateway(reference: firestore.collection(collectionPath))
    }

    func batch() -> CloudSyncWriteBatchGateway {
        CloudSyncWriteBatchLiveGateway(batch: firestore.batch())
    }
}

@MainActor
final class CloudSyncCollectionLiveGateway: CloudSyncCollectionGateway {
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

@MainActor
final class CloudSyncDocumentLiveGateway: CloudSyncDocumentGateway {
    private let reference: DocumentReference

    init(reference: DocumentReference) {
        self.reference = reference
    }

    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway {
        CloudSyncCollectionLiveGateway(reference: reference.collection(collectionPath))
    }

    func setData(_ data: [String: Any], merge: Bool) async throws {
        try await reference.setData(data, merge: merge)
    }
}

@MainActor
final class CloudSyncQueryLiveGateway: CloudSyncQueryGateway {
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

@MainActor
final class CloudSyncWriteBatchLiveGateway: CloudSyncWriteBatchGateway {
    private let batch: WriteBatch

    init(batch: WriteBatch) {
        self.batch = batch
    }

    func setData(_ data: [String: Any], forDocument document: CloudSyncDocumentGateway, merge: Bool) {
        guard let liveDoc = document as? CloudSyncDocumentLiveGateway else {
            fatalError("Mixed gateway implementations are not supported.")
        }
        batch.setData(data, forDocument: liveDoc.reference, merge: merge)
    }

    func commit() async throws {
        try await batch.commit()
    }
}

@MainActor
final class CloudSyncQuerySnapshotLiveGateway: CloudSyncQuerySnapshotGateway {
    private let snapshot: QuerySnapshot

    init(snapshot: QuerySnapshot) {
        self.snapshot = snapshot
    }

    var documents: [CloudSyncDocumentSnapshotGateway] {
        snapshot.documents.map { CloudSyncDocumentSnapshotLiveGateway(document: $0) }
    }
}

@MainActor
final class CloudSyncDocumentSnapshotLiveGateway: CloudSyncDocumentSnapshotGateway {
    private let document: DocumentSnapshot

    init(document: DocumentSnapshot) {
        self.document = document
    }

    var documentID: String { document.documentID }

    func data() -> [String: Any] {
        document.data() ?? [:]
    }
}
