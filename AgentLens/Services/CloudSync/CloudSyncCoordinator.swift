import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Cloud sync coordinator that orchestrates all sync domains.
///
/// ## Architecture
///
/// Domain services (`UsageSyncService`, `ConversationSyncService`, `ChatThreadSyncService`,
/// `SessionLogSyncService`, `CollaborationSyncService`, etc.) each handle a focused sync
/// surface with clean test boundaries and explicit failure propagation.
///
/// ## Public API (replaces CloudSyncService methods)
///
/// | New name | Old name |
/// |---|---|
/// | `syncUsage()` | `uploadPending()` |
/// | `syncConversationMetadata()` | `uploadPendingConversations()` |
/// | `syncChatThreads()` | `uploadPendingChatThreads()` |
/// | `syncSessionLogs()` | `uploadPendingSessionLogs()` |
/// | `syncTextExpansionSnippets()` | new encrypted text-expansion mirror |
/// | `syncCollaborationArtifacts()` | `syncSharedArtifacts()` |
/// | `syncRemoteReplicas()` | `downloadRemoteData()` |
@Observable
final class CloudSyncCoordinator {
    // MARK: - Dependencies

    private let context: CloudSyncContext

    // MARK: - Domain Services

    private let usageSync: UsageSyncService
    private let conversationSync: ConversationSyncService
    private let chatThreadSync: ChatThreadSyncService
    private let sessionLogSync: SessionLogSyncService
    private let providerAccountSync: ProviderAccountSyncService
    private let quotaSnapshotSync: QuotaSnapshotSyncService
    private let textExpansionSync: TextExpansionSyncService
    private let collaborationSync: CollaborationSyncService
    private let downloadSync: DownloadSyncService

    // MARK: - Shared State

    /// Aggregated sync state across all domains.
    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastSyncError: String?
    /// Typed counterpart to `lastSyncError` for metrics and structured logging.
    private(set) var lastTypedSyncError: OpenBurnBarError?
    private(set) var cloudTotalCost: Double?
    private(set) var lastCollaborationNotice: SharedArtifactCollaborationNotice?

    // MARK: - Init

