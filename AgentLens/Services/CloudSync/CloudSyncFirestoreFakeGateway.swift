import FirebaseFirestore
import Foundation

// MARK: - Fake Implementations

/// In-memory fake Firestore backend for deterministic CloudSync testing.
///
/// - Stores documents as `[path: [String: Any]]`.
/// - Supports batch writes, collection queries, ordering, limits, and simple filtering.
/// - Replaces `FieldValue.serverTimestamp()` with `Date()` at write time.
/// - Thread-safe via internal actor isolation.
@MainActor
final class CloudSyncFirestoreFakeGateway: CloudSyncFirestoreGateway {
    private let store = FakeDocumentStore()

    /// When non-nil, all subsequent write/read operations will throw this error
    /// until it is consumed or cleared.
    var nextError: Error?

    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway {
        CloudSyncCollectionFakeGateway(store: store, path: collectionPath, nextError: { [weak self] in self?.nextError })
    }

    func batch() -> CloudSyncWriteBatchGateway {
        CloudSyncWriteBatchFakeGateway(store: store, nextError: { [weak self] in self?.nextError })
    }

    /// Direct access to stored document data for test assertions.
    func documentData(at path: String) -> [String: Any]? {
        store.documentData(at: path)
    }

    /// Direct access to all documents under a collection path.
    func documents(under collectionPath: String) -> [String: [String: Any]] {
        store.documents(under: collectionPath)
    }

    /// Write a document directly (bypassing gateway) to simulate remote changes.
    func setDocumentData(_ data: [String: Any], at path: String) {
        store.setDocumentData(normalizeFieldValues(data), at: path)
    }
}

// MARK: - Fake Document Store

@MainActor
private final class FakeDocumentStore {
    private var documents: [String: [String: Any]] = [:]

    func documentData(at path: String) -> [String: Any]? {
        documents[path]
    }

    func documents(under collectionPath: String) -> [String: [String: Any]] {
        let prefix = collectionPath + "/"
        var result: [String: [String: Any]] = [:]
        for (path, data) in documents {
            if path.hasPrefix(prefix) {
                // Only direct children of this collection
                let remainder = String(path.dropFirst(prefix.count))
                if !remainder.contains("/") {
                    result[path] = data
                }
            }
        }
        return result
    }

    func setDocumentData(_ data: [String: Any], at path: String) {
        documents[path] = data
    }

    func mergeDocumentData(_ data: [String: Any], at path: String) {
        var existing = documents[path] ?? [:]
        for (key, value) in data {
            existing[key] = value
        }
        documents[path] = existing
    }
}

// MARK: - Fake Collection Gateway

@MainActor
private final class CloudSyncCollectionFakeGateway: CloudSyncCollectionGateway {
    private let store: FakeDocumentStore
    private let path: String
    private let nextError: () -> Error?

    init(store: FakeDocumentStore, path: String, nextError: @escaping () -> Error?) {
        self.store = store
        self.path = path
        self.nextError = nextError
    }

    func document(_ documentPath: String) -> CloudSyncDocumentGateway {
        CloudSyncDocumentFakeGateway(store: store, path: "\(path)/\(documentPath)", nextError: nextError)
    }

    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: path,
            predicates: [.whereFieldIsGreaterThan(field, value)],
            sort: nil,
            limit: nil,
            nextError: nextError
        )
    }

    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: path,
            predicates: [.whereFieldIsEqualTo(field, value)],
            sort: nil,
            limit: nil,
            nextError: nextError
        )
    }

    func order(by field: String, descending: Bool) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: path,
            predicates: [],
            sort: SortDescriptor(field: field, descending: descending),
            limit: nil,
            nextError: nextError
        )
    }

    func limit(to limit: Int) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: path,
            predicates: [],
            sort: nil,
            limit: limit,
            nextError: nextError
        )
    }

    func getDocuments() async throws -> CloudSyncQuerySnapshotGateway {
        if let error = nextError() { throw error }
        return CloudSyncQuerySnapshotFakeGateway(
            store: store,
            collectionPath: path,
            predicates: [],
            sort: nil,
            limit: nil
        )
    }
}

