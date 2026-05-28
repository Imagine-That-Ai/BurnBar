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
    @MainActor
    func syncUsage() async {
        await propagateUsageErrors { await usageSync.sync() }
        if usageSync.lastSyncDate != nil {
            lastSyncDate = usageSync.lastSyncDate
        }
    }

    /// Upload unsynced conversation metadata (excluding full transcripts).
    @MainActor
    func syncConversationMetadata() async {
        await propagateConversationErrors { await conversationSync.sync() }
    }

    /// Upload chat threads and messages to Firestore for cross-device resume.
    @MainActor
    func syncChatThreads() async {
        await propagateChatThreadErrors { await chatThreadSync.sync() }
    }

    /// Upload session-log manifests and search metadata to Firestore.
    /// Gated on `sessionLogCloudBackupEnabled`.
    @MainActor
    func syncSessionLogs() async {
        await propagateSessionLogErrors { await sessionLogSync.sync() }
    }

    /// Upload and download encrypted Text Expansion snippets.
    @MainActor
    func syncTextExpansionSnippets() async {
        await propagateTextExpansionErrors { await textExpansionSync.sync() }
    }

    /// Upload non-secret provider account metadata to Firestore for iOS visibility.
    @MainActor
    func syncProviderAccounts() async {
        guard !isSyncing else { return }
        isSyncing = true
        clearSyncFailureState()
        await providerAccountSync.uploadAccounts()
        isSyncing = false
    }

    /// Upload local quota snapshots to Firestore for iOS visibility.
    @MainActor
    func syncQuotaSnapshots(_ snapshots: [ProviderQuotaSnapshot]) async {
        guard !isSyncing else { return }
        isSyncing = true
        clearSyncFailureState()
        await quotaSnapshotSync.uploadSnapshots(snapshots)
        isSyncing = false
    }

    /// Synchronize shared/team artifacts between local cache and Firestore.
    @MainActor
    func syncCollaborationArtifacts() async {
        guard !isSyncing else { return }
        isSyncing = true
        clearSyncFailureState()

        await collaborationSync.sync()

        lastCollaborationNotice = collaborationSync.lastCollaborationNotice
        lastSyncDate = collaborationSync.lastSyncDate ?? lastSyncDate
        recordSyncFailure(collaborationSync.lastSyncError)
        isSyncing = false
    }

    // MARK: - Public API: Download (Cloud → Local)

    /// Download remote data from Firestore with durable watermark tracking.
    @MainActor
    func syncRemoteReplicas() async {
        guard !isSyncing else { return }
        isSyncing = true
        clearSyncFailureState()
        await downloadSync.sync()
        lastSyncDate = downloadSync.lastSyncDate
        recordSyncFailure(downloadSync.lastSyncError)
        cloudTotalCost = downloadSync.cloudTotalCost
        isSyncing = false
    }

    /// Fetch sum of cost across all devices for this user (last 90 days).
    @MainActor
    func fetchCloudTotal() async {
        await downloadSync.fetchCloudTotal()
        cloudTotalCost = downloadSync.cloudTotalCost
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
    @MainActor
    func updateLocalDeviceName(_ name: String) async {
        await downloadSync.updateLocalDeviceName(name)
    }

    // MARK: - Memory Boundary

    @MainActor
    static func currentMemorySyncBoundary(
        settingsManager: any SettingsManagerProtocol = SettingsManager.shared,
        accountManager: any AccountManaging = AccountManager.shared
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

    @MainActor
    func memorySyncBoundarySnapshot() -> OpenBurnBarMemorySyncBoundarySnapshot {
        Self.currentMemorySyncBoundary(
            settingsManager: context.settingsManager,
            accountManager: context.accountManager
        )
    }

    // MARK: - Error Propagation Helpers

    @MainActor
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

    @MainActor
    private func clearSyncFailureState() {
        lastSyncError = nil
        lastTypedSyncError = nil
    }

    @MainActor
    private func propagateUsageErrors(_ block: () async -> Void) async {
        guard !isSyncing else { return }
        isSyncing = true
        clearSyncFailureState()
        await block()
        if let err = usageSync.lastSyncError, err.isEmpty == false {
            recordSyncFailure(err)
        }
        isSyncing = false
    }

    @MainActor
    private func propagateConversationErrors(_ block: () async -> Void) async {
        guard !isSyncing else { return }
        isSyncing = true
        clearSyncFailureState()
        await block()
        if let err = conversationSync.lastSyncError, err.isEmpty == false {
            recordSyncFailure(err)
        }
        isSyncing = false
    }

    @MainActor
    private func propagateTextExpansionErrors(_ block: () async -> Void) async {
        guard !isSyncing else { return }
        isSyncing = true
        clearSyncFailureState()
        await block()
        if let err = textExpansionSync.lastSyncError, err.isEmpty == false {
            recordSyncFailure(err)
        }
        if textExpansionSync.lastSyncDate != nil {
            lastSyncDate = textExpansionSync.lastSyncDate
        }
        isSyncing = false
    }

    @MainActor
    private func propagateChatThreadErrors(_ block: () async -> Void) async {
        guard !isSyncing else { return }
        isSyncing = true
        clearSyncFailureState()
        await block()
        if let err = chatThreadSync.lastSyncError, err.isEmpty == false {
            recordSyncFailure(err)
        }
        isSyncing = false
    }

    @MainActor
    private func propagateSessionLogErrors(_ block: () async -> Void) async {
        guard !isSyncing else { return }
        isSyncing = true
        clearSyncFailureState()
        await block()
        if let err = sessionLogSync.lastSyncError, err.isEmpty == false {
            recordSyncFailure(err)
        }
        isSyncing = false
    }

    // MARK: - Internal Delegate Methods

    @MainActor
    func delegateUsageSync() async {
        await usageSync.sync()
        lastSyncDate = usageSync.lastSyncDate
        lastSyncError = usageSync.lastSyncError
    }

    @MainActor
    func delegateConversationSync() async {
        await conversationSync.sync()
        lastSyncDate = conversationSync.lastSyncDate
        lastSyncError = conversationSync.lastSyncError
    }

    @MainActor
    func delegateChatThreadSync() async {
        await chatThreadSync.sync()
        lastSyncDate = chatThreadSync.lastSyncDate
        lastSyncError = chatThreadSync.lastSyncError
    }

    @MainActor
    func delegateSessionLogSync() async {
        await sessionLogSync.sync()
        lastSyncDate = sessionLogSync.lastSyncDate
        lastSyncError = sessionLogSync.lastSyncError
    }

    func delegateCollaborationSync() async {
        await collaborationSync.sync()
        await MainActor.run {
            lastCollaborationNotice = collaborationSync.lastCollaborationNotice
            lastSyncDate = collaborationSync.lastSyncDate ?? lastSyncDate
            lastSyncError = collaborationSync.lastSyncError
        }
    }

    @MainActor
    func delegateDownloadSync() async {
        await downloadSync.sync()
        lastSyncDate = downloadSync.lastSyncDate
        lastSyncError = downloadSync.lastSyncError
        await fetchCloudTotal()
    }
}
