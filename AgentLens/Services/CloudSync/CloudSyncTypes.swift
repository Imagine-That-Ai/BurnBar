import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

// MARK: - Sync Domain Protocol

/// Protocol for all cloud sync domain services.
/// Each domain is responsible for one area of sync (usage, conversations, artifacts, etc.)
protocol CloudSyncDomain: AnyObject {
    /// Whether this domain is currently syncing.
    var isSyncing: Bool { get }

    /// Last error encountered during sync, if any.
    var lastSyncError: String? { get }

    /// Last successful sync date for this domain.
    var lastSyncDate: Date? { get }

    /// Performs the sync operation for this domain.
    func sync() async
}

@MainActor
protocol CloudSyncing: AnyObject {
    var isSyncing: Bool { get }
    var lastSyncDate: Date? { get }
    var lastSyncError: String? { get }
    var cloudTotalCost: Double? { get }
    var lastCollaborationNotice: SharedArtifactCollaborationNotice? { get }

    func uploadPending() async
    func uploadPendingConversations() async
    func uploadPendingChatThreads() async
    func uploadPendingSessionLogs() async
    func syncSharedArtifacts(maxRemoteArtifacts: Int) async
    func downloadRemoteData(uid: String?) async
    func updateLocalDeviceName(_ name: String) async
    func fetchCloudTotal(uid: String?) async
    func fetchCloudSessionLogs(limit: Int) async throws -> [ConversationRecord]
    func fetchCloudSessionLogBody(docId: String) async throws -> String
    func memorySyncBoundarySnapshot() async -> OpenBurnBarMemorySyncBoundarySnapshot
}

extension CloudSyncing {
    func syncSharedArtifacts() async {
        await syncSharedArtifacts(maxRemoteArtifacts: 200)
    }

    func downloadRemoteData() async {
        await downloadRemoteData(uid: nil)
    }

    func fetchCloudTotal() async {
        await fetchCloudTotal(uid: nil)
    }

    func fetchCloudSessionLogs() async throws -> [ConversationRecord] {
        try await fetchCloudSessionLogs(limit: 200)
    }
}

// MARK: - Shared Sync State

/// Shared per-domain sync status (`isSyncing`/`lastSyncError`/`lastSyncDate`).
///
/// Every CloudSync domain service stores one of these inside a `Locked` box so
/// the `isSyncing` reentrancy guard is an atomic check-then-act instead of an
/// unguarded triplet mutated from nonisolated async methods (finding-211/gap-2).
struct CloudSyncDomainState: Sendable {
    var isSyncing = false
    var lastSyncError: String?
    var lastSyncDate: Date?
}

extension Locked where T == CloudSyncDomainState {
    /// Atomically transitions `isSyncing` false→true and clears `lastSyncError`.
    /// Returns `false` when a sync is already in flight; the caller must bail
    /// without touching any other state (the previous guard semantics).
    func beginSyncingIfIdle() -> Bool {
        withLock { state in
            guard !state.isSyncing else { return false }
            state.isSyncing = true
            state.lastSyncError = nil
            return true
        }
    }

    /// Unconditionally marks a sync as started and clears `lastSyncError`.
    /// Used by domains whose reentrancy is already serialized elsewhere
    /// (process gates) or that historically ran without a reentrancy guard.
    func beginSyncing() {
        withLock { state in
            state.isSyncing = true
            state.lastSyncError = nil
        }
    }

    /// Marks the in-flight sync as finished. Pairs with either begin call.
    func endSyncing() {
        withLock { $0.isSyncing = false }
    }
}

/// Shared backoff policy used across all sync domains.
enum CloudSyncBackoffPolicy {
    static let permissionDeniedCooldown: TimeInterval = 10 * 60
}

/// Shared sync report accumulated during a collaboration sync cycle.
struct SharedArtifactSyncReport: Equatable, Sendable {
    var scope: SharedArtifactScope
    var localArtifactsEvaluated: Int = 0
    var remoteArtifactsEvaluated: Int = 0
    var pushed: Int = 0
    var pulled: Int = 0
    var conflicts: Int = 0
    var skipped: Int = 0
}