// MARK: - Fake Document Gateway

@MainActor
private final class CloudSyncDocumentFakeGateway: CloudSyncDocumentGateway {
    private let store: FakeDocumentStore
    let path: String
    private let nextError: () -> Error?

    init(store: FakeDocumentStore, path: String, nextError: @escaping () -> Error?) {
        self.store = store
        self.path = path
        self.nextError = nextError
    }

    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway {
        CloudSyncCollectionFakeGateway(store: store, path: "\(path)/\(collectionPath)", nextError: nextError)
    }

    func setData(_ data: [String: Any], merge: Bool) async throws {
        if let error = nextError() { throw error }
        let normalized = normalizeFieldValues(data)
        if merge {
            store.mergeDocumentData(normalized, at: path)
        } else {
            store.setDocumentData(normalized, at: path)
        }
    }
}

// MARK: - Fake Query Gateway

@MainActor
private final class CloudSyncQueryFakeGateway: CloudSyncQueryGateway {
    private let store: FakeDocumentStore
    private let collectionPath: String
    private var predicates: [QueryPredicate]
    private var sort: SortDescriptor?
    private var limit: Int?
    private let nextError: () -> Error?

    init(
        store: FakeDocumentStore,
        collectionPath: String,
        predicates: [QueryPredicate],
        sort: SortDescriptor?,
        limit: Int?,
        nextError: @escaping () -> Error?
    ) {
        self.store = store
        self.collectionPath = collectionPath
        self.predicates = predicates
        self.sort = sort
        self.limit = limit
        self.nextError = nextError
    }

    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway {
        var newPredicates = predicates
        newPredicates.append(.whereFieldIsGreaterThan(field, value))
        return CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: newPredicates,
            sort: sort,
            limit: limit,
            nextError: nextError
        )
    }

    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway {
        var newPredicates = predicates
        newPredicates.append(.whereFieldIsEqualTo(field, value))
        return CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: newPredicates,
            sort: sort,
            limit: limit,
            nextError: nextError
        )
    }

    func order(by field: String, descending: Bool) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: predicates,
            sort: SortDescriptor(field: field, descending: descending),
            limit: limit,
            nextError: nextError
        )
    }

    func limit(to limit: Int) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: predicates,
            sort: sort,
            limit: limit,
            nextError: nextError
        )
    }

    func getDocuments() async throws -> CloudSyncQuerySnapshotGateway {
        if let error = nextError() { throw error }
        return CloudSyncQuerySnapshotFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: predicates,
            sort: sort,
            limit: limit
        )
    }
}

// MARK: - Fake Query Snapshot

@MainActor
private final class CloudSyncQuerySnapshotFakeGateway: CloudSyncQuerySnapshotGateway {
    let documents: [CloudSyncDocumentSnapshotGateway]

    init(
        store: FakeDocumentStore,
        collectionPath: String,
        predicates: [QueryPredicate],
        sort: SortDescriptor?,
        limit: Int?
    ) {
        var docs = store.documents(under: collectionPath)
            .map { (path, data) in (path, data) }

        // Apply predicates
        for predicate in predicates {
            docs = docs.filter { (_, data) in
                predicate.matches(data: data)
            }
        }

        // Apply sort
        if let sort {
            docs.sort { lhs, rhs in
                let comparison = FakeQueryEngine.compare(lhs: lhs.1, rhs: rhs.1, field: sort.field)
                return sort.descending ? comparison > 0 : comparison < 0
            }
        }

        // Apply limit
        if let limit {
            docs = Array(docs.prefix(limit))
        }

        self.documents = docs.map { (path, data) in
            CloudSyncDocumentSnapshotFakeGateway(documentID: path.lastPathComponent, data: data)
        }
    }
}

// MARK: - Fake Document Snapshot

