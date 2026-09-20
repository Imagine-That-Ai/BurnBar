import FirebaseFirestore
import Foundation
import os

// MARK: - Fake Implementations

/// In-memory fake Firestore backend for deterministic CloudSync testing.
///
/// - Stores documents as `[path: [String: Any]]`.
/// - Supports batch writes, collection queries, ordering, limits, and simple filtering.
/// - Replaces `FieldValue.serverTimestamp()` with `Date()` at write time and
///   applies `FieldValue.delete()` to merged writes.
/// - Thread-safe via lock-backed in-memory state.
final class CloudSyncFirestoreFakeGateway: CloudSyncFirestoreGateway, Sendable {
    private let store = FakeDocumentStore()
    private let state = CloudSyncFirestoreFakeGatewayState()

    /// When non-nil, all subsequent write/read operations will throw this error
    /// until it is consumed or cleared.
    var nextError: Error? {
        get { state.nextError }
        set { state.nextError = newValue }
    }

    var beforeNextTransaction: (@Sendable () -> Void)? {
        get { state.beforeNextTransaction }
        set { state.beforeNextTransaction = newValue }
    }

    /// One-shot hook fired immediately before the next document write lands.
    /// Lets a test interleave a second writer INSIDE a multi-write pass — see
    /// `FakeDocumentStore.beforeNextDocumentWrite`.
    var beforeNextDocumentWrite: (@Sendable () -> Void)? {
        get { store.beforeNextDocumentWrite }
        set { store.beforeNextDocumentWrite = newValue }
    }

    /// The same one-shot seam for a second writer that must be AWAITED — a whole
    /// second client pass, rather than a synchronous poke at this store. Fired
    /// from the async `setData` path, so it lands in the same window the
    /// synchronous hook does: after everything the interrupted pass decided up
    /// front, before the first document it writes.
    var beforeNextDocumentWriteAsync: (@Sendable () async -> Void)? {
        get { store.beforeNextDocumentWriteAsync }
        set { store.beforeNextDocumentWriteAsync = newValue }
    }

    /// Number of batch commits that have been executed.
    var batchCommitCount: Int { state.batchCommitCount }

    /// Number of batch commit attempts, including attempts that fail before writes apply.
    var batchCommitAttemptCount: Int { state.batchCommitAttemptCount }

    /// Number of batch commit attempts that failed via the fake gateway.
    var batchCommitFailureCount: Int { state.batchCommitFailureCount }

    /// Queue errors that should fail only batch commits. This keeps tests on the
    /// same retry-wrapped path as production `UsageSyncService` uploads without
    /// faulting unrelated heartbeat or read calls.
    func failNextBatchCommits(_ count: Int, with error: Error) {
        state.enqueueBatchCommitFailures(count: count, error: error)
    }

    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway {
        CloudSyncCollectionFakeGateway(store: store, path: collectionPath, nextError: { [weak state] in state?.nextError })
    }

    func batch() -> CloudSyncWriteBatchGateway {
        CloudSyncWriteBatchFakeGateway(
            store: store,
            nextError: { [weak state] in state?.nextError },
            nextBatchCommitError: { [weak state] in state?.consumeBatchCommitError() },
            onCommitAttempt: { [weak state] in state?.incrementBatchCommitAttemptCount() },
            onCommitFailure: { [weak state] in state?.incrementBatchCommitFailureCount() },
            onCommitSuccess: { [weak state] in state?.incrementBatchCommitCount() }
        )
    }

    func runTransaction(
        _ updateBlock: @escaping (CloudSyncTransactionGateway) throws -> Bool
    ) async throws -> Bool {
        if let error = state.nextError { throw error }
        state.consumeBeforeNextTransaction()?()
        let transaction = CloudSyncTransactionFakeGateway(store: store)
        let shouldCommit = try updateBlock(transaction)
        if shouldCommit {
            transaction.commit()
        }
        return shouldCommit
    }

    /// Direct access to stored document data for test assertions.
    func documentData(at path: String) -> [String: Any]? {
        store.documentData(at: path)
    }

    /// Direct access to all documents under a collection path. Inspection only —
    /// it does not count as a gateway read (see `queryCount(under:)`).
    func documents(under collectionPath: String) -> [String: [String: Any]] {
        store.documents(under: collectionPath)
    }