/// Context passed to all sync domain services for shared dependencies.
///
/// Account and settings reads cross into `MainActor` via `syncGate()`; persistence uses
/// `DataStore`'s nonisolated store accessors and `DataStoreActor` for heavy I/O.
final class CloudSyncContext: @unchecked Sendable {
    let dataStore: DataStore
    let accountManager: any AccountManaging
    let settingsManager: any SettingsManagerProtocol

    /// Shared circuit breaker for Firestore network calls.
    let circuitBreaker: CloudSyncCircuitBreaker

    /// Shared retry policy for transient Firestore failures.
    let retryPolicy = CloudSyncRetryPolicy()

    /// Injectable Firestore gateway. Defaults to live Firestore in production.
    let firestoreGateway: CloudSyncFirestoreGateway

    /// User-facing backup limits enforced before upload.
    let backupPlanLimits: CloudBackupPlanLimits

    /// Shared backoff suppression date.
    var suppressedSyncUntil: Date?

    /// Computed Firebase UID, nil if unavailable.
    @MainActor
    var currentUID: String? {
        guard accountManager.isFirebaseAvailable, accountManager.isSignedIn else { return nil }
        return accountManager.currentUID
    }

    /// Computed device ID.
    @MainActor
    var deviceId: String { accountManager.deviceId }

    /// Whether sync is suppressed due to backoff.
    @MainActor
    func syncIsSuppressed(now: Date = Date()) -> Bool {
        guard let suppressedSyncUntil else { return false }
        if suppressedSyncUntil > now {
            return true
        }
        self.suppressedSyncUntil = nil
        return false
    }

    init(
        dataStore: DataStore,
        accountManager: any AccountManaging,
        settingsManager: any SettingsManagerProtocol,
        firestoreGateway: CloudSyncFirestoreGateway = CloudSyncFirestoreLiveGateway(),
        circuitBreaker: CloudSyncCircuitBreaker = CloudSyncCircuitBreaker(),
        backupPlanLimits: CloudBackupPlanLimits = .standard
    ) {
        self.dataStore = dataStore
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.firestoreGateway = firestoreGateway
        self.circuitBreaker = circuitBreaker
        self.backupPlanLimits = backupPlanLimits
    }
}

// MARK: - Memory sync boundary (MainActor reads)

enum CloudSyncMemoryBoundary {
    @MainActor
    static func currentSnapshot(
        settingsManager: any SettingsManagerProtocol,
        accountManager: any AccountManaging
    ) -> OpenBurnBarMemorySyncBoundarySnapshot {
        OpenBurnBarMemorySyncBoundarySnapshot(
            mode: .localFirstOptionalCloud,
            canonicalAuthority: .localSQLite,
            cloudMetadataBackupEnabled: accountManager.isCloudSyncEnabled && settingsManager.conversationCloudBackupEnabled,
            cloudSessionLogBackupEnabled: accountManager.isCloudSyncEnabled && settingsManager.sessionLogCloudBackupEnabled,
            iCloudMirrorEnabled: settingsManager.iCloudSessionMirrorEnabled,
            collaborationUsesCloudHead: accountManager.isCloudSyncEnabled,
            notes: [
                "SQLite and daemon state remain canonical on-device.",
                "Firestore is an optional replication and collaboration plane, not the serving authority.",
                "iCloud mirroring copies files for convenience but does not become the canonical memory graph."
            ]
        )
    }
}

// MARK: - Identity snapshots (MainActor boundary)

/// Account fields needed by sync domains off the main actor.
struct CloudSyncAccountSnapshot: Sendable, Equatable {
    let isFirebaseAvailable: Bool
    let isSignedIn: Bool
    let isCloudSyncEnabled: Bool
    let deviceId: String
    let uid: String?
}

/// Settings flags needed by sync domains off the main actor.
struct CloudSyncSettingsSnapshot: Sendable, Equatable {
    let conversationCloudBackupEnabled: Bool
    let sessionLogCloudBackupEnabled: Bool
    let chatThreadContentCloudBackupEnabled: Bool
}

