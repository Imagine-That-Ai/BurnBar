import XCTest
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

/// P-PERF-1 regression tests for the rollup-based cloud total.
///
/// The production change replaced `DownloadSyncService.fetchCloudTotal()` — which
/// scanned the entire `users/{uid}/usage` collection for 90 days and summed cost
/// client-side — with a single `document(90d).getData()` read of
/// `users/{uid}/usage_rollups/90d`, decoding the result as `UsageRollupDoc` and
/// reading `totals.costUsd`. It also removed a redundant `fetchCloudTotal()` call
/// in `CloudSyncCoordinator.delegateDownloadSync()` (the post-download path).
///
/// These tests prove:
///  1. The rollup doc is the single source of truth (one-read proof).
///  2. A missing rollup degrades to `nil` gracefully (not `0.0`, not a crash).
///  3. The rollup's `costUsd` is used verbatim without re-summing (rounding parity).
///  4. The download-sync path reads the 90d rollup exactly once — the redundant
///     post-download `fetchCloudTotal()` was removed (no double-fetch).
@MainActor
final class DownloadSyncServiceRollupTotalsTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        fakeGateway = CloudSyncFirestoreFakeGateway()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
    }

    private func makeDownloadSync() -> DownloadSyncService {
        DownloadSyncService(context: context)
    }

    // MARK: - 1. One-read proof

    func test_fetchCloudTotal_readsRollupDocNotUsageCollection() async throws {
        seedRollup(costUsd: 123.456)

        let downloadSync = makeDownloadSync()
        await downloadSync.fetchCloudTotal()

        XCTAssertEqual(
            downloadSync.cloudTotalCost,
            123.456,
            "cloudTotalCost must equal the rollup's totals.costUsd"
        )

        let usageDocs = fakeGateway.documents(under: "users/test-uid-1/usage")
        XCTAssertTrue(
            usageDocs.isEmpty,
            "The old code scanned users/{uid}/usage; the new code must not read that collection. " +
            "Found documents: \(usageDocs.keys)"
        )
    }

    // MARK: - 2. Missing rollup graceful nil

    func test_fetchCloudTotal_missingRollupReturnsNil() async throws {
        // Do NOT seed any rollup doc.
        let downloadSync = makeDownloadSync()
        await downloadSync.fetchCloudTotal()

        XCTAssertNil(
            downloadSync.cloudTotalCost,
            "A missing rollup must produce nil, not 0.0 (old code summed an empty usage scan to 0.0)"
        )
    }

    // MARK: - 3. Rounding parity

    func test_fetchCloudTotal_usesRollupCostVerbatim() async throws {
        seedRollup(costUsd: 42.123456)

        let downloadSync = makeDownloadSync()
        await downloadSync.fetchCloudTotal()

        XCTAssertEqual(
            downloadSync.cloudTotalCost,
            42.123456,
            "The rollup costUsd must be used verbatim — no re-summing, no rounding"
        )
    }

    // MARK: - 4. No double-fetch

    /// Verifies that `CloudSyncCoordinator.delegateDownloadSync()` reads the 90d
    /// rollup exactly once. The old code called `fetchCloudTotal()` again after
    /// `downloadSync.sync()` (which already calls `fetchCloudTotal()` at the end
    /// of `sync()`), producing a redundant second read. The production change
    /// removed that call; this test guards against its reintroduction.
    ///
    /// `CloudSyncService` cannot accept a fake gateway (its `makeSyncContext()`
    /// always uses the live gateway), so the equivalent coordinator path is
    /// exercised here — `delegateDownloadSync()` had the same redundant call
    /// removed and is the direct successor.
    func test_delegateDownloadSync_readsRollupExactlyOnce() async throws {
        let countingGateway = CountingFirestoreGateway(wrapping: fakeGateway)
        let coordinator = CloudSyncCoordinator(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: countingGateway,
            conversationVaultKeyProvider: TestConversationVaultKeyProvider(),
            sessionLogEncryptedCloudClient: FakeSessionLogEncryptedCloudClient(),
            sessionLogVaultKeyStore: StaticSessionLogVaultKeyStore(),
            sessionLogVaultKeyPublisher: NoopSessionLogVaultKeyPublisher()
        )

        // Seed a usage doc so the download sync has something to process, and a
        // rollup doc so fetchCloudTotal has a value to read.
        seedUsageDoc()
        seedRollup(costUsd: 77.0)

        await coordinator.delegateDownloadSync()

        XCTAssertEqual(
            coordinator.cloudTotalCost,
            77.0,
            "cloudTotalCost must equal the rollup value after download sync"
        )
        XCTAssertEqual(
            countingGateway.rollupReadCount,
            1,
            "The 90d rollup doc must be read exactly once. " +
            "Old code read it twice (once in sync, once in the redundant post-download fetchCloudTotal). " +
            "Actual reads: \(countingGateway.rollupReadCount)"
        )
    }

    // MARK: - 5. Production-shaped computedAt (ISO string) decodes

    /// P1 regression: Cloud Functions write `computedAt` as an ISO-8601 string
    /// (`now.toISOString()` in `functions/src/rollupCompute.ts`), not a Double.
    /// Before `sanitizeRollupForJSON` was added, `JSONDecoder.deferredToDate`
    /// could not decode the ISO string and the entire rollup decoded to `nil`,
    /// silently losing `cloudTotalCost`.
    func test_fetchCloudTotal_isoStringComputedAt_decodesAndExposesCostUsd() async throws {
        seedRollup(costUsd: 99.99)

        let downloadSync = makeDownloadSync()
        await downloadSync.fetchCloudTotal()

        XCTAssertEqual(
            downloadSync.cloudTotalCost,
            99.99,
            "An ISO-string computedAt (production shape) must decode and expose totals.costUsd. " +
            "Before the sanitizeRollupForJSON fix, this stayed nil."
        )
    }

    // MARK: - 6. Firestore Timestamp computedAt also decodes

    /// Firestore may deliver `computedAt` as a `Timestamp` instead of an ISO
    /// string. `sanitizeRollupForJSON` handles both forms (Timestamp → Double
    /// via `dateValue().timeIntervalSinceReferenceDate`).
    func test_fetchCloudTotal_timestampComputedAt_decodesAndExposesCostUsd() async throws {
        seedRollupWithTimestampComputedAt(costUsd: 55.5)

        let downloadSync = makeDownloadSync()
        await downloadSync.fetchCloudTotal()

        XCTAssertEqual(
            downloadSync.cloudTotalCost,
            55.5,
            "A Timestamp-typed computedAt must also decode and expose totals.costUsd."
        )
    }

    // MARK: - 7. Transient Firestore error retries through circuit breaker

    /// When `getData()` on the rollup doc throws a transient `.unavailable`
    /// error, `withCloudSyncRetry` retries through the circuit breaker. With
    /// `maxAttempts: 3` and `failureThreshold: 3`, three consecutive failures
    /// trip the breaker to `.open` and `cloudTotalCost` stays `nil`.
    func test_fetchCloudTotal_transientUnavailableError_retriesAndTripsBreaker() async throws {
        let circuitBreaker = CloudSyncCircuitBreaker(
            failureThreshold: 3,
            resetTimeout: 60,
            successThresholdToClose: 1
        )
        let fastRetryPolicy = CloudSyncRetryPolicy(
            maxAttempts: 3,
            baseDelay: 0,
            maxDelay: 0,
            jitterFactor: 0
        )
        let retryContext = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway,
            circuitBreaker: circuitBreaker,
            retryPolicy: fastRetryPolicy
        )
        seedRollup(costUsd: 42.0)

        fakeGateway.nextError = NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.unavailable.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Firestore unavailable"]
        )

        let downloadSync = DownloadSyncService(context: retryContext)
        await downloadSync.fetchCloudTotal()

        XCTAssertNil(
            downloadSync.cloudTotalCost,
            "After all retries are exhausted on a persistent .unavailable error, " +
            "cloudTotalCost must be nil (not a crash, not a stale value)."
        )

        let breakerState = await circuitBreaker.state
        guard case .open = breakerState else {
            XCTFail("Expected circuit breaker .open after 3 consecutive failures, got \(breakerState).")
            return
        }
    }

    // MARK: - 8. Transient error then recovery exposes costUsd

    /// After a transient error trips the breaker, clearing the error and
    /// advancing the breaker past `resetTimeout` allows a subsequent
    /// `fetchCloudTotal()` to succeed and expose `cloudTotalCost`. This proves
    /// the retry path does not permanently break the rollup read.
    func test_fetchCloudTotal_transientErrorThenRecovery_exposesCostUsd() async throws {
        let circuitBreaker = CloudSyncCircuitBreaker(
            failureThreshold: 3,
            resetTimeout: 60,
            successThresholdToClose: 1
        )
        let fastRetryPolicy = CloudSyncRetryPolicy(
            maxAttempts: 3,
            baseDelay: 0,
            maxDelay: 0,
            jitterFactor: 0
        )
        let retryContext = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway,
            circuitBreaker: circuitBreaker,
            retryPolicy: fastRetryPolicy
        )
        seedRollup(costUsd: 77.7)

        // Phase 1: persistent transient error trips the breaker.
        fakeGateway.nextError = NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.unavailable.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Firestore unavailable"]
        )

        let downloadSync = DownloadSyncService(context: retryContext)
        await downloadSync.fetchCloudTotal()

        XCTAssertNil(downloadSync.cloudTotalCost, "During the transient outage, cloudTotalCost must be nil.")

        // Phase 2: clear the error and advance the breaker past resetTimeout.
        fakeGateway.nextError = nil
        await circuitBreaker.advanceTime(by: 61)

        await downloadSync.fetchCloudTotal()

        let breakerState = await circuitBreaker.state
        XCTAssertEqual(breakerState, .closed, "After recovery the breaker should close.")
        XCTAssertEqual(
            downloadSync.cloudTotalCost,
            77.7,
            "After recovery, fetchCloudTotal must expose the seeded totals.costUsd."
        )
    }

    // MARK: - Helpers

    /// Seeds a rollup doc at `users/test-uid-1/usage_rollups/90d` with the given
    /// cost. Cloud Functions write `dailyPoints` as a dict (not an array) and
    /// omit `id`/`windowKey` in the payload; `DownloadSyncService.decodeUsageRollup`
    /// normalizes this shape before decoding.
    private func seedRollup(costUsd: Double) {
        let data: [String: Any] = [
            "totals": ["requests": 100, "tokens": 50000, "costUsd": costUsd] as [String: Any],
            "providerSummaries": [["provider": "cursor", "providerID": "cursor", "totalRequests": 50, "totalTokens": 25000, "totalCost": costUsd / 2] as [String: Any]],
            "modelSummaries": [["provider": "cursor", "model": "gpt-4", "requests": 50, "tokens": 25000, "cost": costUsd / 2] as [String: Any]],
            "deviceSummaries": [["deviceId": "test-device-1", "requests": 50, "tokens": 25000] as [String: Any]],
            "dailyPoints": ["2026-07-15": costUsd] as [String: Any],
            "computedAt": "2026-07-15T12:00:00.000Z",
            "schemaVersion": 1
        ]
        fakeGateway.setDocumentData(data, at: "users/test-uid-1/usage_rollups/90d")
    }

    /// Seeds a rollup doc with `computedAt` as a Firestore `Timestamp` instead
    /// of an ISO string. Firestore may deliver the field this way; the macOS
    /// `sanitizeRollupForJSON` pass converts it to a Double before decoding.
    private func seedRollupWithTimestampComputedAt(costUsd: Double) {
        let data: [String: Any] = [
            "totals": ["requests": 100, "tokens": 50000, "costUsd": costUsd] as [String: Any],
            "providerSummaries": [["provider": "cursor", "providerID": "cursor", "totalRequests": 50, "totalTokens": 25000, "totalCost": costUsd / 2] as [String: Any]],
            "modelSummaries": [["provider": "cursor", "model": "gpt-4", "requests": 50, "tokens": 25000, "cost": costUsd / 2] as [String: Any]],
            "deviceSummaries": [["deviceId": "test-device-1", "requests": 50, "tokens": 25000] as [String: Any]],
            "dailyPoints": ["2026-07-15": costUsd] as [String: Any],
            "computedAt": Timestamp(date: Date(timeIntervalSince1970: 1_753_142_400)),
            "schemaVersion": 1
        ]
        fakeGateway.setDocumentData(data, at: "users/test-uid-1/usage_rollups/90d")
    }

    /// Seeds a minimal usage doc under `users/test-uid-1/usage` so the download
    /// sync's `downloadRemoteUsage` has a document to process (ensuring the sync
    /// path runs to completion and `fetchCloudTotal` is invoked from `sync()`).
    private func seedUsageDoc() {
        let data: [String: Any] = [
            "id": "test-device-1_usage-1",
            "deviceId": "test-device-1",
            "provider": "cursor",
            "cost": 10.0,
            "startTime": Timestamp(date: Date()),
            "endTime": Timestamp(date: Date()),
            "inputTokens": 100,
            "outputTokens": 200,
            "totalTokens": 300
        ]
        fakeGateway.setDocumentData(data, at: "users/test-uid-1/usage/test-device-1_usage-1")
    }
}

