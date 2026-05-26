import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Cloud sync coordinator that orchestrates all sync domains.
///
/// ## Architecture
///
/// - **Extracted domain services** (`UsageSyncService`, `ConversationSyncService`,
///   `ChatThreadSyncService`, `SessionLogSyncService`): handle focused, single-responsibility
///   sync with clean test surfaces and clear failure boundaries.
/// - **Legacy CloudSyncService**: retained for collaboration (`syncSharedArtifacts`)
///   only — the 3-way merge, optimistic concurrency, and projection enqueue remain
///   coupled to Datastore internals until CollaborationSyncService is lifted out.
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
@MainActor
final class CloudSyncCoordinator {
    // MARK: - Dependencies

    private let context: CloudSyncContext

    /// Reference to the original CloudSyncService for collaboration sync only.
    private weak var legacyCloudSync: CloudSyncService?

    // MARK: - Domain Services

    private let usageSync: UsageSyncService
    private let conversationSync: ConversationSyncService
    private let chatThreadSync: ChatThreadSyncService
    private let sessionLogSync: SessionLogSyncService
    private let providerAccountSync: ProviderAccountSyncService
    private let quotaSnapshotSync: QuotaSnapshotSyncService
    private let textExpansionSync: TextExpansionSyncService
    private let downloadSync: DownloadSyncService

    // MARK: - Shared State

    /// Aggregated sync state across all domains.
    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastSyncError: String?
    private(set) var cloudTotalCost: Double?
    private(set) var lastCollaborationNotice: SharedArtifactCollaborationNotice?

    // MARK: - Init