/// Combined gate evaluated once at the start of a sync operation.
struct CloudSyncGate: Sendable, Equatable {
    let account: CloudSyncAccountSnapshot
    let settings: CloudSyncSettingsSnapshot
    let syncSuppressed: Bool
}

// MARK: - Backup plan limits + usage

/// User-facing backup limits. Values are intentionally expressed as product
/// entitlements, not infrastructure costs.
struct CloudBackupPlanLimits: Equatable, Sendable {
    static let defaultIncludedTranscriptBytes: Int64 = 250 * 1024 * 1024
    static let defaultIncludedSearchIndexBytes: Int64 = 1024 * 1024 * 1024
    static let defaultMaxConversations = 50_000

    static let standard = CloudBackupPlanLimits(
        transcriptByteLimit: defaultIncludedTranscriptBytes,
        searchableIndexByteLimit: defaultIncludedSearchIndexBytes,
        conversationLimit: defaultMaxConversations
    )

    var transcriptByteLimit: Int64
    var searchableIndexByteLimit: Int64
    var conversationLimit: Int
}

/// Local, pre-upload estimate used to present backup usage and block uploads
/// before a user exceeds their included product limits.
struct CloudBackupUsageSnapshot: Equatable, Sendable {
    static let searchChunkMaxBytes = 16_000
    static let perConversationEnvelopeBytes: Int64 = 512
    static let estimatedIndexBytesPerChunk: Int64 = 24 * 1024

    var conversationCount: Int
    var pendingConversationCount: Int
    var rawTranscriptBytes: Int64
    var pendingRawTranscriptBytes: Int64
    var estimatedSearchIndexBytes: Int64
    var pendingEstimatedSearchIndexBytes: Int64
    var searchChunkCount: Int
    var pendingSearchChunkCount: Int
    var limits: CloudBackupPlanLimits

    var transcriptUsageFraction: Double {
        fraction(rawTranscriptBytes, of: limits.transcriptByteLimit)
    }

    var searchIndexUsageFraction: Double {
        fraction(estimatedSearchIndexBytes, of: limits.searchableIndexByteLimit)
    }

    var isWithinLimits: Bool {
        blockingReason == nil
    }

    var blockingReason: String? {
        if conversationCount > limits.conversationLimit {
            return "Backup limit reached: \(conversationCount) conversations of \(limits.conversationLimit) included."
        }
        if rawTranscriptBytes > limits.transcriptByteLimit {
            return "Backup storage limit reached: \(Self.formatBytes(rawTranscriptBytes)) of \(Self.formatBytes(limits.transcriptByteLimit)) included."
        }
        if estimatedSearchIndexBytes > limits.searchableIndexByteLimit {
            return "Searchable backup limit reached: \(Self.formatBytes(estimatedSearchIndexBytes)) of \(Self.formatBytes(limits.searchableIndexByteLimit)) included."
        }
        return nil
    }

    static func estimateSearchIndexBytes(rawTranscriptBytes: Int64, searchChunkCount: Int) -> Int64 {
        rawTranscriptBytes + (Int64(max(0, searchChunkCount)) * estimatedIndexBytesPerChunk)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        CloudBackupProgressSnapshot.formatBytes(bytes)
    }

    private func fraction(_ numerator: Int64, of denominator: Int64) -> Double {
        guard denominator > 0 else { return 1 }
        return min(1, max(0, Double(numerator) / Double(denominator)))
    }
}

enum CloudBackupPreflightError: LocalizedError, Sendable, Equatable {
    case planLimitExceeded(String)

    var errorDescription: String? {
        switch self {
        case .planLimitExceeded(let message):
            return message
        }
    }
}