// MARK: - Counting Gateway Wrapper

/// A `CloudSyncFirestoreGateway` wrapper that counts `getData()` calls on the
/// 90d rollup document path (`users/{uid}/usage_rollups/90d`). All other calls
/// are delegated transparently to the wrapped fake gateway.
///
/// The wrapper follows the full Firestore path chain
/// (`collection("users").document(uid).collection("usage_rollups").document("90d").getData()`)
/// by threading counting collection/document wrappers through every `collection()`
/// and `document()` hop, so the count is accurate no matter how deep the path.
///
/// Used by the no-double-fetch test to prove the rollup doc is read exactly once.
private final class CountingFirestoreGateway: CloudSyncFirestoreGateway, @unchecked Sendable {
    private let wrapped: CloudSyncFirestoreFakeGateway
    private let lock = NSLock()
    private var _rollupReadCount = 0

    var rollupReadCount: Int { lock.withLock { _rollupReadCount } }

    init(wrapping gateway: CloudSyncFirestoreFakeGateway) {
        self.wrapped = gateway
    }

    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway {
        CountingCollectionGateway(
            wrapped: wrapped.collection(collectionPath),
            accumulatedPath: collectionPath,
            counter: self
        )
    }

    func batch() -> CloudSyncWriteBatchGateway {
        wrapped.batch()
    }

