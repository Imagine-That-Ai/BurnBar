import Foundation
import SwiftUI

// MARK: - Database Workspace Types

enum DatabaseWorkspaceMode: String, CaseIterable, Identifiable {
    case story
    case atlas
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .story: return "Story"
        case .atlas: return "Atlas"
        case .system: return "System"
        }
    }

    var icon: String {
        switch self {
        case .story: return "book.pages"
        case .atlas: return "map"
        case .system: return "gearshape.2"
        }
    }
}

enum DatabaseWorkspaceMetric: String, Hashable, Sendable {
    case totalConversations
    case indexedDocuments
    case indexedChunks
    case sourceArtifacts
    case embeddingModels
    case embeddingVersions
    case embeddedChunks
    case sharedArtifacts
    case permissions
    case auditEvents
    case projectionJobs
    case retrievalHealth
}

struct DatabaseWorkspaceLoadIssue: Identifiable, Equatable, Sendable {
    let metric: DatabaseWorkspaceMetric
    let context: String
    let message: String

    var id: String { "\(metric.rawValue):\(context)" }
}

struct DatabaseWorkspaceProjectionCounts: Equatable, Sendable {
    var total: Int = 0
    var active: Int = 0
    var queued: Int = 0
    var failed: Int = 0
}

struct DatabaseWorkspaceSnapshot: Equatable, Sendable {
    // Corpus summary
    var totalSessions: Int = 0
    var totalConversations: Int = 0
    var totalCostAllTime: Double = 0
    var totalTokensAllTime: Int = 0
    var activeProviders: [AgentProvider] = []
    var activeModels: [String] = []
    var projectNames: [String] = []
    var oldestSession: Date?
    var newestSession: Date?

    // Search/index coverage
    var indexedDocuments: Int = 0
    var indexedChunks: Int = 0
    var sourceArtifacts: Int = 0
    var embeddingModels: Int = 0
    var embeddingVersions: Int = 0
    var embeddedChunks: Int = 0
    var indexingEnabled: Bool = false
    var embeddingModelRecords: [EmbeddingModelRecord] = []
    var embeddingVersionRecords: [EmbeddingVersionRecord] = []

    // Provider/model breakdown
    var providerSummaries: [ProviderSummary] = []
    var modelSummaries: [ModelSummary] = []

    // Shared/team
    var sharedArtifactCount: Int = 0
    var syncedArtifactCount: Int = 0
    var pendingArtifactCount: Int = 0
    var conflictedArtifactCount: Int = 0
    var failedArtifactCount: Int = 0
    var permissionCount: Int = 0
    var auditEventCount: Int = 0
    var syncStates: [SharedArtifactSyncStateRecord] = []
    var auditEvents: [SharedArtifactAuditEventRecord] = []
    var permissions: [SharedArtifactPermissionRecord] = []

    // System
    var projectionJobCounts = DatabaseWorkspaceProjectionCounts()
    var projectionJobs: [ProjectionJobRecord] = []
    var retrievalHealth: [RetrievalHealthRecord] = []
    var retrievalSystemHealth: RetrievalSystemHealthSnapshot = .empty

    // Recent sessions
    var recentSessions: [TokenUsage] = []

    // Freshness
    var lastRefresh: Date?
    var snapshotBuiltAt: Date = Date()
    var contentVersion: String = ""
    var unavailableMetrics: Set<DatabaseWorkspaceMetric> = []
    var loadIssues: [DatabaseWorkspaceLoadIssue] = []
}

struct DatabaseWorkspaceFilterState: Equatable {
    var providerFilter: AgentProvider?
    var sourceKindFilter: SearchSourceKind?
    var projectFilter: String?
    var timeWindow: TimeRange = .allTime
    var searchQuery: String = ""
}

enum DatabaseWorkspaceSelection: Equatable, Hashable {
    case session(UUID)
    case indexedDocument(String)
    case conversation(String)
    case artifact(String)
    case provider(AgentProvider)
    case model(String)
    case projectionJob(String)
    case auditEvent(String)
    case retrievalSubsystem(RetrievalSubsystem)
}

// MARK: - Snapshot Builder