    /// How many queries actually resolved against `collectionPath` through the
    /// gateway. Lets a test assert a closed gate performed ZERO reads rather
    /// than only that it produced no visible effect.
    func queryCount(under collectionPath: String) -> Int {
        store.queriedCollectionPaths.filter { $0 == collectionPath }.count
    }

    /// Write a document directly (bypassing gateway) to simulate remote changes.
    func setDocumentData(_ data: [String: Any], at path: String) {
        store.setDocumentData(normalizeFieldValues(data), at: path)
    }

    /// When non-nil, `aggregateSum` calls throw this error while
    /// `getDocuments` keeps working — used to test the cloud-total
    /// aggregation → document-scan fallback path in isolation.
    var aggregateSumError: Error? {
        get { store.aggregateSumError }
        set { store.aggregateSumError = newValue }
    }
}

private final class CloudSyncFirestoreFakeGatewayState: Sendable {
    private struct State {
        var storedNextError: Error?
        var storedBatchCommitCount = 0
        var storedBatchCommitAttemptCount = 0
        var storedBatchCommitFailureCount = 0
        var storedBatchCommitErrors: [Error] = []
        var storedBeforeNextTransaction: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    var nextError: Error? {
        get { state.withLockUnchecked { $0.storedNextError } }
        set { state.withLockUnchecked { $0.storedNextError = newValue } }
    }

    var batchCommitCount: Int {
        state.withLockUnchecked { $0.storedBatchCommitCount }
    }

    var batchCommitAttemptCount: Int {
        state.withLockUnchecked { $0.storedBatchCommitAttemptCount }
    }

    var batchCommitFailureCount: Int {
        state.withLockUnchecked { $0.storedBatchCommitFailureCount }
    }

    var beforeNextTransaction: (@Sendable () -> Void)? {
        get { state.withLockUnchecked { $0.storedBeforeNextTransaction } }
        set { state.withLockUnchecked { $0.storedBeforeNextTransaction = newValue } }
    }

    func incrementBatchCommitCount() {
        state.withLockUnchecked { $0.storedBatchCommitCount += 1 }
    }

    func incrementBatchCommitAttemptCount() {
        state.withLockUnchecked { $0.storedBatchCommitAttemptCount += 1 }
    }

    func incrementBatchCommitFailureCount() {
        state.withLockUnchecked { $0.storedBatchCommitFailureCount += 1 }
    }

    func enqueueBatchCommitFailures(count: Int, error: Error) {
        guard count > 0 else { return }
        state.withLockUnchecked { state in
            state.storedBatchCommitErrors.append(contentsOf: Array(repeating: error, count: count))
        }
    }

    func consumeBatchCommitError() -> Error? {
        state.withLockUnchecked { state in
            guard !state.storedBatchCommitErrors.isEmpty else { return nil }
            return state.storedBatchCommitErrors.removeFirst()
        }
    }

    func consumeBeforeNextTransaction() -> (@Sendable () -> Void)? {
        state.withLockUnchecked { state in
            let hook = state.storedBeforeNextTransaction
            state.storedBeforeNextTransaction = nil
            return hook
        }
    }
}

// MARK: - Fake Document Store

private final class FakeDocumentStore: Sendable {
    private let box = OSAllocatedUnfairLock<[String: [String: Any]]>(uncheckedState: [:])
    private let aggregateSumErrorBox = OSAllocatedUnfairLock<Error?>(uncheckedState: nil)
    private let queriedCollectionPathsBox = OSAllocatedUnfairLock<[String]>(uncheckedState: [])
    private let beforeNextWriteBox = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(uncheckedState: nil)
    private let beforeNextAsyncWriteBox =
        OSAllocatedUnfairLock<(@Sendable () async -> Void)?>(uncheckedState: nil)

    /// Every collection path a query actually resolved through the gateway, in
    /// order. Recorded at snapshot construction — the single funnel every
    /// `getDocuments()` / `aggregateSum` goes through — so a test can assert a
    /// gate produced ZERO reads, not merely zero visible effects. Direct
    /// test-side inspection (`documents(under:)` on the gateway) does not record.
    var queriedCollectionPaths: [String] {
        queriedCollectionPathsBox.withLockUnchecked { $0 }
    }