extension CloudSyncContext {
    /// Reads account + settings on the main actor and returns an immutable gate for sync work.
    func syncGate(now: Date = Date()) async -> CloudSyncGate {
        await MainActor.run {
            CloudSyncGate(
                account: CloudSyncAccountSnapshot(
                    isFirebaseAvailable: accountManager.isFirebaseAvailable,
                    isSignedIn: accountManager.isSignedIn,
                    isCloudSyncEnabled: accountManager.isCloudSyncEnabled,
                    deviceId: accountManager.deviceId,
                    uid: currentUID
                ),
                settings: CloudSyncSettingsSnapshot(
                    conversationCloudBackupEnabled: settingsManager.conversationCloudBackupEnabled,
                    sessionLogCloudBackupEnabled: settingsManager.sessionLogCloudBackupEnabled,
                    chatThreadContentCloudBackupEnabled: settingsManager.chatThreadContentCloudBackupEnabled
                ),
                syncSuppressed: syncIsSuppressed(now: now)
            )
        }
    }

    /// Refreshes presentation-layer usage state after a download sync completes.
    func refreshPresentationLayer() async {
        let store = dataStore
        await Self.refreshDataStoreOnMainActor(store)
    }

    @MainActor
    private static func refreshDataStoreOnMainActor(_ dataStore: DataStore) async {
        await dataStore.refresh()
    }

    /// Records permission-denied backoff on the main actor.
    func suppressSync(for interval: TimeInterval, now: Date = Date()) async {
        await MainActor.run {
            suppressedSyncUntil = now.addingTimeInterval(interval)
        }
    }
}

// MARK: - Collaboration Health Details

struct CollaborationHealthDetails: Codable {
    let cloudAvailable: Bool
    let workspaceID: String?
    let teamID: String?
    let localArtifactsEvaluated: Int
    let remoteArtifactsEvaluated: Int
    let pushed: Int
    let pulled: Int
    let conflicts: Int
    let skipped: Int
}

// MARK: - Manual backup progress (real counters, not simulated)

/// Live snapshot emitted while a manual backup drains pending session logs and chat threads.
struct CloudBackupProgressSnapshot: Equatable, Sendable {
    enum Phase: String, Sendable, Equatable {
        case idle
        case preparing
        case facetBackfill
        case sessionLogs
        case chatThreads
        case complete
        case failed
    }

    var phase: Phase = .idle
    var startedAt: Date?
    var updatedAt: Date = .init()

    var pendingSessionLogs: Int = 0
    var processedSessionLogs: Int = 0
    var uploadedSessionLogs: Int = 0
    var skippedSessionLogs: Int = 0
    var facetRefreshSessionLogs: Int = 0

    var pendingChatThreads: Int = 0
    var processedChatThreads: Int = 0

    var plaintextBytes: Int64 = 0
    var encryptedBytes: Int64 = 0
    var storageUploads: Int = 0
    var firestoreWrites: Int = 0
    var searchIndexCommits: Int = 0

    var currentLabel: String?
    var currentOperation: String?
    var errorMessage: String?

    var totalWorkItems: Int { pendingSessionLogs + pendingChatThreads }

    var completedWorkItems: Int { processedSessionLogs + processedChatThreads }

    var overallFraction: Double {
        guard totalWorkItems > 0 else {
            switch phase {
            case .complete: return 1
            default: return 0
            }
        }
        return min(1, Double(completedWorkItems) / Double(totalWorkItems))
    }