final class DatabaseWorkspaceSnapshotBuilder {

@MainActor
    static func build(
        from dataStore: DataStore,
        settingsManager: SettingsManager,
        accountManager: AccountManager? = nil,
        cloudSyncService: CloudSyncService? = nil
    ) async -> DatabaseWorkspaceSnapshot {
        var snap = DatabaseWorkspaceSnapshot()

        func capture<T>(
            metric: DatabaseWorkspaceMetric,
            context: String,
            assign: (T) -> Void,
            _ work: () throws -> T
        ) {
            do {
                assign(try work())
            } catch {
                snap.unavailableMetrics.insert(metric)
                snap.loadIssues.append(
                    DatabaseWorkspaceLoadIssue(
                        metric: metric,
                        context: context,
                        message: error.localizedDescription
                    )
                )
            }
        }

        // Corpus
        let usages = dataStore.usages
        let providerSummaries = dataStore.providerSummaries
        let modelSummaries = dataStore.modelSummaries(in: nil)
        let indexingEnabled = settingsManager.conversationIndexingEnabled
        snap.totalSessions = usages.count
        snap.totalCostAllTime = usages.reduce(0) { $0 + $1.cost }
        snap.totalTokensAllTime = usages.reduce(0) { $0 + $1.totalTokens }
        snap.activeProviders = Array(Set(usages.map(\.provider))).sorted { $0.rawValue < $1.rawValue }
        snap.activeModels = Array(Set(usages.map(\.model))).sorted()
        snap.projectNames = Array(Set(usages.map(\.projectName))).sorted()
        snap.oldestSession = usages.min(by: { $0.startTime < $1.startTime })?.startTime
        snap.newestSession = usages.max(by: { $0.startTime < $1.startTime })?.startTime
        snap.recentSessions = Array(usages.sorted { $0.startTime > $1.startTime }.prefix(20))

        // Provider/model summaries
        snap.providerSummaries = providerSummaries
        snap.modelSummaries = modelSummaries

        // Indexing
        snap.indexingEnabled = indexingEnabled

        // Search/index coverage
        capture(metric: .indexedDocuments, context: "document_count", assign: { snap.indexedDocuments = $0 }) {
            try dataStore.countSearchDocuments()
        }
        capture(metric: .indexedChunks, context: "chunk_count", assign: { snap.indexedChunks = $0 }) {
            try dataStore.countSearchChunks()
        }

        // Conversations
        capture(metric: .totalConversations, context: "conversation_count", assign: { snap.totalConversations = $0 }) {
            try dataStore.countConversations()
        }

        // Source artifacts
        capture(metric: .sourceArtifacts, context: "artifact_count", assign: { snap.sourceArtifacts = $0 }) {
            try dataStore.countSourceArtifacts()
        }

        // Shared state
        capture(metric: .sharedArtifacts, context: "shared_sync_count", assign: { snap.sharedArtifactCount = $0 }) {
            try dataStore.countSharedArtifactSyncStates()
        }
        capture(metric: .sharedArtifacts, context: "shared_sync_synced", assign: { snap.syncedArtifactCount = $0 }) {
            try dataStore.countSharedArtifactSyncStates(statuses: [.synced])
        }
        capture(metric: .sharedArtifacts, context: "shared_sync_pending", assign: { snap.pendingArtifactCount = $0 }) {
            try dataStore.countSharedArtifactSyncStates(statuses: [.pendingUpload, .pendingPull])
        }
        capture(metric: .sharedArtifacts, context: "shared_sync_conflicted", assign: { snap.conflictedArtifactCount = $0 }) {
            try dataStore.countSharedArtifactSyncStates(statuses: [.conflicted])
        }
        capture(metric: .sharedArtifacts, context: "shared_sync_failed", assign: { snap.failedArtifactCount = $0 }) {
            try dataStore.countSharedArtifactSyncStates(statuses: [.failed])
        }
        capture(metric: .sharedArtifacts, context: "shared_sync_recent", assign: { snap.syncStates = $0 }) {
            try dataStore.fetchSharedArtifactSyncStates(limit: 100)
        }
        capture(metric: .permissions, context: "permission_count", assign: { snap.permissionCount = $0 }) {
            try dataStore.countSharedArtifactPermissions()
        }
        capture(metric: .permissions, context: "permission_recent", assign: { snap.permissions = $0 }) {
            try dataStore.fetchSharedArtifactPermissions(limit: 100)
        }
        capture(metric: .auditEvents, context: "audit_count", assign: { snap.auditEventCount = $0 }) {
            try dataStore.countSharedArtifactAuditEvents()
        }
        capture(metric: .auditEvents, context: "audit_recent", assign: { snap.auditEvents = $0 }) {
            try dataStore.fetchSharedArtifactAuditEvents(limit: 50)
        }

        // System: projection jobs
        capture(metric: .projectionJobs, context: "projection_recent", assign: { snap.projectionJobs = $0 }) {
            try dataStore.fetchProjectionJobs(
                statuses: ProjectionJobStatus.allCases,
                limit: 100
            )
        }
        capture(metric: .projectionJobs, context: "projection_total", assign: { snap.projectionJobCounts.total = $0 }) {
            try dataStore.countProjectionJobs()
        }
        capture(metric: .projectionJobs, context: "projection_active", assign: { snap.projectionJobCounts.active = $0 }) {
            try dataStore.countProjectionJobs(statuses: [.running, .leased])
        }
        capture(metric: .projectionJobs, context: "projection_queued", assign: { snap.projectionJobCounts.queued = $0 }) {
            try dataStore.countProjectionJobs(statuses: [.queued])
        }
        capture(metric: .projectionJobs, context: "projection_failed", assign: { snap.projectionJobCounts.failed = $0 }) {
            try dataStore.countProjectionJobs(statuses: [.failed])
        }

        // System: retrieval health
        capture(metric: .retrievalHealth, context: "retrieval_health", assign: { snap.retrievalHealth = $0 }) {
            try dataStore.fetchRetrievalHealth()
        }
        snap.retrievalSystemHealth = RetrievalHealthService(dataStore: dataStore).snapshot(
            indexingEnabled: settingsManager.conversationIndexingEnabled,
            sharedFeaturesAvailable: accountManager?.isSignedIn ?? false
        )

        // Embeddings
        capture(metric: .embeddingModels, context: "embedding_models", assign: { snap.embeddingModelRecords = $0 }) {
            try dataStore.fetchEmbeddingModels()
        }
        capture(metric: .embeddingModels, context: "embedding_model_count", assign: { snap.embeddingModels = $0 }) {
            try dataStore.countEmbeddingModels()
        }
        capture(metric: .embeddingVersions, context: "embedding_versions", assign: { snap.embeddingVersionRecords = $0 }) {
            try dataStore.fetchEmbeddingVersions()
        }
        capture(metric: .embeddingVersions, context: "embedding_version_count", assign: { snap.embeddingVersions = $0 }) {
            try dataStore.countEmbeddingVersions()
        }
        capture(metric: .embeddedChunks, context: "embedding_chunk_count", assign: { snap.embeddedChunks = $0 }) {
            try dataStore.countChunkEmbeddings()
        }

        // Freshness
        snap.lastRefresh = dataStore.lastRefresh
        snap.snapshotBuiltAt = Date()
        snap.contentVersion = makeContentVersion(from: snap)

        return snap
    }