    func recordQuery(at collectionPath: String) {
        queriedCollectionPathsBox.withLockUnchecked { $0.append(collectionPath) }
    }

    /// Aggregate-only failure injection (see `CloudSyncFirestoreFakeGateway.aggregateSumError`).
    var aggregateSumError: Error? {
        get { aggregateSumErrorBox.withLockUnchecked { $0 } }
        set { aggregateSumErrorBox.withLockUnchecked { $0 = newValue } }
    }

    func documentData(at path: String) -> [String: Any]? {
        box.withLockUnchecked { $0[path] }
    }

    func documents(under collectionPath: String) -> [String: [String: Any]] {
        box.withLockUnchecked { documents in
            let prefix = collectionPath + "/"
            var result: [String: [String: Any]] = [:]
            for (path, data) in documents where path.hasPrefix(prefix) {
                // Only direct children of this collection.
                let remainder = String(path.dropFirst(prefix.count))
                if !remainder.contains("/") {
                    result[path] = data
                }
            }
            return result
        }
    }

    /// Fires ONCE, immediately before the next document write lands, and then
    /// disarms itself.
    ///
    /// The seam a test needs to stage a genuinely CONCURRENT writer: a hook that
    /// runs while a multi-write pass is mid-flight, after everything it decided
    /// up front and before everything it decides at the end. The team key lane
    /// uses it to land the sync cycle's envelope pickup in the middle of a
    /// founding publication, which is the exact window the founding promotion's
    /// re-check exists to cover.
    var beforeNextDocumentWrite: (@Sendable () -> Void)? {
        get { beforeNextWriteBox.withLockUnchecked { $0 } }
        set { beforeNextWriteBox.withLockUnchecked { $0 = newValue } }
    }

    /// The awaitable sibling of ``beforeNextDocumentWrite``. See
    /// `CloudSyncFirestoreFakeGateway.beforeNextDocumentWriteAsync`.
    var beforeNextDocumentWriteAsync: (@Sendable () async -> Void)? {
        get { beforeNextAsyncWriteBox.withLockUnchecked { $0 } }
        set { beforeNextAsyncWriteBox.withLockUnchecked { $0 = newValue } }
    }

    /// Taken OUTSIDE `box` for the same reason the synchronous one is: the hook
    /// is a whole second client pass and will read and write this same store.
    func consumeBeforeNextAsyncWrite() async {
        let hook = beforeNextAsyncWriteBox.withLockUnchecked { hook -> (@Sendable () async -> Void)? in
            let taken = hook
            hook = nil
            return taken
        }
        await hook?()
    }

    /// Taken OUTSIDE `box`, so a hook is free to read or write this same store
    /// without deadlocking on a lock the write it interrupts already holds.
    private func consumeBeforeNextWrite() {
        let hook = beforeNextWriteBox.withLockUnchecked { hook -> (@Sendable () -> Void)? in
            let taken = hook
            hook = nil
            return taken
        }
        hook?()
    }

    func setDocumentData(_ data: [String: Any], at path: String) {
        consumeBeforeNextWrite()
        box.withLockUnchecked { $0[path] = data }
    }

    func mergeDocumentData(_ data: [String: Any], at path: String) {
        consumeBeforeNextWrite()
        box.withLockUnchecked { documents in
            var existing = documents[path] ?? [:]
            for (key, value) in data {
                if value is FakeFieldDelete {
                    existing.removeValue(forKey: key)
                } else {
                    existing[key] = value
                }
            }
            documents[path] = existing
        }
    }

    func applyWrites(_ writes: [(path: String, data: [String: Any], merge: Bool)]) {
        box.withLockUnchecked { documents in
            for write in writes {
                if write.merge {
                    var existing = documents[write.path] ?? [:]
                    for (key, value) in write.data {
                        if value is FakeFieldDelete {
                            existing.removeValue(forKey: key)
                        } else {
                            existing[key] = value
                        }
                    }
                    documents[write.path] = existing
                } else {
                    documents[write.path] = write.data
                }
            }
        }
    }

    func deleteDocument(at path: String) {
        box.withLockUnchecked { $0.removeValue(forKey: path); return () }
    }
}

// MARK: - Fake Collection Gateway

private final class CloudSyncCollectionFakeGateway: CloudSyncCollectionGateway, Sendable {
    private let store: FakeDocumentStore
    private let path: String
    private let nextError: @Sendable () -> Error?