    var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, updatedAt.timeIntervalSince(startedAt))
    }

    var recordsPerSecond: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(completedWorkItems) / elapsedSeconds
    }

    var uploadBytesPerSecond: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(encryptedBytes) / elapsedSeconds
    }

    var phaseTitle: String {
        switch phase {
        case .idle: return "Ready"
        case .preparing: return "Preparing backup"
        case .facetBackfill: return "Refreshing cockpit facets"
        case .sessionLogs: return "Uploading session logs"
        case .chatThreads: return "Syncing chat threads"
        case .complete: return "Backup complete"
        case .failed: return "Backup failed"
        }
    }

    var detailLine: String {
        switch phase {
        case .sessionLogs:
            if pendingSessionLogs == 0 {
                return "No pending session logs."
            }
            return "\(processedSessionLogs) of \(pendingSessionLogs) conversations processed"
        case .chatThreads:
            if pendingChatThreads == 0 {
                return "No chat threads to sync."
            }
            return "\(processedChatThreads) of \(pendingChatThreads) threads synced"
        case .complete:
            return "\(uploadedSessionLogs) uploaded · \(skippedSessionLogs + facetRefreshSessionLogs) already current"
        case .failed:
            return errorMessage ?? "Unknown error"
        default:
            if let currentOperation, !currentOperation.isEmpty {
                return currentOperation
            }
            return phaseTitle
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    static func formatRate(bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return "\(formatBytes(Int64(bytesPerSecond)))/s"
    }

    static func formatRate(recordsPerSecond: Double) -> String {
        guard recordsPerSecond > 0 else { return "—" }
        if recordsPerSecond >= 10 {
            return String(format: "%.0f rec/s", recordsPerSecond)
        }
        return String(format: "%.1f rec/s", recordsPerSecond)
    }
}

/// Thread-safe accumulator for backup progress. Sync services mutate this; UI observes copies.
final class CloudBackupProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = CloudBackupProgressSnapshot()
    private let onUpdate: (@Sendable (CloudBackupProgressSnapshot) -> Void)?

    init(onUpdate: (@Sendable (CloudBackupProgressSnapshot) -> Void)? = nil) {
        self.onUpdate = onUpdate
    }

    func currentSnapshot() -> CloudBackupProgressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func begin(pendingSessionLogs: Int, pendingChatThreads: Int) {
        publish {
            $0.phase = .preparing
            $0.startedAt = Date()
            $0.pendingSessionLogs = pendingSessionLogs
            $0.pendingChatThreads = pendingChatThreads
            $0.processedSessionLogs = 0
            $0.uploadedSessionLogs = 0
            $0.skippedSessionLogs = 0
            $0.facetRefreshSessionLogs = 0
            $0.processedChatThreads = 0
            $0.plaintextBytes = 0
            $0.encryptedBytes = 0
            $0.storageUploads = 0
            $0.firestoreWrites = 0
            $0.searchIndexCommits = 0
            $0.currentLabel = nil
            $0.currentOperation = "Scanning local database…"
            $0.errorMessage = nil
        }
    }

    func setPhase(_ phase: CloudBackupProgressSnapshot.Phase, operation: String? = nil) {
        publish {
            $0.phase = phase
            if let operation {
                $0.currentOperation = operation
            }
        }
    }

    func setCurrentRecord(label: String, operation: String) {
        publish {
            $0.currentLabel = label
            $0.currentOperation = operation
        }
    }

    func recordSessionLogOutcome(
        label: String,
        uploaded: Bool,
        facetRefreshOnly: Bool,
        plaintextBytes: Int,
        encryptedBytes: Int,
        storageUploads: Int,
        firestoreWrites: Int,
        searchIndexCommits: Int
    ) {
        publish {
            $0.processedSessionLogs += 1
            if uploaded {
                $0.uploadedSessionLogs += 1
            } else if facetRefreshOnly {
                $0.facetRefreshSessionLogs += 1
            } else {
                $0.skippedSessionLogs += 1
            }
            $0.plaintextBytes += Int64(plaintextBytes)
            $0.encryptedBytes += Int64(encryptedBytes)
            $0.storageUploads += storageUploads
            $0.firestoreWrites += firestoreWrites
            $0.searchIndexCommits += searchIndexCommits
            $0.currentLabel = label
        }
    }

    func recordChatThreadProcessed(label: String, firestoreWrites: Int = 1) {
        publish {
            $0.processedChatThreads += 1
            $0.firestoreWrites += firestoreWrites
            $0.currentLabel = label
            $0.currentOperation = "Writing chat thread metadata"
        }
    }

    func complete() {
        publish {
            $0.phase = .complete
            $0.currentOperation = nil
            $0.currentLabel = nil
        }
    }

    func fail(_ message: String) {
        publish {
            $0.phase = .failed
            $0.errorMessage = message
        }
    }

    private func publish(_ mutate: (inout CloudBackupProgressSnapshot) -> Void) {
        lock.lock()
        mutate(&snapshot)
        snapshot.updatedAt = Date()
        let copy = snapshot
        lock.unlock()
        onUpdate?(copy)
    }
}