    func runTransaction(
        _ updateBlock: @escaping (CloudSyncTransactionGateway) throws -> Bool
    ) async throws -> Bool {
        try await wrapped.runTransaction(updateBlock)
    }

    fileprivate func recordRollupRead() {
        lock.withLock { _rollupReadCount += 1 }
    }
}

/// Counting collection wrapper — threads the accumulating path and counter
/// through the chain. When `document("90d")` is requested on a path ending in
/// `usage_rollups`, returns a counting document wrapper that increments the
/// rollup-read counter on `getData()`.
private final class CountingCollectionGateway: CloudSyncCollectionGateway, @unchecked Sendable {
    private let wrapped: CloudSyncCollectionGateway
    private let accumulatedPath: String
    private let counter: CountingFirestoreGateway

    init(
        wrapped: CloudSyncCollectionGateway,
        accumulatedPath: String,
        counter: CountingFirestoreGateway
    ) {
        self.wrapped = wrapped
        self.accumulatedPath = accumulatedPath
        self.counter = counter
    }

    func document(_ documentPath: String) -> CloudSyncDocumentGateway {
        let doc = wrapped.document(documentPath)
        let newPath = accumulatedPath + "/" + documentPath
        if newPath.hasSuffix("usage_rollups/90d") {
            return CountingDocumentGateway(wrapped: doc, counter: counter)
        }
        return CountingDocumentGateway(
            wrapped: doc,
            accumulatedPath: newPath,
            counter: counter
        )
    }