    init(store: FakeDocumentStore, path: String, nextError: @escaping @Sendable () -> Error?) {
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
            sorts: [],
            startAfter: nil,
            limit: nil,
            nextError: nextError
        )
    }

    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: path,
            predicates: [.whereFieldIsEqualTo(field, value)],
            sorts: [],
            startAfter: nil,
            limit: nil,
            nextError: nextError
        )
    }

    func whereDocumentID(isGreaterThan value: String) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: path,
            predicates: [.whereDocumentIDIsGreaterThan(value)],
            sorts: [],
            startAfter: nil,
            limit: nil,
            nextError: nextError
        )
    }

    func whereDocumentID(isLessThan value: String) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: path,
            predicates: [.whereDocumentIDIsLessThan(value)],
            sorts: [],
            startAfter: nil,
            limit: nil,
            nextError: nextError
        )
    }

    func orderByDocumentID(descending: Bool) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: path,
            predicates: [],
            sorts: [SortDescriptor(field: nil, descending: descending)],
            startAfter: nil,
            limit: nil,
            nextError: nextError
        )
    }

    func order(by field: String, descending: Bool) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: path,
            predicates: [],
            sorts: [SortDescriptor(field: field, descending: descending)],
            startAfter: nil,
            limit: nil,
            nextError: nextError
        )
    }

    func limit(to limit: Int) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: path,
            predicates: [],
            sorts: [],
            startAfter: nil,
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
            sorts: [],
            startAfter: nil,
            limit: nil
        )
    }
}

// MARK: - Fake Document Gateway

private final class CloudSyncDocumentFakeGateway: CloudSyncDocumentGateway, Sendable {
    private let store: FakeDocumentStore
    let path: String
    private let nextError: @Sendable () -> Error?

    init(store: FakeDocumentStore, path: String, nextError: @escaping @Sendable () -> Error?) {
        self.store = store
        self.path = path
        self.nextError = nextError
    }

    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway {
        CloudSyncCollectionFakeGateway(store: store, path: "\(path)/\(collectionPath)", nextError: nextError)
    }

    func getData() async throws -> [String: Any]? {
        if let error = nextError() { throw error }
        return store.documentData(at: path)
    }

    func setData(_ data: [String: Any], merge: Bool) async throws {
        if let error = nextError() { throw error }
        await store.consumeBeforeNextAsyncWrite()
        let normalized = normalizeFieldValues(data)
        if merge {
            store.mergeDocumentData(normalized, at: path)
        } else {
            store.setDocumentData(normalized, at: path)
        }
    }

    func deleteDocument() async throws {
        if let error = nextError() { throw error }
        store.deleteDocument(at: path)
    }
}

// MARK: - Fake Query Gateway

// AUDIT(@unchecked Sendable): `startAfter` carries Firestore's untyped `Any`
// cursor values; the array is immutable after init and confined to the in-memory
// fake gateway. sendable-allowlist: firestore-any-test-fake
private final class CloudSyncQueryFakeGateway: CloudSyncQueryGateway, @unchecked Sendable {
    private let store: FakeDocumentStore
    private let collectionPath: String
    private let predicates: [QueryPredicate]
    /// Firestore CHAINS `order(by:)` calls; so does this. A single slot silently
    /// dropped the primary sort when a secondary one was added, which is exactly
    /// what a composite `(updatedAt, documentID)` cursor needs.
    private let sorts: [SortDescriptor]
    private let startAfter: [Any]?
    private let limit: Int?
    private let nextError: @Sendable () -> Error?

    init(
        store: FakeDocumentStore,
        collectionPath: String,
        predicates: [QueryPredicate],
        sorts: [SortDescriptor],
        startAfter: [Any]?,
        limit: Int?,
        nextError: @escaping @Sendable () -> Error?
    ) {
        self.store = store
        self.collectionPath = collectionPath
        self.predicates = predicates
        self.sorts = sorts
        self.startAfter = startAfter
        self.limit = limit
        self.nextError = nextError
    }

