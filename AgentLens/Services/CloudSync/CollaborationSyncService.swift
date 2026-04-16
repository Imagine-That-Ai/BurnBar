import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Sync domain for synchronizing shared/team artifacts between local cache and Firestore.
///
/// NOTE: The full collaboration sync logic is retained in CloudSyncService's
/// `syncSharedArtifacts()` method. This service is a placeholder for future
/// extraction. It currently delegates to the legacy implementation via the coordinator.
@MainActor
final class CollaborationSyncService: CloudSyncDomain {

    // MARK: - State

    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var lastSyncDate: Date?
    private(set) var lastCollaborationNotice: SharedArtifactCollaborationNotice?

    // MARK: - Dependencies

    private let context: CloudSyncContext

    // MARK: - Init

    init(context: CloudSyncContext) {
        self.context = context
    }

    // MARK: - CloudSyncDomain

    func sync() async {
        guard context.accountManager.isFirebaseAvailable,
              context.accountManager.isSignedIn,
              context.accountManager.isCloudSyncEnabled,
              !context.syncIsSuppressed() else { return }

        isSyncing = true
        lastSyncError = nil

        // Collaboration sync is complex (3-way merge, optimistic concurrency, permission snapshots).
        // The full implementation lives in CloudSyncService.syncSharedArtifacts().
        // This placeholder will be replaced when collaboration sync is fully extracted.

        isSyncing = false
    }
}