    private static func makeContentVersion(from snapshot: DatabaseWorkspaceSnapshot) -> String {
        let syncUpdatedAt = snapshot.syncStates.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let auditOccurredAt = snapshot.auditEvents.map(\.occurredAt).max()?.timeIntervalSince1970 ?? 0
        let projectionUpdatedAt = snapshot.projectionJobs.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let retrievalObservedAt = snapshot.retrievalHealth.map(\.observedAt).max()?.timeIntervalSince1970 ?? 0
        let embeddingModelUpdatedAt = snapshot.embeddingModelRecords.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let embeddingVersionUpdatedAt = snapshot.embeddingVersionRecords.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let lastRefresh = snapshot.lastRefresh?.timeIntervalSince1970 ?? 0

        return [
            "\(snapshot.totalSessions)",
            "\(snapshot.totalConversations)",
            "\(snapshot.indexedDocuments)",
            "\(snapshot.indexedChunks)",
            "\(snapshot.sourceArtifacts)",
            "\(snapshot.sharedArtifactCount)",
            "\(snapshot.syncedArtifactCount)",
            "\(snapshot.pendingArtifactCount)",
            "\(snapshot.conflictedArtifactCount)",
            "\(snapshot.failedArtifactCount)",
            "\(snapshot.permissionCount)",
            "\(snapshot.auditEventCount)",
            "\(snapshot.projectionJobCounts.total)",
            "\(syncUpdatedAt)",
            "\(auditOccurredAt)",
            "\(projectionUpdatedAt)",
            "\(retrievalObservedAt)",
            "\(snapshot.retrievalSystemHealth.observedAt.timeIntervalSince1970)",
            "\(embeddingModelUpdatedAt)",
            "\(embeddingVersionUpdatedAt)",
            "\(lastRefresh)",
            snapshot.unavailableMetrics.map(\.rawValue).sorted().joined(separator: ",")
        ].joined(separator: "|")
    }
}