    func start(afterOrderedValues values: [Any]) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: predicates,
            sorts: sorts,
            startAfter: values,
            limit: limit,
            nextError: nextError
        )
    }

    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway {
        var newPredicates = predicates
        newPredicates.append(.whereFieldIsGreaterThan(field, value))
        return CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: newPredicates,
            sorts: sorts,
            startAfter: startAfter,
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
            sorts: sorts,
            startAfter: startAfter,
            limit: limit,
            nextError: nextError
        )
    }

    func whereDocumentID(isGreaterThan value: String) -> CloudSyncQueryGateway {
        var newPredicates = predicates
        newPredicates.append(.whereDocumentIDIsGreaterThan(value))
        return CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: newPredicates,
            sorts: sorts,
            startAfter: startAfter,
            limit: limit,
            nextError: nextError
        )
    }

    func whereDocumentID(isLessThan value: String) -> CloudSyncQueryGateway {
        var newPredicates = predicates
        newPredicates.append(.whereDocumentIDIsLessThan(value))
        return CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: newPredicates,
            sorts: sorts,
            startAfter: startAfter,
            limit: limit,
            nextError: nextError
        )
    }

    func orderByDocumentID(descending: Bool) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: predicates,
            sorts: sorts + [SortDescriptor(field: nil, descending: descending)],
            startAfter: startAfter,
            limit: limit,
            nextError: nextError
        )
    }

    func order(by field: String, descending: Bool) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: predicates,
            sorts: sorts + [SortDescriptor(field: field, descending: descending)],
            startAfter: startAfter,
            limit: limit,
            nextError: nextError
        )
    }

    func limit(to limit: Int) -> CloudSyncQueryGateway {
        CloudSyncQueryFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: predicates,
            sorts: sorts,
            startAfter: startAfter,
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
            sorts: sorts,
            startAfter: startAfter,
            limit: limit
        )
    }

    /// Mirrors Firestore server-side SUM semantics: numeric field values of
    /// matching documents are summed; missing/non-numeric fields contribute 0.
    func aggregateSum(field: String) async throws -> Double {
        if let error = nextError() { throw error }
        if let error = store.aggregateSumError { throw error }
        let snapshot = CloudSyncQuerySnapshotFakeGateway(
            store: store,
            collectionPath: collectionPath,
            predicates: predicates,
            sorts: sorts,
            startAfter: startAfter,
            limit: limit
        )
        return snapshot.documents.reduce(into: 0.0) { total, document in
            if let number = document.data()[field] as? NSNumber {
                total += number.doubleValue
            }
        }
    }
}

// MARK: - Fake Query Snapshot

private final class CloudSyncQuerySnapshotFakeGateway: CloudSyncQuerySnapshotGateway, Sendable {
    let documents: [CloudSyncDocumentSnapshotGateway]

    init(
        store: FakeDocumentStore,
        collectionPath: String,
        predicates: [QueryPredicate],
        sorts: [SortDescriptor],
        startAfter: [Any]?,
        limit: Int?
    ) {
        store.recordQuery(at: collectionPath)
        var docs = store.documents(under: collectionPath)
            .map { path, data in (path, data) }

        // Apply predicates
        for predicate in predicates {
            docs = docs.filter { path, data in
                predicate.matches(documentID: path.lastPathComponent, data: data)
            }
        }

        // Apply sorts, in the order they were chained (Firestore's semantics).
        if !sorts.isEmpty {
            docs.sort { lhs, rhs in
                FakeQueryEngine.compareOrdered(lhs: lhs, rhs: rhs, sorts: sorts) < 0
            }
        }

        // Apply the composite cursor: keep only what sorts strictly AFTER it.
        if let startAfter, !sorts.isEmpty {
            docs = docs.filter { path, data in
                FakeQueryEngine.compareToCursor(
                    documentID: path.lastPathComponent,
                    data: data,
                    cursor: startAfter,
                    sorts: sorts
                ) > 0
            }
        }

        // Apply limit
        if let limit {
            docs = Array(docs.prefix(limit))
        }

        self.documents = docs.map { path, data in
            CloudSyncDocumentSnapshotFakeGateway(documentID: path.lastPathComponent, data: data)
        }
    }
}

// MARK: - Fake Document Snapshot

private final class CloudSyncDocumentSnapshotFakeGateway: CloudSyncDocumentSnapshotGateway, Sendable {
    let documentID: String
    // [String: Any] is not Sendable; the immutable snapshot lives in an
    // OSAllocatedUnfairLock so the gateway is plainly Sendable.
    private let storedData: OSAllocatedUnfairLock<[String: Any]>

