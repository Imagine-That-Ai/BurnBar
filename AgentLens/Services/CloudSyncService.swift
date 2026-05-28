import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia

// MARK: - CloudSyncService

/// Uploads unsynced local TokenUsage rows to Firestore under the authenticated user's namespace.
///
/// Layout: `users/{uid}/usage/{deviceId}_{usageId}`
///
/// Conversation metadata (no full transcripts): `users/{uid}/conversations/{deviceId}_{conversationId}`
///
/// Idempotent: document IDs are deterministic, so re-uploading the same row is a no-op.
@Observable
@MainActor
final class CloudSyncService {
    private enum SyncBackoffPolicy {
        static let permissionDeniedCooldown: TimeInterval = 10 * 60
    }

    // MARK: - State

    var isSyncing = false
    var lastSyncDate: Date?
    var lastSyncError: String?
    private(set) var cloudTotalCost: Double?
    var lastCollaborationNotice: SharedArtifactCollaborationNotice?
    private var suppressedSyncUntil: Date?

    // MARK: - Dependencies

    let dataStore: DataStore
    let accountManager: AccountManager
    let settingsManager: SettingsManager

    /// `Firestore.firestore()` is only read from sync methods that guard `accountManager.isFirebaseAvailable` first.
    var db: Firestore { Firestore.firestore() }



    // MARK: - Init

    init(dataStore: DataStore, accountManager: AccountManager, settingsManager: SettingsManager = .shared) {
        self.dataStore = dataStore
        self.accountManager = accountManager
        self.settingsManager = settingsManager
    }

    static func currentMemorySyncBoundary(
        settingsManager: SettingsManager = .shared,
        accountManager: AccountManager = .shared
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

    func memorySyncBoundarySnapshot() -> OpenBurnBarMemorySyncBoundarySnapshot {
        Self.currentMemorySyncBoundary(
            settingsManager: settingsManager,
            accountManager: accountManager
        )
    }

    private func makeSyncContext() -> CloudSyncContext {
        let context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager
        )
        context.suppressedSyncUntil = suppressedSyncUntil
        return context
    }

    private func applyContextSuppression(from context: CloudSyncContext) {
        suppressedSyncUntil = context.suppressedSyncUntil
    }

    // MARK: - Sync

    func syncIsSuppressed(now: Date = Date()) -> Bool {
        guard let suppressedSyncUntil else { return false }
        if suppressedSyncUntil > now {
            return true
        }
        self.suppressedSyncUntil = nil
        return false
    }

    func recordSyncError(_ error: Error) {
        lastSyncError = error.localizedDescription

        let nsError = error as NSError
        guard nsError.domain == FirestoreErrorDomain,
              let code = FirestoreErrorCode.Code(rawValue: nsError.code),
              code == .permissionDenied || code == .unauthenticated else {
            return
        }

        suppressedSyncUntil = Date().addingTimeInterval(SyncBackoffPolicy.permissionDeniedCooldown)
    }

    /// Upload all unsynced local rows to Firestore. Call after refreshAll().
    func uploadPending() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        let context = makeSyncContext()
        let service = UsageSyncService(context: context)
        let start = Date()
        await service.sync()
        applyContextSuppression(from: context)
        lastSyncDate = service.lastSyncDate ?? lastSyncDate
        lastSyncError = service.lastSyncError

        if service.lastSyncError == nil {
            TelemetryService.shared.record(
                feature: .cloudSync,
                outcome: .success,
                durationMs: Int(Date().timeIntervalSince(start) * 1000)
            )
            if service.lastSyncDate != nil {
                await downloadRemoteData()
                await fetchCloudTotal()
            }
        } else {
            TelemetryService.shared.record(
                feature: .cloudSync,
                outcome: .failure,
                durationMs: Int(Date().timeIntervalSince(start) * 1000)
            )
        }
    }

    /// Uploads unsynced conversation metadata (excluding full transcripts) for cross-device recall.
    func uploadPendingConversations() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        let context = makeSyncContext()
        let service = ConversationSyncService(context: context)
        await service.sync()
        applyContextSuppression(from: context)
        lastSyncDate = service.lastSyncDate ?? lastSyncDate
        lastSyncError = service.lastSyncError
    }

    /// Uploads chat threads to Firestore for cross-device resume.
    func uploadPendingChatThreads() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        let context = makeSyncContext()
        let service = ChatThreadSyncService(context: context)
        await service.sync()
        applyContextSuppression(from: context)
        lastSyncDate = service.lastSyncDate ?? lastSyncDate
        lastSyncError = service.lastSyncError
    }

    /// Synchronizes shared/team artifacts between local cache and Firestore.
    func syncSharedArtifacts(maxRemoteArtifacts: Int = 300) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        let context = makeSyncContext()
        let service = CollaborationSyncService(context: context)
        service.maxRemoteArtifacts = maxRemoteArtifacts
        await service.sync()
        applyContextSuppression(from: context)
        lastCollaborationNotice = service.lastCollaborationNotice
        lastSyncDate = service.lastSyncDate ?? lastSyncDate
        lastSyncError = service.lastSyncError
    }

    func syncTextExpansionSnippets() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        let context = makeSyncContext()
        let service = TextExpansionSyncService(context: context)
        await service.sync()
        applyContextSuppression(from: context)
        lastSyncDate = service.lastSyncDate ?? lastSyncDate
        lastSyncError = service.lastSyncError
    }

    // MARK: - Cross-Device Download

    /// Downloads remote data from Firestore with durable watermark tracking.
    func downloadRemoteData(uid: String? = nil) async {
        guard accountManager.isFirebaseAvailable, accountManager.isSignedIn else { return }
        let context = makeSyncContext()
        let service = DownloadSyncService(context: context)
        await service.sync()
        applyContextSuppression(from: context)
        lastSyncDate = service.lastSyncDate ?? lastSyncDate
        lastSyncError = service.lastSyncError
        cloudTotalCost = service.cloudTotalCost
    }

    /// Updates the local device name in Firestore (called from Settings).
    func updateLocalDeviceName(_ name: String) async {
        let context = makeSyncContext()
        await DownloadSyncService(context: context).updateLocalDeviceName(name)
    }

    /// Fetch sum of cost across all devices for this user (last 90 days).
    func fetchCloudTotal(uid: String? = nil) async {
        guard accountManager.isFirebaseAvailable else { return }
        let context = makeSyncContext()
        let service = DownloadSyncService(context: context)
        await service.fetchCloudTotal()
        cloudTotalCost = service.cloudTotalCost
    }


}