    /// - Parameters:
    ///   - legacyCloudSync: The original CloudSyncService instance, used for collaboration
    ///     artifact sync. May be nil if that feature is not needed.
    init(
        dataStore: DataStore,
        accountManager: any AccountManaging,
        settingsManager: any SettingsManagerProtocol,
        legacyCloudSync: CloudSyncService? = nil
    ) {
        self.context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager
        )
        self.legacyCloudSync = legacyCloudSync
        self.usageSync = UsageSyncService(context: context)
        self.conversationSync = ConversationSyncService(context: context)
        self.chatThreadSync = ChatThreadSyncService(context: context)
        self.sessionLogSync = SessionLogSyncService(context: context)
        self.providerAccountSync = ProviderAccountSyncService(context: context)
        self.quotaSnapshotSync = QuotaSnapshotSyncService(context: context)
        self.textExpansionSync = TextExpansionSyncService(context: context)
        self.downloadSync = DownloadSyncService(context: context)
    }

    // MARK: - Public API: Upload (Local → Cloud)

    /// Upload all unsynced local usage rows to Firestore.
    /// Call after UsageAggregator.refreshAll().
    func syncUsage() async {
        await propagateUsageErrors { await usageSync.sync() }
        if usageSync.lastSyncDate != nil {
            lastSyncDate = usageSync.lastSyncDate
        }
    }

    /// Upload unsynced conversation metadata (excluding full transcripts).
    func syncConversationMetadata() async {
        await propagateConversationErrors { await conversationSync.sync() }
    }

    /// Upload chat threads and messages to Firestore for cross-device resume.
    func syncChatThreads() async {
        await propagateChatThreadErrors { await chatThreadSync.sync() }
    }

    /// Upload session-log manifests and search metadata to Firestore.
    /// Gated on `sessionLogCloudBackupEnabled`.
    func syncSessionLogs() async {
        await propagateSessionLogErrors { await sessionLogSync.sync() }
    }

    /// Upload and download encrypted Text Expansion snippets.
    func syncTextExpansionSnippets() async {
        await propagateTextExpansionErrors { await textExpansionSync.sync() }
    }

    /// Upload non-secret provider account metadata to Firestore for iOS visibility.
    func syncProviderAccounts() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        await providerAccountSync.uploadAccounts()
        isSyncing = false
    }

    /// Upload local quota snapshots to Firestore for iOS visibility.
    func syncQuotaSnapshots(_ snapshots: [ProviderQuotaSnapshot]) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        await quotaSnapshotSync.uploadSnapshots(snapshots)
        isSyncing = false
    }

    /// Synchronize shared/team artifacts between local cache and Firestore.
    /// Delegates to the legacy CloudSyncService which handles the full 3-way merge,
    /// optimistic concurrency, permission snapshots, and projection job enqueuing.
    func syncCollaborationArtifacts() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil

        await delegateCollaborationSync()

        isSyncing = false
    }

    // MARK: - Public API: Download (Cloud → Local)

    /// Download remote data from Firestore with durable watermark tracking.
    func syncRemoteReplicas() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        await downloadSync.sync()
        lastSyncDate = downloadSync.lastSyncDate
        lastSyncError = downloadSync.lastSyncError
        cloudTotalCost = downloadSync.cloudTotalCost
        isSyncing = false
    }

    /// Fetch sum of cost across all devices for this user (last 90 days).
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
    func updateLocalDeviceName(_ name: String) async {
        await downloadSync.updateLocalDeviceName(name)
    }

    // MARK: - Memory Boundary

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

    func memorySyncBoundarySnapshot() -> OpenBurnBarMemorySyncBoundarySnapshot {
        Self.currentMemorySyncBoundary(
            settingsManager: context.settingsManager,
            accountManager: context.accountManager
        )
    }

    // MARK: - Error Propagation Helpers

    private func propagateUsageErrors(_ block: () async -> Void) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        await block()
        if let err = usageSync.lastSyncError, err.isEmpty == false {
            lastSyncError = err
        }
        isSyncing = false
    }

    private func propagateConversationErrors(_ block: () async -> Void) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        await block()
        if let err = conversationSync.lastSyncError, err.isEmpty == false {
            lastSyncError = err
        }
        isSyncing = false
    }

    private func propagateTextExpansionErrors(_ block: () async -> Void) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        await block()
        if let err = textExpansionSync.lastSyncError, err.isEmpty == false {
            lastSyncError = err
        }
        if textExpansionSync.lastSyncDate != nil {
            lastSyncDate = textExpansionSync.lastSyncDate
        }
        isSyncing = false
    }

    private func propagateChatThreadErrors(_ block: () async -> Void) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        await block()
        if let err = chatThreadSync.lastSyncError, err.isEmpty == false {
            lastSyncError = err
        }
        isSyncing = false
    }

    private func propagateSessionLogErrors(_ block: () async -> Void) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        await block()
        if let err = sessionLogSync.lastSyncError, err.isEmpty == false {
            lastSyncError = err
        }
        isSyncing = false
    }

    // MARK: - Internal Delegate Methods
    //
    // These are called by CloudSyncService when it owns the coordinator and
    // needs to route extracted-domain sync calls without triggering circular delegation.
    // The coordinator holds a weak ref back to CloudSyncService for legacy operations.

    /// Delegates usage sync to the extracted UsageSyncService.
    func delegateUsageSync() async {
        await usageSync.sync()
        lastSyncDate = usageSync.lastSyncDate
        lastSyncError = usageSync.lastSyncError
    }

    /// Delegates conversation metadata sync to the extracted ConversationSyncService.
    func delegateConversationSync() async {
        await conversationSync.sync()
        lastSyncDate = conversationSync.lastSyncDate
        lastSyncError = conversationSync.lastSyncError
    }

    /// Delegates chat thread sync to the extracted ChatThreadSyncService.
    func delegateChatThreadSync() async {
        await chatThreadSync.sync()
        lastSyncDate = chatThreadSync.lastSyncDate
        lastSyncError = chatThreadSync.lastSyncError
    }

    /// Delegates session log sync to the extracted SessionLogSyncService.
    func delegateSessionLogSync() async {
        await sessionLogSync.sync()
        lastSyncDate = sessionLogSync.lastSyncDate
        lastSyncError = sessionLogSync.lastSyncError
    }

    /// Delegates collaboration sync to the legacy CloudSyncService's `syncSharedArtifacts()` method.
    /// This call is only used when the coordinator is the entry point (not via CloudSyncService).
    /// Since CloudSyncService owns this coordinator and its own methods are the public API,
    /// this delegate method is only for external coordinator usage.
    func delegateCollaborationSync() async {
        guard let legacy = legacyCloudSync else { return }
        await legacy.syncSharedArtifacts()
        lastCollaborationNotice = legacy.lastCollaborationNotice
        lastSyncDate = legacy.lastSyncDate
        lastSyncError = legacy.lastSyncError
    }

    /// Delegates download sync to DownloadSyncService.
    func delegateDownloadSync() async {
        await downloadSync.sync()
        lastSyncDate = downloadSync.lastSyncDate
        lastSyncError = downloadSync.lastSyncError
        await fetchCloudTotal()
    }
}