    init(documentID: String, data: [String: Any]) {
        self.documentID = documentID
        self.storedData = OSAllocatedUnfairLock(uncheckedState: data)
    }

    func data() -> [String: Any] {
        storedData.withLockUnchecked { $0 }
    }
}

// MARK: - Fake Write Batch

private final class CloudSyncWriteBatchFakeGateway: CloudSyncWriteBatchGateway, Sendable {
    private enum PendingOperation {
        case set(path: String, data: [String: Any], merge: Bool)
        case delete(path: String)
    }

    private let store: FakeDocumentStore
    private let nextError: @Sendable () -> Error?
    private let nextBatchCommitError: @Sendable () -> Error?
    private let onCommitAttempt: (@Sendable () -> Void)?
    private let onCommitFailure: (@Sendable () -> Void)?
    private let onCommitSuccess: (@Sendable () -> Void)?
    private let pending = OSAllocatedUnfairLock<[PendingOperation]>(uncheckedState: [])

    init(
        store: FakeDocumentStore,
        nextError: @escaping @Sendable () -> Error?,
        nextBatchCommitError: @escaping @Sendable () -> Error?,
        onCommitAttempt: (@Sendable () -> Void)? = nil,
        onCommitFailure: (@Sendable () -> Void)? = nil,
        onCommitSuccess: (@Sendable () -> Void)? = nil
    ) {
        self.store = store
        self.nextError = nextError
        self.nextBatchCommitError = nextBatchCommitError
        self.onCommitAttempt = onCommitAttempt
        self.onCommitFailure = onCommitFailure
        self.onCommitSuccess = onCommitSuccess
    }

    func setData(_ data: [String: Any], forDocument document: CloudSyncDocumentGateway, merge: Bool) {
        guard let fakeDoc = document as? CloudSyncDocumentFakeGateway else {
            AppLogger.sync.error(
                "cloud_sync_gateway_implementation_mismatch",
                metadata: ["expected": "CloudSyncDocumentFakeGateway"]
            )
            return
        }
        pending.withLockUnchecked {
            $0.append(.set(path: fakeDoc.path, data: normalizeFieldValues(data), merge: merge))
        }
    }

    func deleteDocument(_ document: CloudSyncDocumentGateway) {
        guard let fakeDoc = document as? CloudSyncDocumentFakeGateway else {
            AppLogger.sync.error(
                "cloud_sync_gateway_implementation_mismatch",
                metadata: ["expected": "CloudSyncDocumentFakeGateway"]
            )
            return
        }
        pending.withLockUnchecked {
            $0.append(.delete(path: fakeDoc.path))
        }
    }

    func commit() async throws {
        onCommitAttempt?()
        if let error = nextError() {
            onCommitFailure?()
            throw error
        }
        if let error = nextBatchCommitError() {
            onCommitFailure?()
            throw error
        }
        let operations = pending.withLockUnchecked { pending -> [PendingOperation] in
            let operations = pending
            pending.removeAll()
            return operations
        }
        for operation in operations {
            switch operation {
            case .set(let path, let data, let merge):
                if merge {
                    store.mergeDocumentData(data, at: path)
                } else {
                    store.setDocumentData(data, at: path)
                }
            case .delete(let path):
                store.deleteDocument(at: path)
            }
        }
        onCommitSuccess?()
    }
}

private final class CloudSyncTransactionFakeGateway: CloudSyncTransactionGateway {
    private typealias PendingWrite = (path: String, data: [String: Any], merge: Bool)

    private let store: FakeDocumentStore
    private let pending = OSAllocatedUnfairLock<[PendingWrite]>(uncheckedState: [])

    init(store: FakeDocumentStore) {
        self.store = store
    }

    func getData(forDocument document: CloudSyncDocumentGateway) throws -> [String: Any]? {
        guard let fakeDoc = document as? CloudSyncDocumentFakeGateway else {
            throw CloudSyncGatewayError.documentImplementationMismatch(expected: "CloudSyncDocumentFakeGateway")
        }
        return store.documentData(at: fakeDoc.path)
    }