    @MainActor
    init(
        dataStore: DataStore,
        accountManager: any AccountManaging,
        settingsManager: any SettingsManagerProtocol,
        firestoreGateway: CloudSyncFirestoreGateway = CloudSyncFirestoreLiveGateway(),
        circuitBreaker: CloudSyncCircuitBreaker = CloudSyncCircuitBreaker(),
        sessionLogEncryptedCloudClient: SessionLogEncryptedCloudClient? = nil
    ) {
        self.context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: firestoreGateway,
            circuitBreaker: circuitBreaker
        )
        self.usageSync = UsageSyncService(context: context)
        self.conversationSync = ConversationSyncService(context: context)
        self.chatThreadSync = ChatThreadSyncService(context: context)
        self.sessionLogSync = SessionLogSyncService(
            context: context,
            encryptedCloudClient: sessionLogEncryptedCloudClient ?? FirebaseSessionLogEncryptedCloudClient()
        )
        self.providerAccountSync = ProviderAccountSyncService(context: context)
        self.quotaSnapshotSync = QuotaSnapshotSyncService(context: context)
        self.textExpansionSync = TextExpansionSyncService(context: context)
        self.collaborationSync = CollaborationSyncService(context: context)
        self.downloadSync = DownloadSyncService(context: context)
    }

    // MARK: - Public API: Upload (Local → Cloud)

    /// Upload all unsynced local usage rows to Firestore.
    /// Call after UsageAggregator.refreshAll().
    func syncUsage() async {
        await propagateUsageErrors { await usageSync.sync() }
        await MainActor.run {
            if usageSync.lastSyncDate != nil {
                lastSyncDate = usageSync.lastSyncDate
            }
        }
    }

    /// Upload unsynced conversation metadata (excluding full transcripts).
    func syncConversationMetadata() async {
        await propagateConversationErrors { await conversationSync.sync() }
    }

    /// Upload chat threads and messages to Firestore for cross-device resume.
    func syncChatThreads(progress: CloudBackupProgressTracker? = nil) async {
        await propagateChatThreadErrors { await chatThreadSync.sync(progress: progress) }
    }

    /// Upload session-log manifests and search metadata to Firestore.
    /// Gated on `sessionLogCloudBackupEnabled`.
    func syncSessionLogs(drainAll: Bool = false, progress: CloudBackupProgressTracker? = nil) async {
        await propagateSessionLogErrors {
            await sessionLogSync.sync(drainAll: drainAll, progress: progress)
        }
    }

    /// Drains all pending session logs and chat threads while emitting live progress snapshots.
    @MainActor
    func performManualBackup(onProgress: @escaping (CloudBackupProgressSnapshot) -> Void) async {
        let pendingLogs = (try? context.dataStore.countUnsyncedSessionLogs()) ?? 0
        let pendingThreads = (try? context.dataStore.fetchChatThreadSummaries(limit: 500).count) ?? 0

        let tracker = CloudBackupProgressTracker { snapshot in
            Task { @MainActor in
                onProgress(snapshot)
            }
        }
        tracker.begin(pendingSessionLogs: pendingLogs, pendingChatThreads: pendingThreads)

        await syncSessionLogs(drainAll: true, progress: tracker)
        if let err = lastSyncError, err.isEmpty == false {
            tracker.fail(err)
            return
        }

        await syncChatThreads(progress: tracker)
        if let err = lastSyncError, err.isEmpty == false {
            tracker.fail(err)
            return
        }

        tracker.complete()
        lastSyncDate = Date()
    }

    /// Upload and download encrypted Text Expansion snippets.
    func syncTextExpansionSnippets() async {
        await propagateTextExpansionErrors { await textExpansionSync.sync() }
    }

    /// Upload non-secret provider account metadata to Firestore for iOS visibility.
    func syncProviderAccounts() async {
        let shouldProceed = await MainActor.run { () -> Bool in
            guard !isSyncing else { return false }
            isSyncing = true
            clearSyncFailureState()
            return true
        }
        guard shouldProceed else { return }
        await providerAccountSync.uploadAccounts()
        await MainActor.run { isSyncing = false }
    }

    /// Upload local quota snapshots to Firestore for iOS visibility.
    func syncQuotaSnapshots(_ snapshots: [ProviderQuotaSnapshot]) async {
        let shouldProceed = await MainActor.run { () -> Bool in
            guard !isSyncing else { return false }
            isSyncing = true
            clearSyncFailureState()
            return true
        }
        guard shouldProceed else { return }
        await quotaSnapshotSync.uploadSnapshots(snapshots)
        await MainActor.run { isSyncing = false }
    }

    /// Synchronize shared/team artifacts between local cache and Firestore.
    func syncCollaborationArtifacts() async {
        let shouldProceed = await MainActor.run { () -> Bool in
            guard !isSyncing else { return false }
            isSyncing = true
            clearSyncFailureState()
            return true
        }
        guard shouldProceed else { return }

        await collaborationSync.sync()

        await MainActor.run {
            lastCollaborationNotice = collaborationSync.lastCollaborationNotice
            lastSyncDate = collaborationSync.lastSyncDate ?? lastSyncDate
            recordSyncFailure(collaborationSync.lastSyncError)
            isSyncing = false
        }
    }

    // MARK: - Public API: Download (Cloud → Local)

    /// Download remote data from Firestore with durable watermark tracking.
    func syncRemoteReplicas() async {
        let shouldProceed = await MainActor.run { () -> Bool in
            guard !isSyncing else { return false }
            isSyncing = true
            clearSyncFailureState()
            return true
        }
        guard shouldProceed else { return }
        await downloadSync.sync()
        await MainActor.run {
            lastSyncDate = downloadSync.lastSyncDate
            recordSyncFailure(downloadSync.lastSyncError)
            cloudTotalCost = downloadSync.cloudTotalCost
            isSyncing = false
        }
    }

    /// Fetch sum of cost across all devices for this user (last 90 days).
    func fetchCloudTotal() async {
        await downloadSync.fetchCloudTotal()
        await MainActor.run {
            cloudTotalCost = downloadSync.cloudTotalCost
        }
    }

    // MARK: - Session Log Read

    /// Fetches session log manifests from Firestore for the signed-in user.
    func fetchCloudSessionLogs(limit: Int = 200) async throws -> [ConversationRecord] {
        try await sessionLogSync.fetchCloudSessionLogs(limit: limit)
    }

    /// Reassembles chunk sub-documents into the full Markdown body for a session log.
    func fetchCloudSessionLogBody(docId: String) async throws -> String {
        try await downloadSync.fetchCloudSessionLogBody(docId: docId)
    }

    /// Update local device name in Firestore (called from Settings).
    func updateLocalDeviceName(_ name: String) async {
        await downloadSync.updateLocalDeviceName(name)
    }

    // MARK: - Memory Boundary

    func memorySyncBoundarySnapshot() async -> OpenBurnBarMemorySyncBoundarySnapshot {
        await MainActor.run {
            CloudSyncMemoryBoundary.currentSnapshot(
                settingsManager: context.settingsManager,
                accountManager: context.accountManager
            )
        }
    }

    // MARK: - Error Propagation Helpers

    private func recordSyncFailure(_ message: String?) {
        guard let message, !message.isEmpty else {
            lastSyncError = nil
            lastTypedSyncError = nil
            return
        }
        let typed = OpenBurnBarError.inferSync(from: message)
        lastSyncError = message
        lastTypedSyncError = typed
        AppLogger.sync.error(
            "sync_failed",
            metadata: typed.logMetadata
        )
    }

    private func clearSyncFailureState() {
        lastSyncError = nil
        lastTypedSyncError = nil
    }

    private func propagateUsageErrors(_ block: () async -> Void) async {
        let shouldProceed = await MainActor.run { () -> Bool in
            guard !isSyncing else { return false }
            isSyncing = true
            clearSyncFailureState()
            return true
        }
        guard shouldProceed else { return }
        await block()
        await MainActor.run {
            if let err = usageSync.lastSyncError, err.isEmpty == false {
                recordSyncFailure(err)
            }
            isSyncing = false
        }
    }

    private func propagateConversationErrors(_ block: () async -> Void) async {
        let shouldProceed = await MainActor.run { () -> Bool in
            guard !isSyncing else { return false }
            isSyncing = true
            clearSyncFailureState()
            return true
        }
        guard shouldProceed else { return }
        await block()
        await MainActor.run {
            if let err = conversationSync.lastSyncError, err.isEmpty == false {
                recordSyncFailure(err)
            }
            isSyncing = false
        }
    }

    private func propagateTextExpansionErrors(_ block: () async -> Void) async {
        let shouldProceed = await MainActor.run { () -> Bool in
            guard !isSyncing else { return false }
            isSyncing = true
            clearSyncFailureState()
            return true
        }
        guard shouldProceed else { return }
        await block()
        await MainActor.run {
            if let err = textExpansionSync.lastSyncError, err.isEmpty == false {
                recordSyncFailure(err)
            }
            if textExpansionSync.lastSyncDate != nil {
                lastSyncDate = textExpansionSync.lastSyncDate
            }
            isSyncing = false
        }
    }

    private func propagateChatThreadErrors(_ block: () async -> Void) async {
        let shouldProceed = await MainActor.run { () -> Bool in
            guard !isSyncing else { return false }
            isSyncing = true
            clearSyncFailureState()
            return true
        }
        guard shouldProceed else { return }
        await block()
        await MainActor.run {
            if let err = chatThreadSync.lastSyncError, err.isEmpty == false {
                recordSyncFailure(err)
            }
            isSyncing = false
        }
    }

    private func propagateSessionLogErrors(_ block: () async -> Void) async {
        let shouldProceed = await MainActor.run { () -> Bool in
            guard !isSyncing else { return false }
            isSyncing = true
            clearSyncFailureState()
            return true
        }
        guard shouldProceed else { return }
        await block()
        await MainActor.run {
            if let err = sessionLogSync.lastSyncError, err.isEmpty == false {
                recordSyncFailure(err)
            }
            isSyncing = false
        }
    }

    // MARK: - Internal Delegate Methods

    func delegateUsageSync() async {
        await usageSync.sync()
        await MainActor.run {
            lastSyncDate = usageSync.lastSyncDate
            lastSyncError = usageSync.lastSyncError
        }
    }

    func delegateConversationSync() async {
        await conversationSync.sync()
        await MainActor.run {
            lastSyncDate = conversationSync.lastSyncDate
            lastSyncError = conversationSync.lastSyncError
        }
    }

    func delegateChatThreadSync() async {
        await chatThreadSync.sync()
        await MainActor.run {
            lastSyncDate = chatThreadSync.lastSyncDate
            lastSyncError = chatThreadSync.lastSyncError
        }
    }

    func delegateSessionLogSync() async {
        await sessionLogSync.sync()
        await MainActor.run {
            lastSyncDate = sessionLogSync.lastSyncDate
            lastSyncError = sessionLogSync.lastSyncError
        }
    }

    func delegateCollaborationSync() async {
        await collaborationSync.sync()
        await MainActor.run {
            lastCollaborationNotice = collaborationSync.lastCollaborationNotice
            lastSyncDate = collaborationSync.lastSyncDate ?? lastSyncDate
            lastSyncError = collaborationSync.lastSyncError
        }
    }

    func delegateDownloadSync() async {
        await downloadSync.sync()
        await MainActor.run {
            lastSyncDate = downloadSync.lastSyncDate
            lastSyncError = downloadSync.lastSyncError
        }
        await fetchCloudTotal()
    }
}
