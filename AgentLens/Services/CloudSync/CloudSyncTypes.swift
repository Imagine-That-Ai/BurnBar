import FirebaseAuth
import FirebaseFirestore
import Foundation

// MARK: - Sync Domain Protocol

/// Protocol for all cloud sync domain services.
/// Each domain is responsible for one area of sync (usage, conversations, artifacts, etc.)
@MainActor
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
    func memorySyncBoundarySnapshot() -> OpenBurnBarMemorySyncBoundarySnapshot
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
@MainActor
final class CloudSyncContext {
    let dataStore: DataStore
    let accountManager: AccountManager
    let settingsManager: SettingsManager

    /// Shared circuit breaker for Firestore network calls.
    let circuitBreaker = CloudSyncCircuitBreaker()

    /// Shared retry policy for transient Firestore failures.
    let retryPolicy = CloudSyncRetryPolicy()

    /// Firestore instance, guarded by Firebase availability checks.
    var db: Firestore { Firestore.firestore() }

    /// Shared backoff suppression date.
    var suppressedSyncUntil: Date?

    /// Computed Firebase UID, nil if unavailable.
    var currentUID: String? {
        guard accountManager.isFirebaseAvailable, accountManager.isSignedIn else { return nil }
        return Auth.auth().currentUser?.uid
    }

    /// Computed device ID.
    var deviceId: String { accountManager.deviceId }

    /// Whether sync is suppressed due to backoff.
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
        accountManager: AccountManager,
        settingsManager: SettingsManager
    ) {
        self.dataStore = dataStore
        self.accountManager = accountManager
        self.settingsManager = settingsManager
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