    func setData(_ data: [String: Any], forDocument document: CloudSyncDocumentGateway, merge: Bool) throws {
        guard let fakeDoc = document as? CloudSyncDocumentFakeGateway else {
            throw CloudSyncGatewayError.documentImplementationMismatch(expected: "CloudSyncDocumentFakeGateway")
        }
        pending.withLockUnchecked {
            $0.append((path: fakeDoc.path, data: normalizeFieldValues(data), merge: merge))
        }
    }

    func commit() {
        let writes = pending.withLockUnchecked { pending -> [PendingWrite] in
            let writes = pending
            pending.removeAll()
            return writes
        }
        store.applyWrites(writes)
    }
}

// MARK: - Query Engine Helpers

// AUDIT(@unchecked Sendable): a test-only enum carrying Firestore's untyped
// `Any` comparison values; instances are immutable and confined to the in-memory
// fake gateway. sendable-allowlist: firestore-any-test-fake
private enum QueryPredicate: @unchecked Sendable {
    case whereFieldIsGreaterThan(String, Any)
    case whereFieldIsEqualTo(String, Any)
    case whereDocumentIDIsGreaterThan(String)
    case whereDocumentIDIsLessThan(String)

    func matches(documentID: String, data: [String: Any]) -> Bool {
        switch self {
        case .whereFieldIsGreaterThan(let field, let value):
            guard let fieldValue = data[field] else { return false }
            return FakeQueryEngine.compare(lhs: fieldValue, rhs: value) > 0
        case .whereFieldIsEqualTo(let field, let value):
            guard let fieldValue = data[field] else { return false }
            return FakeQueryEngine.compare(lhs: fieldValue, rhs: value) == 0
        case .whereDocumentIDIsGreaterThan(let value):
            return documentID.compare(value).rawValue > 0
        case .whereDocumentIDIsLessThan(let value):
            return documentID.compare(value).rawValue < 0
        }
    }
}

private struct SortDescriptor {
    let field: String?
    let descending: Bool
}

private enum FakeQueryEngine {
    /// Compares two documents across a CHAIN of sort descriptors, as Firestore
    /// does: the first descriptor that separates them decides.
    static func compareOrdered(
        lhs: (String, [String: Any]),
        rhs: (String, [String: Any]),
        sorts: [SortDescriptor]
    ) -> Int {
        for sort in sorts {
            let comparison: Int
            if let field = sort.field {
                comparison = compare(lhs: lhs.1, rhs: rhs.1, field: field)
            } else {
                comparison = lhs.0.lastPathComponent.compare(rhs.0.lastPathComponent).rawValue
            }
            guard comparison != 0 else { continue }
            return sort.descending ? -comparison : comparison
        }
        return 0
    }

    /// Compares one document against a `start(after:)` cursor's ordered values,
    /// position by position. A nil sort field means the document id, so the
    /// cursor value at that position is compared against the id.
    static func compareToCursor(
        documentID: String,
        data: [String: Any],
        cursor: [Any],
        sorts: [SortDescriptor]
    ) -> Int {
        for (index, sort) in sorts.enumerated() {
            guard index < cursor.count else { break }
            let documentValue: Any? = sort.field.map { data[$0] } ?? documentID
            guard let documentValue else { return -1 }
            let comparison = compare(lhs: documentValue, rhs: cursor[index])
            guard comparison != 0 else { continue }
            return sort.descending ? -comparison : comparison
        }
        return 0
    }

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

/// Replaces Firestore field transforms with deterministic fake behavior.
private func normalizeFieldValues(_ data: [String: Any]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in data {
        if let transform = fakeFieldTransform(value) {
            switch transform {
            case .delete:
                result[key] = FakeFieldDelete()
            case .serverTimestamp:
                result[key] = Date()
            }
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

private struct FakeFieldDelete {}

private enum FakeFieldTransform {
    case delete
    case serverTimestamp
}

/// Firebase's Swift `FieldValue` type intentionally hides the concrete
/// transform, so the fake inspects the debug surface and falls back to the
/// legacy timestamp behavior for unknown transforms.
private func fakeFieldTransform(_ value: Any) -> FakeFieldTransform? {
    guard value is FieldValue else { return nil }
    let description = "\(String(describing: value)) \(String(reflecting: value))".lowercased()
    if description.contains("delete") {
        return .delete
    }
    return .serverTimestamp
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