@MainActor
private final class CloudSyncDocumentSnapshotFakeGateway: CloudSyncDocumentSnapshotGateway {
    let documentID: String
    private let storedData: [String: Any]

    init(documentID: String, data: [String: Any]) {
        self.documentID = documentID
        self.storedData = data
    }

    func data() -> [String: Any] {
        storedData
    }
}

// MARK: - Fake Write Batch

@MainActor
private final class CloudSyncWriteBatchFakeGateway: CloudSyncWriteBatchGateway {
    private let store: FakeDocumentStore
    private let nextError: () -> Error?
    private var pending: [(path: String, data: [String: Any], merge: Bool)] = []

    init(store: FakeDocumentStore, nextError: @escaping () -> Error?) {
        self.store = store
        self.nextError = nextError
    }

    func setData(_ data: [String: Any], forDocument document: CloudSyncDocumentGateway, merge: Bool) {
        guard let fakeDoc = document as? CloudSyncDocumentFakeGateway else {
            fatalError("Mixed gateway implementations are not supported.")
        }
        pending.append((path: fakeDoc.path, data: normalizeFieldValues(data), merge: merge))
    }

    func commit() async throws {
        if let error = nextError() { throw error }
        for item in pending {
            if item.merge {
                store.mergeDocumentData(item.data, at: item.path)
            } else {
                store.setDocumentData(item.data, at: item.path)
            }
        }
        pending.removeAll()
    }
}

// MARK: - Query Engine Helpers

@MainActor
private enum QueryPredicate {
    case whereFieldIsGreaterThan(String, Any)
    case whereFieldIsEqualTo(String, Any)

    func matches(data: [String: Any]) -> Bool {
        switch self {
        case .whereFieldIsGreaterThan(let field, let value):
            guard let fieldValue = data[field] else { return false }
            return FakeQueryEngine.compare(lhs: fieldValue, rhs: value) > 0
        case .whereFieldIsEqualTo(let field, let value):
            guard let fieldValue = data[field] else { return false }
            return FakeQueryEngine.compare(lhs: fieldValue, rhs: value) == 0
        }
    }
}

@MainActor
private struct SortDescriptor {
    let field: String
    let descending: Bool
}

@MainActor
private enum FakeQueryEngine {
    static func compare(lhs: [String: Any], rhs: [String: Any], field: String) -> Int {
        guard let l = lhs[field], let r = rhs[field] else { return 0 }
        return compare(lhs: l, rhs: r)
    }

    static func compare(lhs: Any, rhs: Any) -> Int {
        if let l = lhs as? Timestamp, let r = rhs as? Timestamp {
            return l.dateValue().compare(r.dateValue()).rawValue
        }
        if let l = lhs as? Date, let r = rhs as? Date {
            return l.compare(r).rawValue
        }
        if let l = lhs as? String, let r = rhs as? String {
            return l.compare(r).rawValue
        }
        if let l = lhs as? Int, let r = rhs as? Int {
            return l < r ? -1 : (l > r ? 1 : 0)
        }
        if let l = lhs as? Double, let r = rhs as? Double {
            return l < r ? -1 : (l > r ? 1 : 0)
        }
        return 0
    }
}

// MARK: - Field Value Normalization

/// Replaces `FieldValue.serverTimestamp()` with the current date so fake queries can compare against it.
@MainActor
private func normalizeFieldValues(_ data: [String: Any]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in data {
        if value is FieldValue {
            result[key] = Date()
        } else if let dict = value as? [String: Any] {
            result[key] = normalizeFieldValues(dict)
        } else if let array = value as? [[String: Any]] {
            result[key] = array.map { normalizeFieldValues($0) }
        } else {
            result[key] = value
        }
    }
    return result
}

// MARK: - String Helpers

private extension String {
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}

private extension ComparisonResult {
    var rawValue: Int {
        switch self {
        case .orderedAscending: return -1
        case .orderedSame: return 0
        case .orderedDescending: return 1
        }
    }
}