    func whereField(_ field: String, isGreaterThan value: Any) -> CloudSyncQueryGateway {
        wrapped.whereField(field, isGreaterThan: value)
    }

    func whereField(_ field: String, isEqualTo value: Any) -> CloudSyncQueryGateway {
        wrapped.whereField(field, isEqualTo: value)
    }

    func whereDocumentID(isGreaterThan value: String) -> CloudSyncQueryGateway {
        wrapped.whereDocumentID(isGreaterThan: value)
    }

    func whereDocumentID(isLessThan value: String) -> CloudSyncQueryGateway {
        wrapped.whereDocumentID(isLessThan: value)
    }

    func orderByDocumentID(descending: Bool) -> CloudSyncQueryGateway {
        wrapped.orderByDocumentID(descending: descending)
    }

    func order(by field: String, descending: Bool) -> CloudSyncQueryGateway {
        wrapped.order(by: field, descending: descending)
    }

    func limit(to limit: Int) -> CloudSyncQueryGateway {
        wrapped.limit(to: limit)
    }

    func getDocuments() async throws -> CloudSyncQuerySnapshotGateway {
        try await wrapped.getDocuments()
    }
}

/// Counting document wrapper — threads the accumulating path through
/// `collection()` so the counting chain continues at every depth. When this
/// document IS the 90d rollup doc, `getData()` increments the counter.
private final class CountingDocumentGateway: CloudSyncDocumentGateway, @unchecked Sendable {
    private let wrapped: CloudSyncDocumentGateway
    private let accumulatedPath: String?
    private let counter: CountingFirestoreGateway

    /// Counting wrapper for the 90d rollup doc — increments counter on getData().
    init(wrapped: CloudSyncDocumentGateway, counter: CountingFirestoreGateway) {
        self.wrapped = wrapped
        self.accumulatedPath = nil
        self.counter = counter
    }

    /// Counting wrapper for an intermediate document — threads the path so
    /// subsequent `collection()` calls continue through counting wrappers.
    init(wrapped: CloudSyncDocumentGateway, accumulatedPath: String, counter: CountingFirestoreGateway) {
        self.wrapped = wrapped
        self.accumulatedPath = accumulatedPath
        self.counter = counter
    }

    func collection(_ collectionPath: String) -> CloudSyncCollectionGateway {
        let wrappedCollection = wrapped.collection(collectionPath)
        guard let accumulatedPath else {
            // This is the terminal 90d doc; it should not be calling collection().
            return wrappedCollection
        }
        return CountingCollectionGateway(
            wrapped: wrappedCollection,
            accumulatedPath: accumulatedPath + "/" + collectionPath,
            counter: counter
        )
    }

    func getData() async throws -> [String: Any]? {
        if accumulatedPath == nil {
            counter.recordRollupRead()
        }
        return try await wrapped.getData()
    }

    func setData(_ data: [String: Any], merge: Bool) async throws {
        try await wrapped.setData(data, merge: merge)
    }

    func deleteDocument() async throws {
        try await wrapped.deleteDocument()
    }
}
