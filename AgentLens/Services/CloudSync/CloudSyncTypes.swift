import FirebaseAuth
import FirebaseFirestore
import Foundation

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
        circuitBreaker: CloudSyncCircuitBreaker = CloudSyncCircuitBreaker()
    ) {
        self.dataStore = dataStore
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.firestoreGateway = firestoreGateway
        self.circuitBreaker = circuitBreaker
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
